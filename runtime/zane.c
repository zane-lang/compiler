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

/* Memory comes in 1 MiB chunks, each named by its id in the chunk
   directory, so a segmented offset (a chunk id and a word offset) can name
   any slot. Scopes nest last-in-first-out, and so do their arenas: a scope
   bumps from where the scope around it stopped, and draining it returns
   everything after that point at once (docs/lowering.md §9). A chunk stays
   mapped once made, and the next scope that reaches its id reuses it. */
enum { ZANE_CHUNK = 1 << 20, ZANE_CHUNKS = 1 << 15 };

static char *zane_directory[ZANE_CHUNKS];
static uint32_t zane_chunks;   /* chunks in use: the current one is the last */
static size_t zane_frontier;   /* the next free byte in the current chunk */

/* A host placed in a scope, with where its contained hosts' backpointers
   are, so the scope's drain can end their identities. It lives in the
   scope's own arena. */
typedef struct zane_hosted {
	struct zane_hosted *next;
	char *slot;
	const int64_t *layout;
} zane_hosted;

/* Where each open scope began, innermost last, and what it hosts. */
typedef struct {
	uint32_t chunks;
	size_t frontier;
	zane_hosted *hosts;
} zane_mark;

static zane_mark *zane_marks;
static int64_t zane_depth, zane_room;

int64_t zane_scope_enter(void) {
	if (zane_depth == zane_room) {
		zane_room = zane_room ? zane_room * 2 : 64;
		zane_mark *marks = realloc(zane_marks, (size_t)zane_room * sizeof *zane_marks);
		if (!marks) zane_broken("out of memory for scopes");
		zane_marks = marks;
	}
	zane_marks[zane_depth] = (zane_mark){ zane_chunks, zane_frontier, NULL };
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
		}
		zane_chunks++;
		start = 0;
	}
	zane_frontier = start + (size_t)size;
	return zane_directory[zane_chunks - 1] + start;
}

/* ---------------------------------------------------------------------- */
/* Anchors and tethers (memory.md §4, docs/lowering.md §9)                */
/* ---------------------------------------------------------------------- */

/* A reference-type instance begins with a `u32` backpointer, and so does
   every host it contains; a handle that owns a block names it. A layout
   lists where they are: a count, then for each position, outermost first,
   its kind, its offset, its size, and the variant tags that must be live
   for it to be there, as a count and then (tag offset, tag) pairs. A host
   under no tag is stable; one under a tag is a variant payload, a
   contingent place (memory.md §2.2). */
enum { ZANE_HOST = 0, ZANE_TEXT = 1 };

typedef struct {
	int64_t kind, offset, size, conditions;
	const int64_t *tags;
} zane_position;

static int zane_next_position(const int64_t *layout, int64_t *cursor, int64_t *left,
                              zane_position *p) {
	if (*left == 0) return 0;
	const int64_t *at = layout + *cursor;
	*p = (zane_position){ at[0], at[1], at[2], at[3], at + 4 };
	*cursor += 4 + 2 * at[3];
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

/* `@primitives$String`, the string view: a reference type whose instance is
   its backpointer and a handle to its bytes, with no terminator. `room` is
   the size of the block the handle owns, or 0 when it owns none: a
   literal's bytes are the program's own and are never returned. */
typedef struct {
	uint32_t bp;
	const char *bytes;
	int64_t length, room;
} zane_text;

/* A block belongs to the handle that names it, and is returned when that
   handle's owner dies. The count is how many are out, which is 0 once every
   scope has drained, except for those a floated host took along. */
static int64_t zane_blocks;

static char *zane_block(int64_t size) {
	char *block = malloc((size_t)size);
	if (!block) zane_broken("out of memory for a dynamic block");
	zane_blocks++;
	return block;
}

static void zane_unblock(const void *block) {
	free((void *)block);
	zane_blocks--;
}

static zane_text *zane_text_at(char *base, const zane_position *p) {
	return (zane_text *)(base + p->offset);
}

/* Whether `offset` is inside one of the `n` hosts that start at `from`,
   each `size` bytes long. */
static int zane_inside(int64_t offset, const int64_t *from, const int64_t *size, int64_t n) {
	for (int64_t i = 0; i < n; i++)
		if (offset >= from[i] && offset < from[i] + size[i]) return 1;
	return 0;
}

/* The value at `base` died: every block it owns is returned. */
static void zane_release(char *base, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (p.kind != ZANE_TEXT || !zane_present(base, &p)) continue;
		zane_text *t = zane_text_at(base, &p);
		if (t->room) zane_unblock(t->bytes);
		t->bytes = NULL;
		t->length = t->room = 0;
	}
}

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
	char *bytes = zane_block(length);
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
/* Hosts arriving, leaving and replaced (memory.md §3.7, §4.5)            */
/* ---------------------------------------------------------------------- */

/* A host arrived at `slot`, which had no identity: the anchors it carries
   follow it there (§4.5). */
void zane_arrive(char *slot, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		uint32_t id;
		if (zane_hosts(slot, &p) && (id = *zane_backpointer(slot, &p)))
			zane_cells[id].target = slot + p.offset;
	}
}

/* A host moved out of `slot`: the slot is spent, and its identities and
   blocks left with the host. */
void zane_vacate(char *slot, const int64_t *layout) {
	zane_position p;
	ZANE_EACH(layout, p) {
		if (!zane_present(slot, &p)) continue;
		if (p.kind == ZANE_HOST) {
			*zane_backpointer(slot, &p) = 0;
		} else {
			zane_text *t = zane_text_at(slot, &p);
			t->bytes = NULL;
			t->length = t->room = 0;
		}
	}
}

/* `incoming` replaces what `slot` holds (memory.md §3.7, §4.5). A variant
   payload's anchored occupant first floats into an anonymous host, taking
   the anchors of every host inside it along, and its blocks. What stays
   dies, and its blocks are returned. Then each stable host keeps its
   identity: the incoming one takes it, and an identity the incoming one
   brought forwards to it. A payload keeps the incoming host's own. */
void zane_overwrite(char *slot, char *incoming, int64_t size, const int64_t *layout) {
	zane_position p, q;
	int64_t n = 0, from[layout[0] + 1], length[layout[0] + 1];
	ZANE_EACH(layout, p) {
		uint32_t id;
		if (p.conditions == 0 || !zane_hosts(slot, &p)) continue;
		if (zane_inside(p.offset, from, length, n)) continue;
		if (!(id = *zane_backpointer(slot, &p))) continue;
		char *anonymous = malloc((size_t)p.size);
		if (!anonymous) zane_broken("out of memory for a floating host");
		memcpy(anonymous, slot + p.offset, (size_t)p.size);
		ZANE_EACH(layout, q) {
			uint32_t inner;
			if (q.offset < p.offset || q.offset >= p.offset + p.size) continue;
			if (!zane_present(slot, &q)) continue;
			/* A floated host lives until the program ends, and so do its
			   blocks (docs/lowering.md §9). */
			if (q.kind == ZANE_TEXT && zane_text_at(slot, &q)->room) zane_blocks--;
			if (zane_hosts(slot, &q) && (inner = *zane_backpointer(slot, &q)))
				zane_cells[inner].target = anonymous + (q.offset - p.offset);
		}
		from[n] = p.offset;
		length[n++] = p.size;
	}
	ZANE_EACH(layout, p) {
		if (p.kind != ZANE_TEXT || zane_inside(p.offset, from, length, n)) continue;
		if (!zane_present(slot, &p)) continue;
		zane_text *t = zane_text_at(slot, &p);
		if (t->room) zane_unblock(t->bytes);
	}
	ZANE_EACH(layout, p) {
		if (!zane_hosts(incoming, &p)) continue;
		uint32_t *brought = zane_backpointer(incoming, &p);
		uint32_t kept = p.conditions == 0 ? *zane_backpointer(slot, &p) : 0;
		if (kept) {
			if (*brought && *brought != kept) {
				zane_cells[*brought].forward = kept;
				zane_cells[*brought].sibling = zane_cells[kept].forwarders;
				zane_cells[kept].forwarders = *brought;
			}
			*brought = kept;
		} else if (*brought) {
			zane_cells[*brought].target = slot + p.offset;
		}
	}
	memcpy(slot, incoming, (size_t)size);
}

/* A slot in the innermost scope's arena, which is the only one a program
   ever places a slot in. A slot holding hosts or blocks is listed, with its
   layout, so the drain can end the identities and return the blocks. */
void *zane_slot(int64_t scope, int64_t size, int64_t align, const int64_t *layout) {
	if (scope != zane_depth - 1) zane_broken("a slot placed in a scope that is not innermost");
	char *slot = zane_bump(size, align);
	if (layout && layout[0] > 0) {
		zane_hosted *h = zane_bump(sizeof *h, 8);
		*h = (zane_hosted){ zane_marks[scope].hosts, slot, layout };
		zane_marks[scope].hosts = h;
	}
	return slot;
}

/* Everything the scope placed is released together, and every identity it
   still hosts ends: its anchors, and the forwarders to them, retire. The
   blocks its values still own are returned. */
void zane_scope_drain(int64_t scope) {
	if (scope != zane_depth - 1) zane_broken("a scope drained out of order");
	for (zane_hosted *h = zane_marks[scope].hosts; h; h = h->next) {
		zane_position p;
		ZANE_EACH(h->layout, p) {
			uint32_t id;
			if (zane_hosts(h->slot, &p) && (id = *zane_backpointer(h->slot, &p))) zane_retire(id);
		}
		zane_release(h->slot, h->layout);
	}
	zane_depth--;
	zane_chunks = zane_marks[zane_depth].chunks;
	zane_frontier = zane_marks[zane_depth].frontier;
}

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. Every scope has drained by the
   time `main` returns, and every block its owner returned. */
int main(void) {
	zane_main();
	if (zane_depth != 0) zane_broken("a scope was left without draining");
	if (zane_blocks != 0) zane_broken("a dynamic block outlived its owner");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
