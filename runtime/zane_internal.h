/* What the parts of the runtime share with each other, and with the C
   tests that reach past its ABI: the types behind it, and every function
   and variable that one part defines and another uses. Every part
   includes this first. */

#ifndef ZANE_INTERNAL_H
#define ZANE_INTERNAL_H

#define _POSIX_C_SOURCE 200809L
/* `mmap`'s anonymous, unreserved mappings and a thread's stack bounds
   (region.c) are not POSIX. */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE

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

/* A scope's memory is in two regions (memory.md §3.1). Its fixed-size
   region is its frame: the scope's record, then every slot it places, each
   at an offset lowering fixed (docs/design/lowering.md §9). Every context
   reserves one range of addresses for its frames, the main context's
   `zane_fixed_region` bytes and a spawned call's
   `zane_spawned_fixed_region`, which the program defines from the root
   manifest. Scopes nest last-in-first-out, so a scope's frame starts where
   the scope around it ended, and draining it returns everything after that
   point at once. The range is reserved with no access and becomes usable a
   step at a time, when the program first touches it, and a guard of
   unmapped addresses follows it, so a frame running past its end faults
   instead of being checked (region.c). Its dynamic region is where the
   blocks its values own are: 1 MiB chunks of its own, each made at a
   1 MiB boundary, with a bump frontier and a stack of returned blocks for
   each size and alignment (§3.2), all given back at the drain with no walk
   of what its values own. A value may own blocks in an outer region, which
   a move into a deeper owner leaves where they are (§3.5); when the value
   dies with this scope they are dead space there, given back when that
   region drains in turn.

   A program run with `ZANE_CHECK` set checks every drain instead: the
   scope's values return their blocks one by one, as they die, and a block
   still out in the region after that is one that should have moved out
   with a value that left, which stops the program.

   The program's `main` runs in one context, and each spawned call in one of
   its own (concurrency.md §3): its own nest of scopes, and its own range,
   so a thread places frames only in its own (docs/design/lowering.md §9). */
enum { ZANE_CHUNK = 1 << 20, ZANE_LINE = 64, ZANE_CONTEXTS = (1 << 16) - 1 };

/* The guard after a context's range, and the step it becomes usable in:
   a frame no larger than the guard, placed below the range's end, ends
   inside the guard at worst, so lowering checks only a larger one. */
enum { ZANE_GUARD = ZANE_CHUNK, ZANE_STEP = ZANE_CHUNK };

enum { ZANE_PAGES = 1 << 14 };

/* Whether drains are checked, `ZANE_CHECK` set and not to 0, is
   `zane_checking` (zane.h): emitted code reads it too. */

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

/* An open scope's record, at the start of its frame: its dynamic region's
   heap, its context, how deep it is, the scope around it, an ancestor to
   skip to when searching, the calls it spawned, and the rest of its
   dynamic region; when drains are checked, also what it holds and what
   write-backs retired there. The first of the program's is the program's
   own, open until it ends.

   `skip` is Myers' skew-binary jump pointer: the scope around it, or that
   scope's own skip's skip when both spans below it are the same length.
   Following it whenever it still lies above an address, and `outer`
   otherwise, finds the scope whose frame holds the address in steps
   logarithmic in the depth. The first scope skips to itself. */
struct zane_mark {
	zane_heap heap;
	zane_context *context;
	int64_t depth;
	zane_mark *outer, *skip;
	zane_task *tasks;
	zane_mapping *mappings;
	zane_held *held;
	zane_stack *stacks;
	zane_retired *retired;
};

/* The offsets emitted code reads a record at (lib/codegen/walks.ml and
   lib/codegen/emit.ml). A frame starts with its record, and frames are
   aligned to 16. */
_Static_assert(offsetof(zane_mark, heap) == 0, "a mark starts with its heap");
_Static_assert(offsetof(zane_heap, bump) == 8 * ZANE_CLASSES, "the frontier follows the classes");
_Static_assert(offsetof(zane_heap, end) == 8 * ZANE_CLASSES + 8, "its end follows it");
_Static_assert(offsetof(zane_heap, live) == 8 * ZANE_CLASSES + 16, "the count follows that");
_Static_assert(offsetof(zane_mark, context) == 152, "the context follows the heap");
_Static_assert(offsetof(zane_mark, depth) == 160, "then the depth");
_Static_assert(offsetof(zane_mark, outer) == 168, "then the scope around it");
_Static_assert(offsetof(zane_mark, skip) == 176, "then its skip");
_Static_assert(offsetof(zane_mark, tasks) == 184, "then its calls");
_Static_assert(offsetof(zane_mark, mappings) == 192, "then its chunks");
_Static_assert(sizeof(zane_mark) == 224, "a frame's record is 224 bytes");

/* A context's range: `frontier` is where the next frame starts, `top` the
   innermost scope's record, and `limit` the range's end, where the guard
   begins; emitted code reads the three at fixed offsets. `committed` is
   how much of the range is usable. `shared` counts the calls it spawned
   that are still out. Until it spawns, a context is its own thread's alone;
   while a call it spawned is out, that call may reach its storage, so its
   scopes and regions change under its lock, which another thread always
   takes for a context it reaches (docs/design/lowering.md §9). */
struct zane_context {
	char *frontier;
	zane_mark *top;
	char *limit;
	char *base;
	char *committed;
	int64_t size;
	int32_t id;
	pthread_mutex_t lock;
	int64_t shared;
	zane_mapping *spare; /* dynamic chunks its drained regions gave back */
	zane_context *next;
};

_Static_assert(offsetof(zane_context, frontier) == 0, "a context starts with its frontier");
_Static_assert(offsetof(zane_context, top) == 8, "then its innermost scope");
_Static_assert(offsetof(zane_context, limit) == 16, "then its range's end");

/* A spawned call. Its frame -- room for its result, then its arguments --
   follows this header in the frame of the scope that spawned it,
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

_Static_assert(sizeof(zane_task) == 96, "lowering places a 96-byte header before a spawn's frame");

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
void zane_reopen(void);
void zane_lock(zane_context *c);
void zane_unlock(zane_context *c);
zane_context *zane_context_new(void);
uintptr_t *zane_page(const void *at, int make);

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
void zane_work_grow(zane_work *w) __attribute__((cold, noinline));

static inline void zane_work_push(zane_work *w, zane_job job) {
	if (__builtin_expect(w->count == w->room, 0)) zane_work_grow(w);
	w->jobs[w->count++] = job;
}

static inline int zane_work_pop(zane_work *w, zane_job *job) {
	if (w->count == 0) return 0;
	*job = w->jobs[--w->count];
	return 1;
}

void zane_work_end(zane_work *w);
void zane_work_run(zane_work *w);
void zane_end(char *base, const zane_type *type);

/* region.c */
void zane_regions_start(void);
void zane_thread_start(void);
void zane_reserve(zane_context *c, int64_t size);
_Noreturn void zane_too_deep_in(zane_context *c);

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
