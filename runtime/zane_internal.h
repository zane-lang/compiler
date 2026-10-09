/* What the parts of the runtime share with each other, and with the C
   tests that reach past its ABI: the types behind it, and every function
   and variable that one part defines and another uses. Every part
   includes this first. */

#ifndef ZANE_INTERNAL_H
#define ZANE_INTERNAL_H

#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zane.h"

/* What Windows does differently (docs/design/platforms.md). It has no
   `aligned_alloc`, and memory from `_aligned_malloc` goes back through
   `_aligned_free`. Its POSIX threads are MinGW's winpthreads, which also
   counts the processors. */
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <malloc.h>
#define zane_chunk_alloc(size) _aligned_malloc((size), ZANE_CHUNK)
#define zane_chunk_free(chunk) _aligned_free(chunk)
#else
#define zane_chunk_alloc(size) aligned_alloc(ZANE_CHUNK, (size))
#define zane_chunk_free(chunk) free(chunk)
#endif

/* Memory comes in 1 MiB chunks, each made at a 1 MiB boundary. Scopes nest
   last-in-first-out, and each has two regions (memory.md §3.1). Its
   fixed-size region is where its slots are: every scope bumps one shared
   chain of chunks from where the scope around it stopped, and draining it
   returns everything after that point at once (docs/design/lowering.md §9). A
   fixed chunk stays mapped once made, and the next scope that reaches it
   reuses it. Its dynamic region is where the blocks its values own are: a
   chain of chunks of its own, with a bump frontier and a stack of returned
   blocks for each size and alignment (§3.2), all given back at the drain
   with no walk of what its values own. A value may own blocks in an outer
   region, which a move into a deeper owner leaves where they are (§3.5);
   when the value dies with this scope they are dead space there, given back
   when that region drains in turn.

   A program run with `ZANE_CHECK` set checks every drain instead: the
   scope's values return their blocks one by one, as they die, and a block
   still out in the region after that is one that should have moved out
   with a value that left, which stops the program.

   The program's `main` runs in one context, and each spawned call in one of
   its own (concurrency.md §3): its own nest of scopes, and its own chain of
   fixed chunks, so a thread bumps only its own (docs/design/lowering.md §9). */
enum { ZANE_CHUNK = 1 << 20, ZANE_CHUNKS = 1 << 15, ZANE_LINE = 64 };
enum { ZANE_DEPTH = 1 << 15, ZANE_SEGMENT = 64, ZANE_CONTEXTS = (1 << 16) - 1 };

enum { ZANE_PAGES = 1 << 14 };

/* Whether drains are checked: `ZANE_CHECK` is set, and not to 0. */
extern int zane_checking;

/* A slot held in a scope because what it holds owns blocks, with the
   type whose walks reach them, so a checked drain can return them. It
   lives in the scope's own arena. */
typedef struct zane_held {
	struct zane_held *next;
	char *slot;
	const zane_type *type;
} zane_held;

/* The returned blocks of one size and alignment, each naming the next, for
   the blocks no size class holds. */
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

/* What a value owned before a spawned call wrote it back (§4.4), kept as it
   was for a checked drain to return. */
typedef struct zane_retired {
	struct zane_retired *next;
	const zane_type *type;
	int64_t size;
} zane_retired;

/* Where a region hands out its blocks, kept at the start of its mark so
   emitted code finds every field at a fixed offset (docs/design/lowering.md
   §9). A block of up to ZANE_CLASSES words aligned to a word comes from its
   size class's stack of returned blocks, each naming the next, or else from
   `bump`, the region's frontier in its current chunk, which ends at `end`.
   The frontier stays aligned to a word, since every block is a whole number
   of words and a wider alignment only rounds it up, so a block of a size
   class takes its bytes from there as they are. `live` counts the blocks
   handed out and not returned. A region with no chunk yet has both ends
   null. */
enum { ZANE_CLASSES = 16 };

typedef struct {
	char *classes[ZANE_CLASSES];
	char *bump, *end;
	int64_t live;
} zane_heap;

/* Each open scope of a context, innermost last: its dynamic region's heap,
   where its slots began, the calls it spawned, and the rest of its dynamic
   region; when drains are checked, also what it holds and what write-backs
   retired there. The first of the program's is the program's own, open
   until it ends. */
struct zane_mark {
	zane_heap heap;
	zane_context *context;
	int64_t depth;
	uint32_t chunks;
	size_t frontier;
	zane_held *held;
	zane_task *tasks;
	zane_mapping *mappings;
	zane_stack *stacks;
	zane_retired *retired;
};

/* The offsets emitted code reads a heap at (lib/codegen/walks.ml). */
_Static_assert(offsetof(zane_mark, heap) == 0, "a mark starts with its heap");
_Static_assert(offsetof(zane_heap, bump) == 8 * ZANE_CLASSES, "the frontier follows the classes");
_Static_assert(offsetof(zane_heap, end) == 8 * ZANE_CLASSES + 8, "its end follows it");
_Static_assert(offsetof(zane_heap, live) == 8 * ZANE_CLASSES + 16, "the count follows that");

/* A context's scopes are kept in segments, so a scope's mark stays where it
   is while others open. `shared` counts the calls it spawned that are still
   out. Until it spawns, a context is its own thread's alone; while a call it
   spawned is out, that call may reach its storage, so its scopes and
   regions change under its lock, which another thread always takes for a
   context it reaches (docs/design/lowering.md §9). */
struct zane_context {
	int32_t id;
	pthread_mutex_t lock;
	int64_t shared, depth;
	zane_mark *segments[ZANE_DEPTH / ZANE_SEGMENT];
	char **directory;
	uint32_t chunks;  /* fixed chunks in use: the current one is the last */
	size_t frontier;  /* the next free byte in the current fixed chunk */
	zane_mapping *spare; /* dynamic chunks its drained regions gave back */
	zane_context *next;
};

/* A spawned call. Its frame -- room for its result, then its arguments --
   follows this header in the fixed region of the scope that spawned it,
   which waits for it before it drains (§4.1). The call runs in a context of
   its own, which it keeps until its result comes home: copied to `dest`,
   `size` bytes of `type`, whose blocks move into the destination's
   region. */
struct zane_task {
	zane_task *next;           /* the next the same scope spawned */
	zane_task *before, *after; /* in its deque, while queued */
	void (*run)(char *frame);
	char *frame, *dest;
	const zane_type *type;
	int64_t size, deque;
	zane_context *owner, *context;
	int state;
};

enum { ZANE_QUEUED, ZANE_RUNNING, ZANE_DONE, ZANE_JOINED };

/* The pool steals work (§2.4). Each of its threads keeps a deque of the
   calls it spawned, and takes its own newest first; a thread with none
   left steals the oldest of another's. Calls spawned where no pool thread
   runs -- the program's own thread -- go to a deque of their own, the
   first, which every pool thread steals from. A deque outlives a thread
   that leaves it, and the next thread to start takes it over, calls and
   all. */
typedef struct {
	pthread_mutex_t lock;
	zane_task *first, *last;
	int kept;
} zane_deque;

enum { ZANE_DEQUES = 1 << 12 };

/* main.c */
void zane_broken(const char *what);

/* arena.c */
extern pthread_mutex_t zane_memory;
extern int32_t zane_context_count;
extern zane_context *zane_idle;
extern _Thread_local zane_context *zane_self;
extern zane_mark *zane_program;
zane_mark *zane_mark_at(zane_context *c, int64_t depth);
void zane_lock(zane_context *c);
void zane_unlock(zane_context *c);
zane_context *zane_context_new(void);
void *zane_bump(int64_t size, int64_t align);

/* The program's arguments after its own name, kept by `main`. */
extern int zane_argc;
extern char **zane_argv;
void zane_unmap(zane_mark *region);
void zane_give_spares(zane_context *c);
zane_stack *zane_find_stack(zane_mark *m, int64_t size, int64_t align);
int64_t zane_blocks(void);

/* block.c */

/* What is still to be done to a value's blocks, kept off the machine stack
   (memory.md §2.3 sets no depth limit). A job is a walk to run at depth 0,
   with its place and what it works with, or, with no walk, a block of
   `extra` bytes aligned to `align` to return. */
typedef struct {
	zane_walk walk;
	char *at, *with;
	int64_t extra, align;
} zane_job;

/* Most walks never hand on more than a few jobs at once, so the first few
   live in the work itself and only a longer walk takes a heap buffer. A
   work points into itself from its start, so it stays where it was declared.
   `zane_work_start` sets only its header, since zeroing the jobs would cost
   what they save; a work zeroed whole starts at its first push instead. */
#define ZANE_LOCAL_JOBS 4

struct zane_work {
	zane_job *jobs;
	int64_t count, room;
	zane_job local[ZANE_LOCAL_JOBS];
};

void zane_work_start(zane_work *w);
void zane_work_push(zane_work *w, zane_job job);
int zane_work_pop(zane_work *w, zane_job *job);
void zane_work_end(zane_work *w);
void zane_work_run(zane_work *w);
void zane_end(char *base, const zane_type *type);

/* value.c */
void zane_move(char *value, const zane_type *type, zane_mark *region, int64_t from);

/* spawn.c */
int zane_state(zane_task *t);
void zane_set_state(zane_task *t, int s);
extern zane_deque zane_deques[ZANE_DEQUES];
extern pthread_mutex_t zane_pool;
extern pthread_cond_t zane_finished;
extern int64_t zane_threads, zane_wanted, zane_queued;
void zane_unlink(zane_deque *d, zane_task *t);
void zane_taken(void);
void zane_run(zane_task *t);
int64_t zane_processors(void);

#endif
