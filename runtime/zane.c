/* The Zane runtime (docs/lowering.md L17): what every program links with.

   A program's `main` is `zane_main`, which the C `main` below calls once the
   runtime is ready. Everything else here is what an intrinsic lowers to. */

#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void zane_main(void);


/* An integer division by zero (docs/lowering.md §9): what the program wrote
   so far is kept, and it stops with a failing status. */
void zane_divide_by_zero(void) {
	fflush(stdout);
	fputs("division by zero\n", stderr);
	exit(1);
}

/* ---------------------------------------------------------------------- */
/* Scope arenas (memory.md §3.1–3.2, docs/lowering.md L8)                 */
/* ---------------------------------------------------------------------- */

/* A mistake of the compiler's, not the program's: the program stops. */
static void zane_broken(const char *what) {
	fflush(stdout);
	fprintf(stderr, "zane runtime: %s\n", what);
	abort();
}

/* Memory comes in 1 MiB chunks, each made at a 1 MiB boundary. Scopes nest
   last-in-first-out, and each has two regions (memory.md §3.1). Its
   fixed-size region is where its slots are: every scope bumps one shared
   chain of chunks from where the scope around it stopped, and draining it
   returns everything after that point at once (docs/lowering.md §9). A
   fixed chunk stays mapped once made, and the next scope that reaches it
   reuses it. Its dynamic region is where the blocks its values own are: a
   chain of chunks of its own, with a bump frontier and a stack of returned
   blocks for each size and alignment (§3.2), all given back at the drain.

   The program's `main` runs in one context, and each spawned call in one of
   its own (concurrency.md §3): its own nest of scopes, and its own chain of
   fixed chunks, so a thread bumps only its own (docs/lowering.md §9). */
enum { ZANE_CHUNK = 1 << 20, ZANE_CHUNKS = 1 << 15, ZANE_LINE = 64 };
enum { ZANE_DEPTH = 1 << 15, ZANE_SEGMENT = 64, ZANE_CONTEXTS = (1 << 16) - 1 };

/* What threads share and change -- the chunk map's levels, the spare
   chunks, and the contexts -- changes under this lock. */
static pthread_mutex_t zane_memory = PTHREAD_MUTEX_INITIALIZER;

/* Which region every chunk belongs to, by its address over 1 MiB: 0 for
   none, a fixed chunk's entry, or minus a dynamic chunk's. Each entry names
   the context and, within it, the fixed chunk's index or the dynamic
   chunk's scope. An oversized block's chunks are each listed. */
enum { ZANE_PAGES = 1 << 14 };
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

/* A host placed in a scope, with where its contained hosts' backpointers
   are, so the scope's drain can end their identities. It lives in the
   scope's own arena. */
typedef struct zane_hosted {
	struct zane_hosted *next;
	char *slot;
	const int64_t *layout;
} zane_hosted;

/* The returned blocks of one size and alignment, each naming the next. */
typedef struct zane_stack {
	struct zane_stack *next;
	int64_t size, align;
	char *top;
} zane_stack;

/* A dynamic chunk, or the chunks of one oversized block, begins with this,
   and its blocks start a cache line in. */
typedef struct zane_mapping {
	struct zane_mapping *next;
	size_t size;
} zane_mapping;

typedef struct zane_task zane_task;
typedef struct zane_context zane_context;

/* Each open scope of a context, innermost last: where its slots began,
   what it hosts, the calls it spawned, and its dynamic region with the
   number of blocks out in it. The first of the program's is the program's
   own, open until it ends. */
typedef struct {
	zane_context *context;
	int64_t depth;
	uint32_t chunks;
	size_t frontier;
	zane_hosted *hosts;
	zane_task *tasks;
	zane_mapping *mappings;
	char *chunk;
	size_t bumped;
	zane_stack *stacks;
	int64_t live;
} zane_mark;

/* A context's scopes are kept in segments, so a scope's mark stays where it
   is while others open. `shared` counts the calls it spawned that are still
   out. Until it spawns, a context is its own thread's alone; while a call it
   spawned is out, that call may reach its storage, so its scopes and
   regions change under its lock, which another thread always takes for a
   context it reaches (docs/lowering.md §9). */
struct zane_context {
	int32_t id;
	pthread_mutex_t lock;
	int64_t shared, depth;
	zane_mark *segments[ZANE_DEPTH / ZANE_SEGMENT];
	char **directory;
	uint32_t chunks;  /* fixed chunks in use: the current one is the last */
	size_t frontier;  /* the next free byte in the current fixed chunk */
	zane_context *next;
};

/* Every context made, by its id, and those free for the next spawned call. */
static zane_context *zane_contexts[ZANE_CONTEXTS];
static int32_t zane_context_count;
static zane_context *zane_idle;

/* The context running on this thread, and the program's own region. */
static _Thread_local zane_context *zane_self;
static zane_mark *zane_program;

static zane_mark *zane_mark_at(zane_context *c, int64_t depth) {
	return &c->segments[depth / ZANE_SEGMENT][depth % ZANE_SEGMENT];
}

static int zane_guarded(zane_context *c) { return c != zane_self || c->shared > 0; }
static void zane_lock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_lock(&c->lock); }
static void zane_unlock(zane_context *c) { if (zane_guarded(c)) pthread_mutex_unlock(&c->lock); }

static zane_context *zane_context_new(void) {
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
		(zane_mark){ c, c->depth, c->chunks, c->frontier, NULL, NULL, NULL, NULL, 0, NULL, 0 };
	int64_t depth = c->depth++;
	zane_unlock(c);
	return depth;
}

/* Bytes from this context's fixed chain; its caller holds the lock. */
static void *zane_bump(int64_t size, int64_t align) {
	zane_context *c = zane_self;
	if (size > ZANE_CHUNK) zane_broken("a slot larger than a chunk");
	size_t start = (c->frontier + (size_t)align - 1) / (size_t)align * (size_t)align;
	if (c->chunks == 0 || start + (size_t)size > ZANE_CHUNK) {
		if (c->chunks == ZANE_CHUNKS) zane_broken("out of chunks");
		if (!c->directory[c->chunks]) {
			c->directory[c->chunks] = aligned_alloc(ZANE_CHUNK, ZANE_CHUNK);
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
static zane_mark *zane_region_at(const void *at) {
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
	if (!m && !(m = aligned_alloc(ZANE_CHUNK, size)))
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
static void zane_unmap(zane_mark *region) {
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
			free(region->mappings);
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
static zane_stack *zane_find_stack(zane_mark *m, int64_t size, int64_t align) {
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
static _Atomic int64_t zane_blocks;

/* A block in a region: one returned there of the same size and alignment,
   or else new bytes from its frontier (§3.2). */
static char *zane_alloc(zane_mark *region, int64_t size, int64_t align) {
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
static void zane_free(char *block, int64_t size, int64_t align) {
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

/* ---------------------------------------------------------------------- */
/* Anchors and tethers (memory.md §4, docs/lowering.md §9)                */
/* ---------------------------------------------------------------------- */

/* A reference-type instance begins with a `u32` backpointer, and so does
   every host it contains; a string's or a list's handle, and a boxed
   member's pointer, name the block it owns. A layout lists where they are:
   a count, then for each position, outermost first, its kind, its offset,
   its size, a list's stride or a box's payload size, the layout of a
   list's elements or a box's payload, and the variant tags that must be
   live for it to be there, as a count and then (tag offset, tag) pairs. A
   host under no tag is stable; one under a tag is a variant payload, a
   contingent place (memory.md §2.2). */
enum { ZANE_HOST = 0, ZANE_TEXT = 1, ZANE_LIST = 2, ZANE_BOX = 3 };

typedef struct {
	int64_t kind, offset, size, extra;
	const int64_t *inner;
	int64_t conditions;
	const int64_t *tags;
} zane_position;

static int zane_next_position(const int64_t *layout, int64_t *cursor, int64_t *left,
                              zane_position *p) {
	if (*left == 0) return 0;
	const int64_t *at = layout + *cursor;
	*p = (zane_position){ at[0], at[1], at[2], at[3], (const int64_t *)(intptr_t)at[4], at[5],
		                  at + 6 };
	*cursor += 6 + 2 * at[5];
	(*left)--;
	return 1;
}

/* A layout with no positions may be no table at all. */
#define ZANE_EACH(layout, p)                                                        \
	for (int64_t zane_cursor = 1, zane_left = (layout) ? (layout)[0] : 0;           \
	     zane_next_position((layout), &zane_cursor, &zane_left, &(p));)

static int zane_present(const char *base, const zane_position *p) {
	for (int64_t i = 0; i < p->conditions; i++)
		if (*(const int32_t *)(base + p->tags[2 * i]) != (int32_t)p->tags[2 * i + 1]) return 0;
	return 1;
}

static uint32_t *zane_backpointer(char *base, const zane_position *p) {
	return (uint32_t *)(base + p->offset);
}

/* A host that is there, whose identity a caller may read. */
static int zane_hosts(const char *base, const zane_position *p) {
	return p->kind == ZANE_HOST && zane_present(base, p);
}

/* A cell is a payload anchor, naming the host's address, or a forwarder to
   another cell. Tethers and backpointers hold a cell's index, and index 0
   is never a cell, so it stands for untethered. A cell keeps the cells that
   forward to it, which retire with it: every guest that could still name a
   forwarder died before the identity it forwards to ended (§4.6). */
typedef struct {
	void *target;
	uint32_t forward;     /* the cell this one forwards to, or 0 */
	uint32_t forwarders;  /* the first cell forwarding here */
	uint32_t sibling;     /* the next cell forwarding where this one does */
} zane_cell;

/* Cells are kept in segments, so one stays where it is while others are
   made, and a guest reads its own from any thread. Cells are made and
   retired under a lock. */
enum { ZANE_CELL_SEGMENT = 1 << 16 };
static zane_cell *zane_cell_segments[(1ull << 32) / ZANE_CELL_SEGMENT];
static uint32_t zane_cell_count = 1;
static uint32_t zane_free_cell;  /* a stack of returned cells, linked by `sibling` */
static pthread_mutex_t zane_anchors = PTHREAD_MUTEX_INITIALIZER;

static zane_cell *zane_anchor(uint32_t id) {
	return &zane_cell_segments[id / ZANE_CELL_SEGMENT][id % ZANE_CELL_SEGMENT];
}

/* A new cell; the lock is held. */
static uint32_t zane_new_cell(void *target) {
	uint32_t id = zane_free_cell;
	if (id) {
		zane_free_cell = zane_anchor(id)->sibling;
	} else {
		if (zane_cell_count == UINT32_MAX) zane_broken("out of anchors");
		zane_cell **segment = &zane_cell_segments[zane_cell_count / ZANE_CELL_SEGMENT];
		if (!*segment && !(*segment = malloc(ZANE_CELL_SEGMENT * sizeof **segment)))
			zane_broken("out of memory for anchors");
		id = zane_cell_count++;
	}
	*zane_anchor(id) = (zane_cell){ target, 0, 0, 0 };
	return id;
}

/* A cell retired with its forwarders; the lock is held. */
static void zane_retire_held(uint32_t id) {
	uint32_t f = zane_anchor(id)->forwarders;
	while (f) {
		uint32_t next = zane_anchor(f)->sibling;
		zane_retire_held(f);
		f = next;
	}
	zane_anchor(id)->sibling = zane_free_cell;
	zane_free_cell = id;
}

static void zane_retire(uint32_t id) {
	pthread_mutex_lock(&zane_anchors);
	zane_retire_held(id);
	pthread_mutex_unlock(&zane_anchors);
}

/* The identity a tether ends at, following forwarders. */
uint32_t zane_terminal(uint32_t tether) {
	if (tether == 0) zane_broken("an untethered guest");
	while (zane_anchor(tether)->forward) tether = zane_anchor(tether)->forward;
	return tether;
}

/* The address a guest names. */
void *zane_resolve(uint32_t tether) { return zane_anchor(zane_terminal(tether))->target; }

/* A guest to the host at `payload`: its anchor, made the first time. Calls
   running at once may each mint one to a host they read, and get the same. */
uint32_t zane_mint(void *payload) {
	uint32_t *backpointer = payload;
	uint32_t id = __atomic_load_n(backpointer, __ATOMIC_ACQUIRE);
	if (id) return id;
	pthread_mutex_lock(&zane_anchors);
	id = *backpointer;
	if (!id) __atomic_store_n(backpointer, id = zane_new_cell(payload), __ATOMIC_RELEASE);
	pthread_mutex_unlock(&zane_anchors);
	return id;
}

/* ---------------------------------------------------------------------- */
/* Dynamic blocks (memory.md §3.6, docs/lowering.md §9)                   */
/* ---------------------------------------------------------------------- */

/* `@primitives$String`, the string view, and `@primitives$List<T>`:
   reference types whose instance is its backpointer and a handle to its
   bytes or elements. A string has no terminator, and its length is in
   bytes; a list's is in elements. `room` is the size of the block the
   handle owns, or 0 when it owns none: a literal's bytes are the program's
   own and are never returned. */
typedef struct {
	uint32_t bp;
	const char *bytes;
	int64_t length, room;
} zane_text;

typedef struct {
	uint32_t bp;
	char *items;
	int64_t count, room;
} zane_list;

/* A block is returned when the handle or boxed member that owns it dies,
   to the region it is in. What it is decides its size and alignment: a
   string's bytes are as long as its room, a list's elements start at a
   cache line (memory.md §3.6), and a box holds one payload. */
static void zane_unblock(const zane_position *p, void *block, int64_t room) {
	zane_free(block, p->kind == ZANE_BOX ? p->extra : room, p->kind == ZANE_LIST ? ZANE_LINE : 8);
}

static void *zane_at(char *base, const zane_position *p) { return base + p->offset; }

/* Whether `offset` is inside one of the `n` hosts that start at `from`,
   each `size` bytes long. */
static int zane_inside(int64_t offset, const int64_t *from, const int64_t *size, int64_t n) {
	for (int64_t i = 0; i < n; i++)
		if (offset >= from[i] && offset < from[i] + size[i]) return 1;
	return 0;
}

/* The value at `base` dies, but for the `n` hosts at `from` that floated:
   each block it owns is returned, once what lives in the block has died,
   and each host inside a block ends its identity. `identities` says whether
   the hosts held inline end theirs too, as at a drain, or are the caller's
   to keep or float, as at an overwrite. */
static void zane_end(char *base, const int64_t *layout, int identities, const int64_t *from,
                     const int64_t *length, int64_t n) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(base, &p) || zane_inside(p.offset, from, length, n)) continue;
		switch (p.kind) {
		case ZANE_HOST: {
			uint32_t id = *zane_backpointer(base, &p);
			if (identities && id) zane_retire(id);
			break;
		}
		case ZANE_TEXT: {
			zane_text *t = zane_at(base, &p);
			if (t->room) zane_unblock(&p, (void *)t->bytes, t->room);
			t->bytes = NULL;
			t->length = t->room = 0;
			break;
		}
		case ZANE_LIST: {
			zane_list *l = zane_at(base, &p);
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++)
					zane_end(l->items + i * p.extra, p.inner, 1, NULL, NULL, 0);
			if (l->room) zane_unblock(&p, l->items, l->room);
			l->items = NULL;
			l->count = l->room = 0;
			break;
		}
		case ZANE_BOX: {
			char **box = zane_at(base, &p);
			if (!*box) break;
			if (p.inner) zane_end(*box, p.inner, 1, NULL, NULL, 0);
			zane_unblock(&p, *box, 0);
			*box = NULL;
			break;
		}
		}
	}
}

/* How many blocks the value at `base` owns, down through them, counting
   only positions from `lo` up to `hi`. */
static int64_t zane_owned(char *base, const int64_t *layout, int64_t lo, int64_t hi) {
	int64_t n = 0;
	zane_position p;
	ZANE_EACH(layout, p) {
		if (p.offset < lo || p.offset >= hi || !zane_present(base, &p)) continue;
		if (p.kind == ZANE_TEXT) {
			n += ((zane_text *)zane_at(base, &p))->room != 0;
		} else if (p.kind == ZANE_LIST) {
			zane_list *l = zane_at(base, &p);
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++)
					n += zane_owned(l->items + i * p.extra, p.inner, 0, INT64_MAX);
			n += l->room != 0;
		} else if (p.kind == ZANE_BOX) {
			char *box = *(char **)zane_at(base, &p);
			if (box && p.inner) n += zane_owned(box, p.inner, 0, INT64_MAX);
			n += box != NULL;
		}
	}
	return n;
}

/* The scope a value is made in is the innermost; where it arrives decides
   where its blocks end up. */
static zane_mark *zane_here(void) { return zane_mark_at(zane_self, zane_self->depth - 1); }

/* The value at `value` was copied from another place: each block it names
   is still the original's, so it gets a copy of its own, down through the
   blocks inside it, and each host in it starts untethered (memory.md
   §2.3). */
void zane_copy(char *value, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(value, &p)) continue;
		switch (p.kind) {
		case ZANE_HOST:
			*zane_backpointer(value, &p) = 0;
			break;
		case ZANE_TEXT: {
			zane_text *t = zane_at(value, &p);
			if (!t->room) break;
			char *bytes = zane_alloc(zane_here(), t->length, 8);
			memcpy(bytes, t->bytes, (size_t)t->length);
			t->bytes = bytes;
			t->room = t->length;
			break;
		}
		case ZANE_LIST: {
			zane_list *l = zane_at(value, &p);
			if (!l->room) break;
			char *items = zane_alloc(zane_here(), l->room, ZANE_LINE);
			memcpy(items, l->items, (size_t)(l->count * p.extra));
			l->items = items;
			if (p.inner)
				for (int64_t i = 0; i < l->count; i++) zane_copy(items + i * p.extra, p.inner);
			break;
		}
		case ZANE_BOX: {
			char **box = zane_at(value, &p);
			if (!*box) break;
			char *payload = zane_alloc(zane_here(), p.extra, 8);
			memcpy(payload, *box, (size_t)p.extra);
			*box = payload;
			if (p.inner) zane_copy(payload, p.inner);
			break;
		}
		}
	}
}

/* A boxed member's block (memory.md §3.6): exactly one payload's size. */
void *zane_box(int64_t size, int64_t align) { return zane_alloc(zane_here(), size, align); }

/* `@runtime$Console`'s `print` (effects.md §6.6): exactly the string's
   length in bytes, with no terminator and nothing added. */
void zane_print(const zane_text *text) {
	fwrite(text->bytes, 1, (size_t)text->length, stdout);
}

/* `+` on `@primitives$String`: a new string that owns its bytes. */
void zane_text_join(zane_text *out, const zane_text *left, const zane_text *right) {
	int64_t length = left->length + right->length;
	if (length == 0) {
		*out = (zane_text){ 0, "", 0, 0 };
		return;
	}
	char *bytes = zane_alloc(zane_here(), length, 8);
	memcpy(bytes, left->bytes, (size_t)left->length);
	memcpy(bytes + left->length, right->bytes, (size_t)right->length);
	*out = (zane_text){ 0, bytes, length, length };
}

/* `==` on `@primitives$String`: the same bytes. */
int64_t zane_text_equal(const zane_text *left, const zane_text *right) {
	return left->length == right->length &&
	       memcmp(left->bytes, right->bytes, (size_t)left->length) == 0;
}

/* ---------------------------------------------------------------------- */
/* Values arriving, leaving and replaced (memory.md §3.5, §3.7, §4.5)     */
/* ---------------------------------------------------------------------- */

/* Whether a block must move into `region`: any block elsewhere when `from`
   is 0, and otherwise one in this context's scope `from` or a later one. */
static int zane_leaves(const void *block, zane_mark *region, int64_t from) {
	zane_mark *r = zane_region_at(block);
	return r != region && (from == 0 || (r->context == zane_self && r->depth >= from));
}

static void zane_move(char *value, const int64_t *layout, zane_mark *region, int64_t from);

/* The block that the handle or boxed member at `at` owns moves into
   `region` when it is in `from` or a later scope and not there already: an
   equal block there takes what lives in it, down through the blocks it
   owns, and the old one is returned (memory.md §3.5). */
static void zane_move_at(char *at, const zane_position *p, zane_mark *region, int64_t from) {
	switch (p->kind) {
	case ZANE_TEXT: {
		zane_text *t = (zane_text *)at;
		if (!t->room || !zane_leaves(t->bytes, region, from)) break;
		char *bytes = zane_alloc(region, t->room, 8);
		memcpy(bytes, t->bytes, (size_t)t->length);
		zane_unblock(p, (void *)t->bytes, t->room);
		t->bytes = bytes;
		break;
	}
	case ZANE_LIST: {
		zane_list *l = (zane_list *)at;
		if (!l->room || !zane_leaves(l->items, region, from)) break;
		char *items = zane_alloc(region, l->room, ZANE_LINE);
		memcpy(items, l->items, (size_t)(l->count * p->extra));
		zane_unblock(p, l->items, l->room);
		l->items = items;
		if (p->inner)
			for (int64_t i = 0; i < l->count; i++) zane_move(items + i * p->extra, p->inner, region, from);
		break;
	}
	case ZANE_BOX: {
		char **box = (char **)at;
		if (!*box || !zane_leaves(*box, region, from)) break;
		char *payload = zane_alloc(region, p->extra, 8);
		memcpy(payload, *box, (size_t)p->extra);
		zane_unblock(p, *box, 0);
		*box = payload;
		if (p->inner) zane_move(payload, p->inner, region, from);
		break;
	}
	}
}

/* The value at `value` is where it now lives: the anchors of the hosts it
   holds follow them there (§4.5), and every block it owns that is in
   `from` or a later scope moves into `region`. */
static void zane_move(char *value, const int64_t *layout, zane_mark *region, int64_t from) {
	zane_position p;
	ZANE_EACH(layout, p) {
		uint32_t id;
		if (!zane_present(value, &p)) continue;
		if (p.kind != ZANE_HOST) zane_move_at(zane_at(value, &p), &p, region, from);
		else if ((id = *zane_backpointer(value, &p))) zane_anchor(id)->target = value + p.offset;
	}
}

/* A value arrived at `slot`, which had no identity: the anchors it carries
   follow it there (§4.5), and the blocks it owns move into the region of
   the scope that holds the slot. */
void zane_arrive(char *slot, const int64_t *layout) {
	zane_move(slot, layout, zane_region_at(slot), 0);
}

/* A value leaves the scopes from `depth` in, which drain before it arrives
   anywhere: every block it owns in them moves into the scope around them
   first (§3.1). */
void zane_promote(char *value, const int64_t *layout, int64_t depth) {
	zane_move(value, layout, zane_mark_at(zane_self, depth - 1), depth);
}

/* A host moved out of `slot`: the slot is spent, and its identities and
   blocks left with the host. */
void zane_vacate(char *slot, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(slot, &p)) continue;
		switch (p.kind) {
		case ZANE_HOST:
			*zane_backpointer(slot, &p) = 0;
			break;
		case ZANE_TEXT:
		case ZANE_LIST: {
			zane_list *l = zane_at(slot, &p);
			l->items = NULL;
			l->count = l->room = 0;
			break;
		}
		case ZANE_BOX:
			*(char **)zane_at(slot, &p) = NULL;
			break;
		}
	}
}

/* Floated hosts, and the blocks they took along when they floated, which
   stay out until the program ends. */
static _Atomic int64_t zane_floated;

/* `incoming` replaces what `slot` holds (memory.md §3.7, §4.5). A contingent
   place's anchored occupant -- a variant payload's, or anything in a list's
   element when `contingent` is set -- first floats into an anonymous host in
   the program's own region, taking along the anchors of every host inside
   it, and its blocks, which move there too. What stays dies, and its blocks are
   returned. Then each stable host keeps its identity: the incoming one
   takes it, and an identity the incoming one brought forwards to it. A
   contingent one keeps the incoming host's own. What arrives moves its
   blocks into the slot's region. */
void zane_overwrite(char *slot, char *incoming, int64_t size, const int64_t *layout,
                    int64_t contingent) {
	zane_position p, q;
	int64_t positions = layout ? layout[0] : 0;
	int64_t n = 0, from[positions + 1], length[positions + 1];
	ZANE_EACH(layout, p) {
		uint32_t id;
		if ((p.conditions == 0 && !contingent) || !zane_hosts(slot, &p)) continue;
		if (zane_inside(p.offset, from, length, n)) continue;
		if (!(id = *zane_backpointer(slot, &p))) continue;
		/* A floated host is a block of the program's own region, so what
		   later arrives in it, or grows from it, is placed there too. It
		   lives until the program ends, and so do its blocks
		   (docs/lowering.md §9). */
		char *anonymous = zane_alloc(zane_program, p.size, 8);
		memcpy(anonymous, slot + p.offset, (size_t)p.size);
		zane_floated += 1 + zane_owned(slot, layout, p.offset, p.offset + p.size);
		ZANE_EACH(layout, q) {
			uint32_t inner;
			if (q.offset < p.offset || q.offset >= p.offset + p.size) continue;
			if (!zane_present(slot, &q)) continue;
			char *at = anonymous + (q.offset - p.offset);
			if (q.kind != ZANE_HOST) zane_move_at(at, &q, zane_program, 0);
			else if ((inner = *zane_backpointer(slot, &q))) zane_anchor(inner)->target = at;
		}
		from[n] = p.offset;
		length[n++] = p.size;
	}
	zane_end(slot, layout, 0, from, length, n);
	ZANE_EACH(layout, p) {
		if (!zane_hosts(incoming, &p)) continue;
		uint32_t *brought = zane_backpointer(incoming, &p);
		uint32_t kept = p.conditions == 0 && !contingent ? *zane_backpointer(slot, &p) : 0;
		if (kept) {
			if (*brought && *brought != kept) {
				pthread_mutex_lock(&zane_anchors);
				zane_anchor(*brought)->forward = kept;
				zane_anchor(*brought)->sibling = zane_anchor(kept)->forwarders;
				zane_anchor(kept)->forwarders = *brought;
				pthread_mutex_unlock(&zane_anchors);
			}
			*brought = kept;
		}
	}
	memcpy(slot, incoming, (size_t)size);
	zane_arrive(slot, layout);
}

/* ---------------------------------------------------------------------- */
/* Lists (memory.md §3.6)                                                 */
/* ---------------------------------------------------------------------- */

/* An index outside a list (docs/lowering.md §9): what the program wrote so
   far is kept, and it stops with a failing status. */
static void zane_out_of_range(void) {
	fflush(stdout);
	fputs("index out of range\n", stderr);
	exit(1);
}

/* `@primitives$List(T)`: empty, owning no block. */
void zane_list_new(zane_list *out) { *out = (zane_list){ 0, NULL, 0, 0 }; }

/* Room for one more element, `stride` bytes wide, at the end: the address
   the caller then moves it into. A full list's block doubles, from 128
   bytes, in the region of the scope that holds the list (§3.6): into a
   returned block of that size, or in place when it is the last thing at
   the region's frontier with room after it in its chunk, or else into new
   bytes there. Elements that move take their anchors along, as `layout`
   says. */
void *zane_list_push(zane_list *list, int64_t stride, const int64_t *layout) {
	int64_t needed = (list->count + 1) * stride;
	if (needed > list->room) {
		int64_t room = list->room ? list->room * 2 : 128;
		while (room < needed) room *= 2;
		zane_mark *region = zane_region_at(list->room ? (void *)list->items : (void *)list);
		zane_lock(region->context);
		zane_stack *s = zane_find_stack(region, room, ZANE_LINE);
		int grows = !(s && s->top) && list->room &&
		            list->items + list->room == region->chunk + region->bumped &&
		            region->bumped + (size_t)(room - list->room) <= ZANE_CHUNK;
		/* The block grows where it is, so nothing in it moves. */
		if (grows) region->bumped += (size_t)(room - list->room);
		zane_unlock(region->context);
		if (grows) {
			list->room = room;
		} else {
			char *items = zane_alloc(region, room, ZANE_LINE);
			if (list->count) memcpy(items, list->items, (size_t)(list->count * stride));
			if (list->room) zane_free(list->items, list->room, ZANE_LINE);
			list->items = items;
			list->room = room;
			if (layout)
				for (int64_t i = 0; i < list->count; i++)
					zane_move(items + i * stride, layout, region, 0);
		}
	}
	return list->items + list->count++ * stride;
}

/* The element at `index`, counted from 1 (control-flow.md §3.4). */
void *zane_list_at(zane_list *list, int64_t index, int64_t stride) {
	if (index < 1 || index > list->count) zane_out_of_range();
	return list->items + (index - 1) * stride;
}

/* ---------------------------------------------------------------------- */
/* Slots and drains (memory.md §3.2, docs/lowering.md L8)                 */
/* ---------------------------------------------------------------------- */

/* A zeroed slot in the innermost scope's arena, which is the only one a
   program ever places a slot in. A slot holding hosts or blocks is listed,
   with its layout, so the drain can end the identities and return the
   blocks; one filled later holds nothing until then. */
void *zane_slot(int64_t scope, int64_t size, int64_t align, const int64_t *layout) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1) zane_broken("a slot placed in a scope that is not innermost");
	zane_mark *m = zane_mark_at(c, scope);
	zane_lock(c);
	char *slot = zane_bump(size, align);
	memset(slot, 0, (size_t)size);
	if (layout && layout[0] > 0) {
		zane_hosted *h = zane_bump(sizeof *h, 8);
		*h = (zane_hosted){ m->hosts, slot, layout };
		m->hosts = h;
	}
	zane_unlock(c);
	return slot;
}

/* ---------------------------------------------------------------------- */
/* Spawned calls (concurrency.md §3–4, docs/lowering.md §9)               */
/* ---------------------------------------------------------------------- */

/* A spawned call. Its frame -- room for its result, then its arguments --
   follows this header in the fixed region of the scope that spawned it,
   which waits for it before it drains (§4.1). The call runs in a context of
   its own, which it keeps until its result comes home: copied to `dest`,
   `size` bytes laid out as `layout` says, where its anchors follow it and
   its blocks move into the destination's region. */
struct zane_task {
	zane_task *next;           /* the next the same scope spawned */
	zane_task *before, *after; /* in the queue, while queued */
	void (*run)(char *frame);
	char *frame, *dest;
	const int64_t *layout;
	int64_t size;
	zane_context *owner, *context;
	int state;
};

enum { ZANE_QUEUED, ZANE_RUNNING, ZANE_DONE, ZANE_JOINED };

/* The pool: calls waiting for a thread, first spawned first, and the
   threads that run them, started with the first spawn. It keeps `wanted`
   threads, one per processor until the program sets a number (§2.4), and
   a thread over that number leaves when it next looks for work. */
static pthread_mutex_t zane_pool = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t zane_waiting = PTHREAD_COND_INITIALIZER;
static pthread_cond_t zane_finished = PTHREAD_COND_INITIALIZER;
static zane_task *zane_first, *zane_last;
static int zane_started;
static int64_t zane_threads, zane_wanted;

/* A queued call taken off the queue to run; the pool's lock is held. */
static void zane_take(zane_task *t) {
	if (t->before) t->before->after = t->after;
	else zane_first = t->after;
	if (t->after) t->after->before = t->before;
	else zane_last = t->before;
	t->before = t->after = NULL;
	t->state = ZANE_RUNNING;
}

/* A call run on this thread, in a context of its own whose first scope
   holds its result's blocks until the result comes home. */
static void zane_run(zane_task *t) {
	zane_context *outer = zane_self;
	zane_self = t->context = zane_context_new();
	zane_scope_enter();
	t->run(t->frame);
	zane_self = outer;
	pthread_mutex_lock(&zane_pool);
	t->state = ZANE_DONE;
	pthread_cond_broadcast(&zane_finished);
	pthread_mutex_unlock(&zane_pool);
}

static void *zane_worker(void *unused) {
	(void)unused;
	pthread_mutex_lock(&zane_pool);
	for (;;) {
		while (!zane_first && zane_threads <= zane_wanted)
			pthread_cond_wait(&zane_waiting, &zane_pool);
		if (zane_threads > zane_wanted) {
			zane_threads--;
			pthread_mutex_unlock(&zane_pool);
			return NULL;
		}
		zane_task *t = zane_first;
		zane_take(t);
		pthread_mutex_unlock(&zane_pool);
		zane_run(t);
		pthread_mutex_lock(&zane_pool);
	}
	return NULL;
}

/* One thread for each processor. */
static int64_t zane_processors(void) {
	long n = sysconf(_SC_NPROCESSORS_ONLN);
	return n < 1 ? 1 : n;
}

/* Threads started until the pool has as many as it wants, and those over
   it woken to leave; the pool's lock is held. */
static void zane_fill(void) {
	for (; zane_threads < zane_wanted; zane_threads++) {
		pthread_t thread;
		if (pthread_create(&thread, NULL, zane_worker, NULL) != 0)
			zane_broken("no thread for the pool");
		pthread_detach(thread);
	}
	pthread_cond_broadcast(&zane_waiting);
}

static void zane_start(void) {
	if (!zane_wanted) zane_wanted = zane_processors();
	zane_started = 1;
	zane_fill();
}

/* `@runtime$Runtime`'s `setThreads` and `setThreadsAuto` (§2.4): the pool
   resized, now or when it starts. A count below one resizes nothing, and
   the call aborts: 0 says so. */
int64_t zane_set_threads(int64_t count) {
	if (count < 1) return 0;
	pthread_mutex_lock(&zane_pool);
	zane_wanted = count;
	if (zane_started) zane_fill();
	pthread_mutex_unlock(&zane_pool);
	return 1;
}

void zane_set_threads_auto(void) { zane_set_threads(zane_processors()); }

/* A new call's frame, `size` bytes, in the innermost scope's fixed region. */
void *zane_frame(int64_t scope, int64_t size, int64_t align) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1) zane_broken("a call spawned from a scope that is not innermost");
	if (align > 8) zane_broken("a spawned call's frame aligned past a word");
	zane_lock(c);
	zane_task *t = zane_bump((int64_t)sizeof *t + size, 8);
	zane_unlock(c);
	memset(t, 0, sizeof *t);
	t->frame = (char *)(t + 1);
	return t->frame;
}

/* The call whose frame is filled starts (§3.6): the innermost scope waits
   for it, and from now its context is shared. */
void zane_spawn(char *frame, void (*run)(char *), char *dest, const int64_t *layout,
                int64_t size) {
	zane_task *t = (zane_task *)frame - 1;
	zane_context *c = zane_self;
	zane_mark *m = zane_mark_at(c, c->depth - 1);
	t->run = run;
	t->dest = dest;
	t->layout = layout;
	t->size = size;
	t->owner = c;
	t->next = m->tasks;
	m->tasks = t;
	c->shared++;
	pthread_mutex_lock(&zane_pool);
	if (!zane_started) zane_start();
	t->state = ZANE_QUEUED;
	t->before = zane_last;
	if (zane_last) zane_last->after = t;
	else zane_first = t;
	zane_last = t;
	pthread_cond_signal(&zane_waiting);
	pthread_mutex_unlock(&zane_pool);
}

/* A context whose call is over, back in the pool: by now its first scope
   holds nothing, since the result took its blocks home. */
static void zane_release(zane_context *c) {
	zane_mark *m = zane_mark_at(c, 0);
	for (zane_hosted *h = m->hosts; h; h = h->next) zane_end(h->slot, h->layout, 1, NULL, NULL, 0);
	zane_lock(c);
	if (m->live != 0) zane_broken("a dynamic block outlived its owner");
	zane_unmap(m);
	c->depth = 0;
	c->chunks = 0;
	c->frontier = 0;
	zane_unlock(c);
	pthread_mutex_lock(&zane_memory);
	c->next = zane_idle;
	zane_idle = c;
	pthread_mutex_unlock(&zane_memory);
}

/* Waiting for a call (§3.2): one no thread has taken yet runs here, and one
   running elsewhere is waited for. Its result then comes home, once. */
static void zane_join_task(zane_task *t) {
	if (t->owner != zane_self) zane_broken("a spawned call joined outside its context");
	pthread_mutex_lock(&zane_pool);
	if (t->state == ZANE_JOINED) {
		pthread_mutex_unlock(&zane_pool);
		return;
	}
	if (t->state == ZANE_QUEUED) {
		zane_take(t);
		pthread_mutex_unlock(&zane_pool);
		zane_run(t);
		pthread_mutex_lock(&zane_pool);
	}
	while (t->state != ZANE_DONE) pthread_cond_wait(&zane_finished, &zane_pool);
	t->state = ZANE_JOINED;
	pthread_mutex_unlock(&zane_pool);
	if (t->size) {
		memcpy(t->dest, t->frame, (size_t)t->size);
		zane_arrive(t->dest, t->layout);
	}
	zane_release(t->context);
	t->owner->shared--;
}

/* A read of what a spawned call returns. */
void zane_join(char *frame) { zane_join_task((zane_task *)frame - 1); }

/* Every identity the scope still hosts ends: its anchors, and the
   forwarders to them, retire. The blocks its values still own are
   returned, and by then no block is out in its region, since every one has
   an owner in the scope or has moved out with it. Then both regions are
   released together. First, as the water tower has it (§4.1), the scope
   waits for every call it spawned, and each result comes home. */
void zane_scope_drain(int64_t scope) {
	zane_context *c = zane_self;
	if (scope != c->depth - 1 || scope == 0) zane_broken("a scope drained out of order");
	zane_mark *m = zane_mark_at(c, scope);
	for (zane_task *t = m->tasks; t; t = t->next) zane_join_task(t);
	for (zane_hosted *h = m->hosts; h; h = h->next) zane_end(h->slot, h->layout, 1, NULL, NULL, 0);
	zane_lock(c);
	if (m->live != 0) zane_broken("a dynamic block outlived its owner");
	zane_unmap(m);
	c->depth--;
	c->chunks = m->chunks;
	c->frontier = m->frontier;
	zane_unlock(c);
}

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. The program's own scope is open
   around `main`, and when it returns every other scope has drained, and
   every call it spawned has returned. What its own region still holds --
   floated hosts, and what they own, which may have changed since they
   floated -- goes with the program. */
int main(void) {
	zane_self = zane_context_new();
	zane_scope_enter();
	zane_program = zane_mark_at(zane_self, 0);
	zane_main();
	if (zane_self->depth != 1) zane_broken("a scope was left without draining");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
