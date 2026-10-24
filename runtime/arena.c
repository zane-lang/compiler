#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Scope arenas (memory.md §3.1–3.2, docs/design/lowering.md L8)          */
/* ---------------------------------------------------------------------- */

/* What threads share and change -- the chunk map's levels, the spare
   chunks idle contexts gave back, and the contexts -- changes under this
   lock. */
pthread_mutex_t zane_memory = PTHREAD_MUTEX_INITIALIZER;

/* What every 1 MiB of the address space belongs to, by its address over
   1 MiB: 0 for nothing of the runtime's, a dynamic chunk's region record,
   or a context with its lowest bit set, for each MiB of the range it
   reserved for its frames, guard included. An oversized block's chunks are
   each listed. The fault handler reads it too (region.c), so a level, once
   made, stays, and every entry is read and written whole. */
static uintptr_t *zane_pages[ZANE_PAGES];

uintptr_t *zane_page(const void *at, int make) {
	uintptr_t page = (uintptr_t)at >> 20;
	if (page / ZANE_PAGES >= ZANE_PAGES) {
		if (make) zane_broken("memory beyond a 48-bit address");
		return NULL;
	}
	uintptr_t **level = &zane_pages[page / ZANE_PAGES];
	uintptr_t *entries = __atomic_load_n(level, __ATOMIC_ACQUIRE);
	if (!entries) {
		if (!make) return NULL;
		pthread_mutex_lock(&zane_memory);
		entries = __atomic_load_n(level, __ATOMIC_ACQUIRE);
		if (!entries) {
			entries = calloc(ZANE_PAGES, sizeof *entries);
			if (!entries) zane_broken("out of memory for the chunk map");
			__atomic_store_n(level, entries, __ATOMIC_RELEASE);
		}
		pthread_mutex_unlock(&zane_memory);
	}
	return entries + page % ZANE_PAGES;
}

static void zane_set_page(const void *at, uintptr_t entry) {
	__atomic_store_n(zane_page(at, 1), entry, __ATOMIC_RELEASE);
}

/* Every context made, by its id, and those free for the next spawned call.
   A context takes its id under the lock, and is listed once its range is
   reserved. */
static zane_context *zane_contexts[ZANE_CONTEXTS];
int32_t zane_context_count;
zane_context *zane_idle;

/* The context running on this thread, and the program's own region. */
_Thread_local zane_context *zane_self;
zane_mark *zane_program;

/* The innermost region of the context running on this thread while no call
   it spawned is out, so that nothing else can reach it, and otherwise null.
   Emitted code takes a box's block there itself, and opens and drains a
   scope there itself (docs/design/lowering.md §9). Whatever changes the
   context, its innermost scope or whether it is shared sets it again. */
_Thread_local zane_mark *zane_open;

void zane_reopen(void) {
	zane_context *c = zane_self;
	zane_open = c && c->top && c->shared == 0 ? c->top : NULL;
}

/* The context with id `id`, once it is listed. */
zane_context *zane_context_at(int32_t id) { return __atomic_load_n(&zane_contexts[id], __ATOMIC_ACQUIRE); }

static int zane_guarded(zane_context *c) { return c != zane_self || c->shared > 0; }
void zane_lock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_lock(&c->lock); }
void zane_unlock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_unlock(&c->lock); }

/* A context for the program's `main`, the first one made, or for a
   spawned call, with the range its frames go in. A context a call is over
   with keeps its range for the next. */
zane_context *zane_context_new(void) {
	pthread_mutex_lock(&zane_memory);
	zane_context *c = zane_idle;
	if (c) {
		zane_idle = c->next;
		pthread_mutex_unlock(&zane_memory);
		return c;
	}
	if (zane_context_count == ZANE_CONTEXTS) zane_broken("too many spawned calls out at once");
	c = calloc(1, sizeof *c);
	if (!c) zane_broken("out of memory for a context");
	pthread_mutex_init(&c->lock, NULL);
	c->id = zane_context_count++;
	pthread_mutex_unlock(&zane_memory);
	zane_reserve(c, c->id == 0 ? zane_fixed_region : zane_spawned_fixed_region);
	for (char *at = c->base; at < c->limit + ZANE_GUARD; at += ZANE_CHUNK)
		zane_set_page(at, (uintptr_t)c | 1);
	__atomic_store_n(&zane_contexts[c->id], c, __ATOMIC_RELEASE);
	return c;
}

/* The scope a new one skips to (`zane_mark`): the scope around it, or that
   scope's skip's skip when the two spans below it are equal. */
static zane_mark *zane_skip_of(zane_mark *outer) {
	zane_mark *a = outer->skip, *b = a->skip;
	return outer->depth - a->depth == a->depth - b->depth ? b : outer;
}

/* A scope opens with a frame of `size` bytes, its record first, and the
   record's address names it from now. Emitted code does the same inline
   while the context is its thread's alone, and calls this otherwise. A
   frame past the range's end stops the program here, as one past its guard
   would. */
zane_mark *zane_scope_enter(int64_t size) {
	zane_context *c = zane_self;
	if (size < (int64_t)sizeof(zane_mark)) size = (int64_t)sizeof(zane_mark);
	size = (size + 15) / 16 * 16;
	zane_lock(c);
	zane_mark *m = (zane_mark *)c->frontier;
	if (size > c->limit - c->frontier) {
		zane_unlock(c);
		zane_too_deep_in(c);
	}
	c->frontier += size;
	zane_mark *outer = c->top;
	*m = (zane_mark){ .context = c, .depth = outer ? outer->depth + 1 : 0, .outer = outer };
	m->skip = outer ? zane_skip_of(outer) : m;
	c->top = m;
	zane_unlock(c);
	zane_reopen();
	return m;
}

/* The scope of context `c` whose frame holds `at`: the innermost whose
   record is at or below it. Every frame starts with its record and lies
   above the frames around it, so a record above `at` and every record
   between it and its skip are above it too. */
static zane_mark *zane_scope_holding(zane_context *c, const char *at) {
	zane_mark *m = c->top;
	while (m && (const char *)m > at) m = (const char *)m->skip > at ? m->skip : m->outer;
	return m;
}

/* The region that holds `at`: the one whose dynamic chunk it is in, or the
   scope of the context whose range it is in whose frame holds it. Anything
   else, such as a value on the machine stack, is the innermost scope's
   here. Most slots asked about are the innermost scope's own, so the
   search tries that one first, and without the lock while the context is
   this thread's alone. */
zane_mark *zane_region_at(const void *at) {
	uintptr_t *page = zane_page(at, 0);
	uintptr_t entry = page ? __atomic_load_n(page, __ATOMIC_ACQUIRE) : 0;
	if (entry == 0) return zane_self->top;
	if (!(entry & 1)) return (zane_mark *)entry;
	zane_context *c = (zane_context *)(entry & ~(uintptr_t)1);
	zane_mark *top = c->top;
	if (top && !zane_guarded(c) && (const char *)at >= (const char *)top) return top;
	zane_lock(c);
	zane_mark *m = zane_scope_holding(c, at);
	zane_unlock(c);
	if (!m) zane_broken("an address in a context's range below its first scope");
	return m;
}

/* Every block is at least a word, and aligned to one. */
static int64_t zane_word(int64_t n) { return n < 8 ? 8 : (n + 7) / 8 * 8; }

/* Dynamic chunks come from the system directly, at a 1 MiB boundary, so
   that a drained one's pages can go back to it. A spare chunk is warm, its
   pages resident, or cold, its pages after the first given back: the first
   holds its header and the link of the list it is on. A drained chunk stays
   warm on its context, which keeps ZANE_WARM_KEPT of them for good and the
   rest while fewer than ZANE_COOLING of its later drains have passed, and
   a context going idle gives its warm ones to the pool, which keeps up to
   ZANE_POOL_WARM. Every other spare turns cold, and past ZANE_COLD_KEPT
   cold ones goes back to the system whole, as an oversized block's chunks
   always do. A region takes its context's latest warm spare first, then
   the pool's, then a cold one, whose pages come back zeroed when touched,
   then a new chunk. The pool's lists and every count change under
   `zane_memory`; a context's own warm list, under its lock. */
static zane_mapping *zane_spare, *zane_cold;
int64_t zane_warm_spares, zane_cold_spares, zane_cold_reuses;

#ifdef _WIN32
/* Windows gives back a reservation only whole, and a 1 MiB-aligned one costs
   an extra MiB of addresses, so chunks are carved from slabs of 64 MiB, or
   one of its own for a larger block. A slab counts its chunks that are live
   or warm. A cold chunk keeps its first page committed; one given back
   whole is decommitted entirely and only its slab's addresses remain. Once
   every chunk carved from a slab is cold or given back, and no more will be
   carved from it, its cold chunks leave the cold list and the slab goes back
   to the system. Slabs change under `zane_memory`. */
enum { ZANE_SLAB = 64 * ZANE_CHUNK };

typedef struct zane_slab {
	char *raw, *base;
	size_t bytes, carved;
	int64_t held;
} zane_slab;

static zane_slab *zane_carving;

static zane_slab *zane_slab_new(size_t bytes) {
	zane_slab *s = calloc(1, sizeof *s);
	if (!s || !(s->base = zane_reserve_aligned(bytes, &s->raw)))
		zane_broken("out of addresses for a dynamic chunk");
	s->bytes = bytes;
	return s;
}

static void zane_slab_release(zane_slab *s) {
	for (zane_mapping **at = &zane_cold; *at;)
		if ((*at)->slab == s) {
			*at = (*at)->next;
			zane_cold_spares--;
		} else {
			at = &(*at)->next;
		}
	zane_release_addresses(s->raw, s->base, s->bytes);
	free(s);
}

/* `chunks` of a slab's chunks are cold or given back. */
static void zane_slab_drop(zane_slab *s, size_t chunks) {
	s->held -= (int64_t)chunks;
	if (s->held == 0 && s != zane_carving) zane_slab_release(s);
}
#endif

/* `size` bytes of new chunks, usable. */
static zane_mapping *zane_chunks_new(size_t size) {
	char *base;
#ifdef _WIN32
	pthread_mutex_lock(&zane_memory);
	zane_slab *s = zane_carving;
	if (size >= ZANE_SLAB) {
		s = zane_slab_new(size);
	} else if (!s || s->bytes - s->carved < size) {
		zane_slab *old = s;
		s = zane_carving = zane_slab_new(ZANE_SLAB);
		if (old && old->held == 0) zane_slab_release(old);
	}
	base = s->base + s->carved;
	s->carved += size;
	s->held += (int64_t)(size / ZANE_CHUNK);
	pthread_mutex_unlock(&zane_memory);
#else
	char *raw;
	if (!(base = zane_reserve_aligned(size, &raw))) zane_broken("out of addresses for a dynamic chunk");
#endif
	if (!zane_commit_range(base, size)) zane_broken("out of memory for a dynamic chunk");
	zane_mapping *m = (zane_mapping *)base;
#ifdef _WIN32
	m->slab = s;
#else
	m->slab = NULL;
#endif
	return m;
}

/* Chunks of `size` bytes from `m` given back to the system whole. */
static void zane_chunks_drop(zane_mapping *m, size_t size) {
#ifdef _WIN32
	/* The header is in the range decommitted, so its slab is read first. */
	zane_slab *slab = m->slab;
	zane_decommit_range((char *)m, size);
	pthread_mutex_lock(&zane_memory);
	zane_slab_drop(slab, size / ZANE_CHUNK);
	pthread_mutex_unlock(&zane_memory);
#else
	zane_release_addresses(NULL, (char *)m, size);
#endif
}

/* A drained chunk no context keeps warm turns cold, or goes back to the
   system past the cold ones kept. */
static void zane_chill(zane_mapping *m) {
	size_t page = zane_page_bytes();
	if (!zane_decommit_range((char *)m + page, ZANE_CHUNK - page)) {
		zane_chunks_drop(m, ZANE_CHUNK);
		return;
	}
	pthread_mutex_lock(&zane_memory);
	if (zane_cold_spares < ZANE_COLD_KEPT) {
		m->next = zane_cold;
		zane_cold = m;
		zane_cold_spares++;
#ifdef _WIN32
		zane_slab_drop(m->slab, 1);
#endif
		pthread_mutex_unlock(&zane_memory);
		return;
	}
	pthread_mutex_unlock(&zane_memory);
	zane_chunks_drop(m, ZANE_CHUNK);
}

/* A context's warm spares: the latest given back first, the earliest
   last. */
static void zane_keep_warm(zane_context *c, zane_mapping *m) {
	m->stamp = c->drains;
	m->prev = NULL;
	m->next = c->spare;
	if (c->spare) c->spare->prev = m;
	else c->spare_last = m;
	c->spare = m;
	c->warm++;
}

static zane_mapping *zane_take_warm(zane_context *c) {
	zane_mapping *m = c->spare;
	c->spare = m->next;
	if (c->spare) c->spare->prev = NULL;
	else c->spare_last = NULL;
	c->warm--;
	return m;
}

/* A context going idle gives its warm chunks to the pool, so an idle one
   never keeps the peak its last call reached; past what the pool keeps
   warm, they turn cold. */
void zane_give_spares(zane_context *c) {
	if (!c->spare) return;
	pthread_mutex_lock(&zane_memory);
	while (c->spare && zane_warm_spares < ZANE_POOL_WARM) {
		zane_mapping *m = zane_take_warm(c);
		m->next = zane_spare;
		zane_spare = m;
		zane_warm_spares++;
	}
	pthread_mutex_unlock(&zane_memory);
	while (c->spare) zane_chill(zane_take_warm(c));
}

/* Chunks of its own for one region: `size` bytes in all, a whole number of
   chunks, listed in the chunk map as the region's. A whole chunk is a warm
   spare of its context's or the pool's when there is one, else a cold one,
   made usable again, else a new one. Its context's lock is held. */
static zane_mapping *zane_map(zane_mark *region, size_t size) {
	zane_context *c = region->context;
	zane_mapping *m = NULL;
	if (size == ZANE_CHUNK) {
		if (c->spare) {
			m = zane_take_warm(c);
		} else {
			int cold = 0;
			pthread_mutex_lock(&zane_memory);
			if ((m = zane_spare)) {
				zane_spare = m->next;
				zane_warm_spares--;
			} else if ((m = zane_cold)) {
				zane_cold = m->next;
				zane_cold_spares--;
				zane_cold_reuses++;
				cold = 1;
#ifdef _WIN32
				m->slab->held++;
#endif
			}
			pthread_mutex_unlock(&zane_memory);
			size_t page = zane_page_bytes();
			if (cold && !zane_commit_range((char *)m + page, ZANE_CHUNK - page))
				zane_broken("out of memory for a dynamic chunk");
		}
	}
	if (!m) m = zane_chunks_new(size);
	for (size_t at = 0; at < size; at += ZANE_CHUNK) zane_set_page((char *)m + at, (uintptr_t)region);
	m->size = size;
	m->reserved = 0;
	m->raw = NULL;
	m->next = region->mappings;
	region->mappings = m;
	return m;
}

/* A region's chunks given back, whatever is still in them (memory.md
   §3.2): each leaves the chunk map, and a whole chunk stays warm for the
   next region of the same context, until it has sat unused through
   ZANE_COOLING of the context's drains past the ZANE_WARM_KEPT it keeps
   for good. A list's growable span gives back its whole reservation, and an
   oversized block its chunks. Its context's lock is held. */
void zane_unmap(zane_mark *region) {
	zane_context *c = region->context;
	if (region->mappings) c->drains++;
	while (region->mappings) {
		zane_mapping *m = region->mappings;
		region->mappings = m->next;
		for (size_t at = 0; at < m->size; at += ZANE_CHUNK) zane_set_page((char *)m + at, 0);
		if (m->reserved) zane_release_addresses(m->raw, (char *)m, m->reserved);
		else if (m->size != ZANE_CHUNK) zane_chunks_drop(m, m->size);
		else zane_keep_warm(c, m);
	}
	while (c->warm > ZANE_WARM_KEPT && c->drains - c->spare_last->stamp >= ZANE_COOLING) {
		zane_mapping *m = c->spare_last;
		c->spare_last = m->prev;
		c->spare_last->next = NULL;
		c->warm--;
		zane_chill(m);
	}
	region->heap = (zane_heap){ 0 };
	region->stacks = NULL;
}

/* Whether scope `m`'s frame stretches to `end`: it does while the scope is
   its context's innermost, by at least ZANE_STRETCH bytes and to a 16-byte
   boundary, as long as the frame stays within `most` bytes and the range
   (zane_internal.h). The frontier moves to its new end, and so does
   the end of the scope's heap. Its context's lock is held. */
int zane_stretch(zane_mark *m, char *end, int64_t most) {
	zane_context *c = m->context;
	if (c->top != m) return 0;
	uintptr_t to = (uintptr_t)end, least = (uintptr_t)c->frontier + ZANE_STRETCH;
	if (to < least) to = least;
	to = (to + 15) & ~(uintptr_t)15;
	if (to - (uintptr_t)m > (uintptr_t)most || to > (uintptr_t)c->limit) return 0;
	c->frontier = m->heap.end = (char *)to;
	return 1;
}

/* Bytes from a region's frontier: where its heap has room, else in its
   frame, stretched to hold them, else in a fresh chunk, which becomes where
   the heap is. A block too large for any chunk is an oversized one, with
   chunks of its own (§3.1). A frame a list has stretched past
   ZANE_STRETCHED (list.c) may stretch by ZANE_STRETCH more, up to a
   chunk's size, so a small block after the list, such as the record of the
   stack its old block goes to, takes no chunk of its own. */
static char *zane_frontier_of(zane_mark *m, int64_t size, int64_t align) {
	zane_heap *h = &m->heap;
	uintptr_t mask = (uintptr_t)align - 1;
	uintptr_t start = ((uintptr_t)h->bump + mask) & ~mask;
	if (h->bump && start + (uintptr_t)size <= (uintptr_t)h->end) {
		h->bump = (char *)(start + (uintptr_t)size);
		return (char *)start;
	}
	char *frontier = m->context->frontier;
	start = (((uintptr_t)(h->bump && h->end == frontier ? h->bump : frontier)) + mask) & ~mask;
	int64_t most = frontier - (char *)m;
	most = most > ZANE_STRETCHED && most <= ZANE_CHUNK - ZANE_STRETCH ? most + ZANE_STRETCH : ZANE_STRETCHED;
	if (zane_stretch(m, (char *)(start + (uintptr_t)size), most)) {
		h->bump = (char *)(start + (uintptr_t)size);
		return (char *)start;
	}
	if (size > ZANE_CHUNK - ZANE_LINE) {
		size_t chunks = ((size_t)size + ZANE_LINE + ZANE_CHUNK - 1) / ZANE_CHUNK;
		return (char *)zane_map(m, chunks * ZANE_CHUNK) + ZANE_LINE;
	}
	char *chunk = (char *)zane_map(m, ZANE_CHUNK);
	start = (uintptr_t)chunk + ZANE_LINE;
	h->end = chunk + ZANE_CHUNK;
	h->bump = (char *)(start + (uintptr_t)size);
	return (char *)start;
}

/* The whole chunks an oversized block of `size` bytes takes, its mapping's
   header included. */
static size_t zane_span_bytes(int64_t size) {
	return ((size_t)size + ZANE_LINE + ZANE_CHUNK - 1) / ZANE_CHUNK * ZANE_CHUNK;
}

/* How many times a list's oversized block may grow in place, in bytes, over
   the size it is first made at. */
enum { ZANE_HEADROOM = 64 };

/* A list's oversized block of `size` bytes in a region, at the start of a
   reservation of addresses `ZANE_HEADROOM` times its span, so that it grows
   in place as the list doubles (memory.md §3.6). Reserving costs addresses,
   not memory: only what is usable is charged, and only what is touched
   takes RAM. Where a process may not reserve that many addresses, the
   reservation is the span alone. Its context's lock is held. */
char *zane_alloc_growable(zane_mark *region, int64_t size) {
	size_t bytes = zane_span_bytes(size), reserved = bytes * ZANE_HEADROOM;
	char *raw;
	char *base = reserved / ZANE_HEADROOM == bytes ? zane_reserve_aligned(reserved, &raw) : NULL;
	if (!base) base = zane_reserve_aligned(reserved = bytes, &raw);
	if (!base) zane_broken("out of addresses for a list's elements");
	if (!zane_commit_range(base, bytes)) zane_broken("out of memory for a list's elements");
	zane_mapping *m = (zane_mapping *)base;
	for (size_t at = 0; at < bytes; at += ZANE_CHUNK) zane_set_page(base + at, (uintptr_t)region);
	m->size = bytes;
	m->reserved = reserved;
	m->raw = raw;
	m->next = region->mappings;
	region->mappings = m;
	region->heap.live++;
	return base + ZANE_LINE;
}

/* The oversized block at `block`, in `region`, grown in place to `size`
   bytes, or 0 when its reservation cannot hold them: what follows its
   usable bytes is made usable and listed as the region's. Its context's
   lock is held. */
int zane_extend(zane_mark *region, char *block, int64_t size) {
	zane_mapping *m = (zane_mapping *)(block - ZANE_LINE);
	size_t bytes = zane_span_bytes(size);
	if (bytes > m->reserved) return 0;
	if (bytes > m->size) {
		if (!zane_commit_range((char *)m + m->size, bytes - m->size))
			zane_broken("out of memory for a list's elements");
		for (size_t at = m->size; at < bytes; at += ZANE_CHUNK) zane_set_page((char *)m + at, (uintptr_t)region);
		m->size = bytes;
	}
	return 1;
}

/* The size class of a block of `size` bytes aligned to `align`, both
   already rounded to words, or -1 when no class holds it. */
static int64_t zane_class(int64_t size, int64_t align) {
	return align == 8 && size <= 8 * ZANE_CLASSES ? size / 8 - 1 : -1;
}

/* A region's stack of returned blocks of one size and alignment, if any
   has been returned there. */
zane_stack *zane_find_stack(zane_mark *m, int64_t size, int64_t align) {
	for (zane_stack *s = m->stacks; s; s = s->next)
		if (s->size == size && s->align == align) return s;
	return NULL;
}

/* The same stack, made the first time a block is returned to it. */
zane_stack *zane_stack_of(zane_mark *m, int64_t size, int64_t align) {
	zane_stack *s = zane_find_stack(m, size, align);
	if (s) return s;
	s = (zane_stack *)zane_frontier_of(m, sizeof *s, 8);
	*s = (zane_stack){ m->stacks, size, align, NULL };
	m->stacks = s;
	return s;
}

/* A block in a region: one returned there of the same size and alignment,
   or else new bytes from its frontier (§3.2). The caller holds the region's
   context's lock, or needs none: emitted code calls this when its own
   inline path finds neither (docs/design/lowering.md §9). */
char *zane_alloc_held(zane_mark *region, int64_t size, int64_t align) {
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_heap *h = &region->heap;
	int64_t class = zane_class(size, align);
	char *block;
	if (class >= 0) {
		block = h->classes[class];
		if (block) h->classes[class] = *(char **)block;
	} else {
		zane_stack *s = zane_find_stack(region, size, align);
		block = s ? s->top : NULL;
		if (block) s->top = *(char **)block;
	}
	if (!block) block = zane_frontier_of(region, size, align);
	h->live++;
	return block;
}

char *zane_alloc(zane_mark *region, int64_t size, int64_t align) {
	zane_lock(region->context);
	char *block = zane_alloc_held(region, size, align);
	zane_unlock(region->context);
	return block;
}

/* A block returned to its region, for the next of its size and alignment. */
void zane_free(char *block, int64_t size, int64_t align) {
	zane_mark *region = zane_region_at(block);
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_lock(region->context);
	int64_t class = zane_class(size, align);
	char **top = class >= 0 ? &region->heap.classes[class] : &zane_stack_of(region, size, align)->top;
	*(char **)block = *top;
	*top = block;
	region->heap.live--;
	zane_unlock(region->context);
}

/* How many blocks are out in every open region, for the runtime's own
   tests: each is counted until it is returned or its region drains. Only
   a test asks, between calls it has joined. */
int64_t zane_blocks(void) {
	int64_t n = 0;
	for (int32_t i = 0; i < zane_context_count; i++) {
		zane_context *c = __atomic_load_n(&zane_contexts[i], __ATOMIC_ACQUIRE);
		if (c)
			for (zane_mark *m = c->top; m; m = m->outer) n += m->heap.live;
	}
	return n;
}
