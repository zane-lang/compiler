/* What the parts of the runtime share with each other, and with the C
   tests that reach past its ABI: the types behind it, and every function
   and variable that one part defines and another uses. Every part
   includes this first. */

#ifndef ZANE_INTERNAL_H
#define ZANE_INTERNAL_H

#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <sched.h>
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
   blocks for each size and alignment (§3.2), all given back at the drain.

   The program's `main` runs in one context, and each spawned call in one of
   its own (concurrency.md §3): its own nest of scopes, and its own chain of
   fixed chunks, so a thread bumps only its own (docs/design/lowering.md §9). */
enum { ZANE_CHUNK = 1 << 20, ZANE_CHUNKS = 1 << 15, ZANE_LINE = 64 };
enum { ZANE_DEPTH = 1 << 15, ZANE_SEGMENT = 64, ZANE_CONTEXTS = (1 << 16) - 1 };

enum { ZANE_PAGES = 1 << 14 };

/* A slot held in a scope because what it holds owns blocks, with the
   layout that says where they are, so the scope's drain can return them.
   It lives in the scope's own arena. */
typedef struct zane_held {
	struct zane_held *next;
	char *slot;
	const int64_t *layout;
} zane_held;

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

/* What a value owned before a spawned call wrote it back (§4.4): kept, as
   it was, until its region drains, since a reader may still be following
   it. */
typedef struct zane_retired {
	struct zane_retired *next;
	const int64_t *layout;
	int64_t size;
} zane_retired;

/* Each open scope of a context, innermost last: where its slots began,
   what it holds, the calls it spawned, and its dynamic region with the
   number of blocks out in it. The first of the program's is the program's
   own, open until it ends. */
typedef struct {
	zane_context *context;
	int64_t depth;
	uint32_t chunks;
	size_t frontier;
	zane_held *held;
	zane_task *tasks;
	zane_mapping *mappings;
	char *chunk;
	size_t bumped;
	zane_stack *stacks;
	zane_retired *retired;
	int64_t live;
} zane_mark;

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
	zane_context *next;
};

/* A string's or a list's handle, and a boxed member's pointer, name the
   block it owns. A layout lists where they are: a count, then for each
   position its kind, its offset, its size, a list's stride or a box's
   payload size, the layout of a list's elements or a box's payload, and
   the variant tags that must be live for it to be there, as a count and
   then (tag offset, tag) pairs. */
enum { ZANE_TEXT = 1, ZANE_LIST = 2, ZANE_BOX = 3 };

typedef struct {
	int64_t kind, offset, size, extra;
	const int64_t *inner;
	int64_t conditions;
	const int64_t *tags;
} zane_position;

/* A layout with no positions may be no table at all. */
#define ZANE_EACH(layout, p)                                                        \
	for (int64_t zane_cursor = 1, zane_left = (layout) ? (layout)[0] : 0;           \
	     zane_next_position((layout), &zane_cursor, &zane_left, &(p));)


/* A spawned call. Its frame -- room for its result, then its arguments --
   follows this header in the fixed region of the scope that spawned it,
   which waits for it before it drains (§4.1). The call runs in a context of
   its own, which it keeps until its result comes home: copied to `dest`,
   `size` bytes laid out as `layout` says, where its blocks move into the
   destination's region. */
struct zane_task {
	zane_task *next;           /* the next the same scope spawned */
	zane_task *before, *after; /* in its deque, while queued */
	void (*run)(char *frame);
	char *frame, *dest;
	const int64_t *layout;
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
zane_mark *zane_region_at(const void *at);
void zane_unmap(zane_mark *region);
zane_stack *zane_find_stack(zane_mark *m, int64_t size, int64_t align);
extern _Atomic int64_t zane_blocks;
char *zane_alloc(zane_mark *region, int64_t size, int64_t align);
void zane_free(char *block, int64_t size, int64_t align);

/* block.c */
int zane_next_position(const int64_t *layout, int64_t *cursor, int64_t *left,
                       zane_position *p);
int zane_present(const char *base, const zane_position *p);
void zane_unblock(const zane_position *p, void *block, int64_t room);
void *zane_at(char *base, const zane_position *p);
void zane_end_at(char *base, const zane_position *p);
void zane_end(char *base, const int64_t *layout);

/* value.c */
void zane_move(char *value, const int64_t *layout, zane_mark *region, int64_t from);

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
