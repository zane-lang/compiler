/* The Zane runtime (docs/lowering.md L17): what every program links with.

   A program's `main` is `zane_main`, which the C `main` below calls once the
   runtime is ready. Everything else here is what an intrinsic lowers to. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void zane_main(void);

/* `@runtime$Console`'s `print` (effects.md §6.6): exactly the view's length
   in bytes, with no terminator and nothing added. */
void zane_print(const char *bytes, int64_t length) {
	fwrite(bytes, 1, (size_t)length, stdout);
}

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

/* Where each open scope began, innermost last. */
typedef struct {
	uint32_t chunks;
	size_t frontier;
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
	zane_marks[zane_depth] = (zane_mark){ zane_chunks, zane_frontier };
	return zane_depth++;
}

/* A fixed-size slot in the innermost scope's arena, which is the only one a
   program ever places a slot in. */
void *zane_slot(int64_t scope, int64_t size, int64_t align) {
	if (scope != zane_depth - 1) zane_broken("a slot placed in a scope that is not innermost");
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

/* Everything the scope placed is released together. */
void zane_scope_drain(int64_t scope) {
	if (scope != zane_depth - 1) zane_broken("a scope drained out of order");
	zane_depth--;
	zane_chunks = zane_marks[zane_depth].chunks;
	zane_frontier = zane_marks[zane_depth].frontier;
}

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. Every scope has drained by the
   time `main` returns. */
int main(void) {
	zane_main();
	if (zane_depth != 0) zane_broken("a scope was left without draining");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
