#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Scope arenas (memory.md §3.1–3.2, docs/design/lowering.md L8)                 */
/* ---------------------------------------------------------------------- */

/* What threads share and change -- the chunk map's levels, the spare
   chunks, and the contexts -- changes under this lock. */
pthread_mutex_t zane_memory = PTHREAD_MUTEX_INITIALIZER;

/* Which region every chunk belongs to, by its address over 1 MiB: 0 for
   none, a fixed chunk's entry, or minus a dynamic chunk's. Each entry names
   the context and, within it, the fixed chunk's index or the dynamic
   chunk's scope. An oversized block's chunks are each listed. */
static int32_t *zane_pages[ZANE_PAGES];

static int32_t *zane_page(const void *at, int make) {
	uintptr_t page = (uintptr_t)at >> 20;
	if (page / ZANE_PAGES >= ZANE_PAGES) {
		if (make) zane_broken("memory beyond a 48-bit address");
		return NULL;
	}
	int32_t **level = &zane_pages[page / ZANE_PAGES];
	int32_t *entries = __atomic_load_n(level, __ATOMIC_ACQUIRE);
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

/* Every context made, by its id, and those free for the next spawned call. */
static zane_context *zane_contexts[ZANE_CONTEXTS];
int32_t zane_context_count;
zane_context *zane_idle;

/* The context running on this thread, and the program's own region. */
_Thread_local zane_context *zane_self;
zane_mark *zane_program;

zane_mark *zane_mark_at(zane_context *c, int64_t depth) {
	return &c->segments[depth / ZANE_SEGMENT][depth % ZANE_SEGMENT];
}

static int zane_guarded(zane_context *c) { return c != zane_self || c->shared > 0; }
void zane_lock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_lock(&c->lock); }
void zane_unlock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_unlock(&c->lock); }

zane_context *zane_context_new(void) {
	pthread_mutex_lock(&zane_memory);
	zane_context *c = zane_idle;
	if (c) {
		zane_idle = c->next;
	} else {
		if (zane_context_count == ZANE_CONTEXTS) zane_broken("too many spawned calls out at once");
		c = calloc(1, sizeof *c);
		if (!c || !(c->directory = calloc(ZANE_CHUNKS, sizeof *c->directory)))
			zane_broken("out of memory for a context");
		pthread_mutex_init(&c->lock, NULL);
		c->id = zane_context_count;
		zane_contexts[zane_context_count++] = c;
	}
	pthread_mutex_unlock(&zane_memory);
	return c;
}

/* A chunk-map entry: a context's fixed chunk, or its scope's dynamic one. */
static int32_t zane_entry(const zane_context *c, int64_t n) {
	return (int32_t)(((int64_t)c->id << 15 | n) + 1);
}

int64_t zane_scope_enter(void) {
	zane_context *c = zane_self;
	if (c->depth == ZANE_DEPTH) zane_broken("scopes nested too deep");
	zane_lock(c);
	zane_mark **segment = &c->segments[c->depth / ZANE_SEGMENT];
	if (!*segment && !(*segment = malloc(ZANE_SEGMENT * sizeof **segment)))
		zane_broken("out of memory for scopes");
	*zane_mark_at(c, c->depth) =
		(zane_mark){ c, c->depth, c->chunks, c->frontier, NULL, NULL, NULL, NULL, 0, NULL, NULL, 0, NULL };
	int64_t depth = c->depth++;
	zane_unlock(c);
	return depth;
}

/* Bytes from this context's fixed chain; its caller holds the lock. */
void *zane_bump(int64_t size, int64_t align) {
	zane_context *c = zane_self;
	if (size > ZANE_CHUNK) zane_broken("a slot larger than a chunk");
	size_t start = (c->frontier + (size_t)align - 1) / (size_t)align * (size_t)align;
	if (c->chunks == 0 || start + (size_t)size > ZANE_CHUNK) {
		if (c->chunks == ZANE_CHUNKS) zane_broken("out of chunks");
		if (!c->directory[c->chunks]) {
			c->directory[c->chunks] = zane_chunk_alloc(ZANE_CHUNK);
			if (!c->directory[c->chunks]) zane_broken("out of memory for a chunk");
			*zane_page(c->directory[c->chunks], 1) = zane_entry(c, c->chunks);
		}
		c->chunks++;
		start = 0;
	}
	c->frontier = start + (size_t)size;
	return c->directory[c->chunks - 1] + start;
}

/* The region that holds `at`: the one whose dynamic chunk it is in, or the
   innermost scope of the context whose fixed chain it is in that began at
   or before it. Anything else, such as a value on the machine stack, is the
   innermost scope's here. */
zane_mark *zane_region_at(const void *at) {
	int32_t *page = zane_page(at, 0);
	int32_t entry = page ? *page : 0;
	if (entry == 0) return zane_mark_at(zane_self, zane_self->depth - 1);
	int64_t n = (entry < 0 ? -(int64_t)entry : (int64_t)entry) - 1;
	zane_context *c = zane_contexts[n >> 15];
	n &= ZANE_DEPTH - 1;
	if (entry < 0) return zane_mark_at(c, n);
	zane_lock(c);
	int64_t position = n * ZANE_CHUNK + ((const char *)at - c->directory[n]);
	int64_t lo = 0, hi = c->depth - 1;
	while (lo < hi) {
		int64_t mid = (lo + hi + 1) / 2;
		zane_mark *m = zane_mark_at(c, mid);
		int64_t start = m->chunks ? (int64_t)(m->chunks - 1) * ZANE_CHUNK + (int64_t)m->frontier : 0;
		if (start <= position) lo = mid;
		else hi = mid - 1;
	}
	zane_unlock(c);
	return zane_mark_at(c, lo);
}

/* Whether `at` is in a region's chunk at all, rather than on the machine
   stack. */
int zane_in_region(const void *at) {
	int32_t *page = zane_page(at, 0);
	return page && *page != 0;
}

/* Every block is at least a word, and aligned to one. */
static int64_t zane_word(int64_t n) { return n < 8 ? 8 : (n + 7) / 8 * 8; }

/* Dynamic chunks a drained region gave back, ready for the next. */
static zane_mapping *zane_spare;

/* Chunks of its own for one region: `size` bytes in all, a whole number of
   chunks, listed in the chunk map as the region's. Its context's lock is
   held. */
static zane_mapping *zane_map(zane_mark *region, size_t size) {
	zane_mapping *m = NULL;
	if (size == ZANE_CHUNK) {
		pthread_mutex_lock(&zane_memory);
		if ((m = zane_spare)) zane_spare = m->next;
		pthread_mutex_unlock(&zane_memory);
	}
	if (!m && !(m = zane_chunk_alloc(size)))
		zane_broken("out of memory for a dynamic chunk");
	for (size_t at = 0; at < size; at += ZANE_CHUNK)
		*zane_page((char *)m + at, 1) = -zane_entry(region->context, region->depth);
	m->size = size;
	m->next = region->mappings;
	region->mappings = m;
	return m;
}

/* A region's chunks given back: each leaves the chunk map, and a whole
   chunk is kept for the next region that needs one. */
void zane_unmap(zane_mark *region) {
	while (region->mappings) {
		zane_mapping *next = region->mappings->next;
		for (size_t at = 0; at < region->mappings->size; at += ZANE_CHUNK)
			*zane_page((char *)region->mappings + at, 0) = 0;
		if (region->mappings->size == ZANE_CHUNK) {
			pthread_mutex_lock(&zane_memory);
			region->mappings->next = zane_spare;
			zane_spare = region->mappings;
			pthread_mutex_unlock(&zane_memory);
		} else {
			zane_chunk_free(region->mappings);
		}
		region->mappings = next;
	}
	region->chunk = NULL;
	region->bumped = 0;
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
	size_t start = (m->bumped + (size_t)align - 1) / (size_t)align * (size_t)align;
	if (!m->chunk || start + (size_t)size > ZANE_CHUNK) {
		m->chunk = (char *)zane_map(m, ZANE_CHUNK);
		start = ZANE_LINE;
	}
	m->bumped = start + (size_t)size;
	return m->chunk + start;
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

/* How many blocks are out, in every open region. */
_Atomic int64_t zane_blocks;

/* A block in a region: one returned there of the same size and alignment,
   or else new bytes from its frontier (§3.2). */
char *zane_alloc(zane_mark *region, int64_t size, int64_t align) {
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_lock(region->context);
	zane_stack *s = zane_find_stack(region, size, align);
	char *block = s ? s->top : NULL;
	if (block) s->top = *(char **)block;
	else block = zane_frontier_of(region, size, align);
	region->live++;
	zane_unlock(region->context);
	zane_blocks++;
	return block;
}

/* A block returned to its region, for the next of its size and alignment. */
void zane_free(char *block, int64_t size, int64_t align) {
	zane_mark *region = zane_region_at(block);
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_lock(region->context);
	zane_stack *s = zane_stack_of(region, size, align);
	*(char **)block = s->top;
	s->top = block;
	region->live--;
	zane_unlock(region->context);
	zane_blocks--;
}
