/* The Zane runtime (docs/lowering.md L17): what every program links with.

   A program's `main` is `zane_main`, which the C `main` below calls once the
   runtime is ready. Everything else here is what an intrinsic lowers to. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
   blocks for each size and alignment (§3.2), all given back at the drain. */
enum { ZANE_CHUNK = 1 << 20, ZANE_CHUNKS = 1 << 15, ZANE_LINE = 64 };

static char *zane_directory[ZANE_CHUNKS];
static uint32_t zane_chunks;   /* fixed chunks in use: the current one is the last */
static size_t zane_frontier;   /* the next free byte in the current fixed chunk */

/* Which region every chunk belongs to, by its address over 1 MiB: 0 for
   none, a fixed chunk's index plus one, or minus one less than a dynamic
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
	if (!*level) {
		if (!make) return NULL;
		*level = calloc(ZANE_PAGES, sizeof **level);
		if (!*level) zane_broken("out of memory for the chunk map");
	}
	return *level + page % ZANE_PAGES;
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

/* Each open scope, innermost last: where its slots began, what it hosts,
   and its dynamic region with the number of blocks out in it. The first is
   the program's own, open until it ends. */
typedef struct {
	uint32_t chunks;
	size_t frontier;
	zane_hosted *hosts;
	zane_mapping *mappings;
	char *chunk;
	size_t bumped;
	zane_stack *stacks;
	int64_t live;
} zane_mark;

static zane_mark *zane_marks;
static int64_t zane_depth, zane_room;

/* Dynamic chunks a drained region gave back, ready for the next. */
static zane_mapping *zane_spare;

int64_t zane_scope_enter(void) {
	if (zane_depth == zane_room) {
		zane_room = zane_room ? zane_room * 2 : 64;
		zane_mark *marks = realloc(zane_marks, (size_t)zane_room * sizeof *zane_marks);
		if (!marks) zane_broken("out of memory for scopes");
		zane_marks = marks;
	}
	zane_marks[zane_depth] = (zane_mark){ zane_chunks, zane_frontier, NULL, NULL, NULL, 0, NULL, 0 };
	return zane_depth++;
}

static void *zane_bump(int64_t size, int64_t align) {
	if (size > ZANE_CHUNK) zane_broken("a slot larger than a chunk");
	size_t start = (zane_frontier + (size_t)align - 1) / (size_t)align * (size_t)align;
	if (zane_chunks == 0 || start + (size_t)size > ZANE_CHUNK) {
		if (zane_chunks == ZANE_CHUNKS) zane_broken("out of chunks");
		if (!zane_directory[zane_chunks]) {
			zane_directory[zane_chunks] = aligned_alloc(ZANE_CHUNK, ZANE_CHUNK);
			if (!zane_directory[zane_chunks]) zane_broken("out of memory for a chunk");
			*zane_page(zane_directory[zane_chunks], 1) = (int32_t)zane_chunks + 1;
		}
		zane_chunks++;
		start = 0;
	}
	zane_frontier = start + (size_t)size;
	return zane_directory[zane_chunks - 1] + start;
}

/* The scope whose region holds `at`: the one that owns the dynamic chunk
   it is in, or the innermost whose slots began at or before it in the
   fixed chain. Anything else, such as a value on the machine stack, is the
   innermost scope's. */
static int64_t zane_region_of(const void *at) {
	int32_t *entry = zane_page(at, 0);
	if (!entry || *entry == 0) return zane_depth - 1;
	if (*entry < 0) return -(int64_t)*entry - 1;
	int64_t chunk = *entry - 1;
	int64_t position = chunk * ZANE_CHUNK + ((const char *)at - zane_directory[chunk]);
	int64_t lo = 0, hi = zane_depth - 1;
	while (lo < hi) {
		int64_t mid = (lo + hi + 1) / 2;
		zane_mark *m = &zane_marks[mid];
		int64_t start = m->chunks ? (int64_t)(m->chunks - 1) * ZANE_CHUNK + (int64_t)m->frontier : 0;
		if (start <= position) lo = mid;
		else hi = mid - 1;
	}
	return lo;
}

/* Every block is at least a word, and aligned to one. */
static int64_t zane_word(int64_t n) { return n < 8 ? 8 : (n + 7) / 8 * 8; }

/* Chunks of its own for one region: `size` bytes in all, a whole number of
   chunks, listed in the chunk map as the region's. */
static zane_mapping *zane_map(int64_t region, size_t size) {
	zane_mapping *m;
	if (size == ZANE_CHUNK && zane_spare) {
		m = zane_spare;
		zane_spare = m->next;
	} else {
		m = aligned_alloc(ZANE_CHUNK, size);
		if (!m) zane_broken("out of memory for a dynamic chunk");
	}
	for (size_t at = 0; at < size; at += ZANE_CHUNK)
		*zane_page((char *)m + at, 1) = -(int32_t)region - 1;
	m->size = size;
	m->next = zane_marks[region].mappings;
	zane_marks[region].mappings = m;
	return m;
}

/* Bytes from a region's frontier, which moves to a fresh chunk when the
   current one cannot hold them. A block too large for any chunk is an
   oversized one, with chunks of its own (§3.1). */
static char *zane_frontier_of(int64_t region, int64_t size, int64_t align) {
	zane_mark *m = &zane_marks[region];
	if (size > ZANE_CHUNK - ZANE_LINE) {
		size_t chunks = ((size_t)size + ZANE_LINE + ZANE_CHUNK - 1) / ZANE_CHUNK;
		return (char *)zane_map(region, chunks * ZANE_CHUNK) + ZANE_LINE;
	}
	size_t start = (m->bumped + (size_t)align - 1) / (size_t)align * (size_t)align;
	if (!m->chunk || start + (size_t)size > ZANE_CHUNK) {
		m->chunk = (char *)zane_map(region, ZANE_CHUNK);
		start = ZANE_LINE;
	}
	m->bumped = start + (size_t)size;
	return m->chunk + start;
}

/* A region's stack of returned blocks of one size and alignment, if any
   has been returned there. */
static zane_stack *zane_find_stack(int64_t region, int64_t size, int64_t align) {
	for (zane_stack *s = zane_marks[region].stacks; s; s = s->next)
		if (s->size == size && s->align == align) return s;
	return NULL;
}

/* The same stack, made the first time a block is returned to it. */
static zane_stack *zane_stack_of(int64_t region, int64_t size, int64_t align) {
	zane_mark *m = &zane_marks[region];
	zane_stack *s = zane_find_stack(region, size, align);
	if (s) return s;
	s = (zane_stack *)zane_frontier_of(region, sizeof *s, 8);
	*s = (zane_stack){ m->stacks, size, align, NULL };
	m->stacks = s;
	return s;
}

/* How many blocks are out, in every open region. */
static int64_t zane_blocks;

/* A block in a region: one returned there of the same size and alignment,
   or else new bytes from its frontier (§3.2). */
static char *zane_alloc(int64_t region, int64_t size, int64_t align) {
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_stack *s = zane_find_stack(region, size, align);
	char *block = s ? s->top : NULL;
	if (block) s->top = *(char **)block;
	else block = zane_frontier_of(region, size, align);
	zane_marks[region].live++;
	zane_blocks++;
	return block;
}

/* A block returned to its region, for the next of its size and alignment. */
static void zane_free(char *block, int64_t size, int64_t align) {
	int64_t region = zane_region_of(block);
	size = zane_word(size);
	if (align < 8) align = 8;
	zane_stack *s = zane_stack_of(region, size, align);
	*(char **)block = s->top;
	s->top = block;
	zane_marks[region].live--;
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

#define ZANE_EACH(layout, p)                                                        \
	for (int64_t zane_cursor = 1, zane_left = (layout)[0];                          \
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

static zane_cell *zane_cells;
static uint32_t zane_cell_count = 1, zane_cell_room;
static uint32_t zane_free_cell;  /* a stack of returned cells, linked by `sibling` */

static uint32_t zane_new_cell(void *target) {
	uint32_t id = zane_free_cell;
	if (id) {
		zane_free_cell = zane_cells[id].sibling;
	} else {
		if (zane_cell_count >= zane_cell_room) {
			zane_cell_room = zane_cell_room ? zane_cell_room * 2 : 1024;
			zane_cell *cells = realloc(zane_cells, (size_t)zane_cell_room * sizeof *zane_cells);
			if (!cells) zane_broken("out of memory for anchors");
			zane_cells = cells;
		}
		id = zane_cell_count++;
	}
	zane_cells[id] = (zane_cell){ target, 0, 0, 0 };
	return id;
}

static void zane_retire(uint32_t id) {
	uint32_t f = zane_cells[id].forwarders;
	while (f) {
		uint32_t next = zane_cells[f].sibling;
		zane_retire(f);
		f = next;
	}
	zane_cells[id].sibling = zane_free_cell;
	zane_free_cell = id;
}

/* The identity a tether ends at, following forwarders. */
uint32_t zane_terminal(uint32_t tether) {
	if (tether == 0) zane_broken("an untethered guest");
	while (zane_cells[tether].forward) tether = zane_cells[tether].forward;
	return tether;
}

/* The address a guest names. */
void *zane_resolve(uint32_t tether) { return zane_cells[zane_terminal(tether)].target; }

/* A guest to the host at `payload`: its anchor, made the first time. */
uint32_t zane_mint(void *payload) {
	uint32_t *backpointer = payload;
	if (*backpointer == 0) *backpointer = zane_new_cell(payload);
	return *backpointer;
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
static int64_t zane_here(void) { return zane_depth - 1; }

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

/* Whether a block in `from` or a later scope must move into `region`. */
static int zane_leaves(const void *block, int64_t region, int64_t from) {
	int64_t r = zane_region_of(block);
	return r != region && r >= from;
}

static void zane_move(char *value, const int64_t *layout, int64_t region, int64_t from);

/* The block that the handle or boxed member at `at` owns moves into
   `region` when it is in `from` or a later scope and not there already: an
   equal block there takes what lives in it, down through the blocks it
   owns, and the old one is returned (memory.md §3.5). */
static void zane_move_at(char *at, const zane_position *p, int64_t region, int64_t from) {
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
static void zane_move(char *value, const int64_t *layout, int64_t region, int64_t from) {
	zane_position p;
	ZANE_EACH(layout, p) {
		uint32_t id;
		if (!zane_present(value, &p)) continue;
		if (p.kind != ZANE_HOST) zane_move_at(zane_at(value, &p), &p, region, from);
		else if ((id = *zane_backpointer(value, &p))) zane_cells[id].target = value + p.offset;
	}
}

/* A value arrived at `slot`, which had no identity: the anchors it carries
   follow it there (§4.5), and the blocks it owns move into the region of
   the scope that holds the slot. */
void zane_arrive(char *slot, const int64_t *layout) {
	zane_move(slot, layout, zane_region_of(slot), 0);
}

/* A value leaves the scopes from `depth` in, which drain before it arrives
   anywhere: every block it owns in them moves into the scope around them
   first (§3.1). */
void zane_promote(char *value, const int64_t *layout, int64_t depth) {
	zane_move(value, layout, depth - 1, depth);
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

/* The blocks floated hosts took along, which stay out until the program
   ends. */
static int64_t zane_floated;

/* `incoming` replaces what `slot` holds (memory.md §3.7, §4.5). A contingent
   place's anchored occupant -- a variant payload's, or anything in a list's
   element when `contingent` is set -- first floats into an anonymous host,
   taking along the anchors of every host inside it, and its blocks, which
   move into the program's own region. What stays dies, and its blocks are
   returned. Then each stable host keeps its identity: the incoming one
   takes it, and an identity the incoming one brought forwards to it. A
   contingent one keeps the incoming host's own. What arrives moves its
   blocks into the slot's region. */
void zane_overwrite(char *slot, char *incoming, int64_t size, const int64_t *layout,
                    int64_t contingent) {
	zane_position p, q;
	int64_t n = 0, from[layout[0] + 1], length[layout[0] + 1];
	ZANE_EACH(layout, p) {
		uint32_t id;
		if ((p.conditions == 0 && !contingent) || !zane_hosts(slot, &p)) continue;
		if (zane_inside(p.offset, from, length, n)) continue;
		if (!(id = *zane_backpointer(slot, &p))) continue;
		char *anonymous = malloc((size_t)p.size);
		if (!anonymous) zane_broken("out of memory for a floating host");
		memcpy(anonymous, slot + p.offset, (size_t)p.size);
		/* A floated host lives until the program ends, and so do its blocks
		   (docs/lowering.md §9). */
		zane_floated += zane_owned(slot, layout, p.offset, p.offset + p.size);
		ZANE_EACH(layout, q) {
			uint32_t inner;
			if (q.offset < p.offset || q.offset >= p.offset + p.size) continue;
			if (!zane_present(slot, &q)) continue;
			char *at = anonymous + (q.offset - p.offset);
			if (q.kind != ZANE_HOST) zane_move_at(at, &q, 0, 1);
			else if ((inner = *zane_backpointer(slot, &q))) zane_cells[inner].target = at;
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
				zane_cells[*brought].forward = kept;
				zane_cells[*brought].sibling = zane_cells[kept].forwarders;
				zane_cells[kept].forwarders = *brought;
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
		int64_t region = zane_region_of(list->room ? (void *)list->items : (void *)list);
		zane_mark *m = &zane_marks[region];
		zane_stack *s = zane_find_stack(region, room, ZANE_LINE);
		if (!(s && s->top) && list->room && list->items + list->room == m->chunk + m->bumped &&
		    m->bumped + (size_t)(room - list->room) <= ZANE_CHUNK) {
			/* The block grows where it is, so nothing in it moves. */
			m->bumped += (size_t)(room - list->room);
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
	if (scope != zane_depth - 1) zane_broken("a slot placed in a scope that is not innermost");
	char *slot = zane_bump(size, align);
	memset(slot, 0, (size_t)size);
	if (layout && layout[0] > 0) {
		zane_hosted *h = zane_bump(sizeof *h, 8);
		*h = (zane_hosted){ zane_marks[scope].hosts, slot, layout };
		zane_marks[scope].hosts = h;
	}
	return slot;
}

/* Every identity the scope still hosts ends: its anchors, and the
   forwarders to them, retire. The blocks its values still own are
   returned, and by then no block is out in its region, since every one has
   an owner in the scope or has moved out with it. Then both regions are
   released together. */
void zane_scope_drain(int64_t scope) {
	if (scope != zane_depth - 1 || scope == 0) zane_broken("a scope drained out of order");
	zane_mark *m = &zane_marks[scope];
	for (zane_hosted *h = m->hosts; h; h = h->next) zane_end(h->slot, h->layout, 1, NULL, NULL, 0);
	if (m->live != 0) zane_broken("a dynamic block outlived its owner");
	while (m->mappings) {
		zane_mapping *next = m->mappings->next;
		for (size_t at = 0; at < m->mappings->size; at += ZANE_CHUNK)
			*zane_page((char *)m->mappings + at, 0) = 0;
		if (m->mappings->size == ZANE_CHUNK) {
			m->mappings->next = zane_spare;
			zane_spare = m->mappings;
		} else {
			free(m->mappings);
		}
		m->mappings = next;
	}
	zane_depth--;
	zane_chunks = m->chunks;
	zane_frontier = m->frontier;
}

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. The program's own scope is open
   around `main`, and when it returns every other scope has drained, and
   every block is back but those floated hosts took along. */
int main(void) {
	zane_scope_enter();
	zane_main();
	if (zane_depth != 1) zane_broken("a scope was left without draining");
	if (zane_marks[0].live != zane_floated) zane_broken("a dynamic block outlived its owner");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
