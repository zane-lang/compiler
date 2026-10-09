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
   search tries that one first. */
zane_mark *zane_region_at(const void *at) {
	uintptr_t *page = zane_page(at, 0);
	uintptr_t entry = page ? __atomic_load_n(page, __ATOMIC_ACQUIRE) : 0;
	if (entry == 0) return zane_self->top;
	if (!(entry & 1)) return (zane_mark *)entry;
	zane_context *c = (zane_context *)(entry & ~(uintptr_t)1);
	zane_lock(c);
	zane_mark *m = zane_scope_holding(c, at);
	zane_unlock(c);
	if (!m) zane_broken("an address in a context's range below its first scope");
	return m;
}

/* Every block is at least a word, and aligned to one. */
static int64_t zane_word(int64_t n) { return n < 8 ? 8 : (n + 7) / 8 * 8; }

/* Dynamic chunks that contexts gave back when their calls were over,
   ready for any context that has no spare of its own. */
static zane_mapping *zane_spare;

/* A context going idle gives its spare chunks to every context, so an idle
   one never keeps the peak its last call reached. */
void zane_give_spares(zane_context *c) {
	if (!c->spare) return;
	zane_mapping *last = c->spare;
	while (last->next) last = last->next;
	pthread_mutex_lock(&zane_memory);
	last->next = zane_spare;
	zane_spare = c->spare;
	pthread_mutex_unlock(&zane_memory);
	c->spare = NULL;
}

/* Chunks of its own for one region: `size` bytes in all, a whole number of
   chunks, listed in the chunk map as the region's. A whole chunk is one of
   its context's spares when there is one, else one an idle context gave
   back. Its context's lock is held. */
static zane_mapping *zane_map(zane_mark *region, size_t size) {
	zane_context *c = region->context;
	zane_mapping *m = NULL;
	if (size == ZANE_CHUNK) {
		if ((m = c->spare)) {
			c->spare = m->next;
		} else {
			pthread_mutex_lock(&zane_memory);
			if ((m = zane_spare)) zane_spare = m->next;
			pthread_mutex_unlock(&zane_memory);
		}
	}
	if (!m && !(m = zane_chunk_alloc(size)))
		zane_broken("out of memory for a dynamic chunk");
	for (size_t at = 0; at < size; at += ZANE_CHUNK) zane_set_page((char *)m + at, (uintptr_t)region);
	m->size = size;
	m->next = region->mappings;
	region->mappings = m;
	return m;
}

/* A region's chunks given back, whatever is still in them (memory.md
   §3.2): each leaves the chunk map, and a whole chunk is kept for the next
   region of the same context that needs one. Its context's lock is held. */
void zane_unmap(zane_mark *region) {
	zane_context *c = region->context;
	while (region->mappings) {
		zane_mapping *next = region->mappings->next;
		for (size_t at = 0; at < region->mappings->size; at += ZANE_CHUNK)
			zane_set_page((char *)region->mappings + at, 0);
		if (region->mappings->size == ZANE_CHUNK) {
			region->mappings->next = c->spare;
			c->spare = region->mappings;
		} else {
			zane_chunk_free(region->mappings);
		}
		region->mappings = next;
	}
	region->heap = (zane_heap){ 0 };
	region->stacks = NULL;
}

/* Bytes from a region's frontier, which moves to a fresh chunk when the
   current one cannot hold them. A block too large for any chunk is an
   oversized one, with chunks of its own (§3.1). */
static char *zane_frontier_of(zane_mark *m, int64_t size, int64_t align) {
	if (size > ZANE_CHUNK - ZANE_LINE) {
		size_t chunks = ((size_t)size + ZANE_LINE + ZANE_CHUNK - 1) / ZANE_CHUNK;
		return (char *)zane_map(m, chunks * ZANE_CHUNK) + ZANE_LINE;
	}
	zane_heap *h = &m->heap;
	uintptr_t start = ((uintptr_t)h->bump + (uintptr_t)align - 1) / (uintptr_t)align * (uintptr_t)align;
	if (!h->bump || start + (uintptr_t)size > (uintptr_t)h->end) {
		char *chunk = (char *)zane_map(m, ZANE_CHUNK);
		start = (uintptr_t)chunk + ZANE_LINE;
		h->end = chunk + ZANE_CHUNK;
	}
	h->bump = (char *)(start + (uintptr_t)size);
	return (char *)start;
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
static zane_stack *zane_stack_of(zane_mark *m, int64_t size, int64_t align) {
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
