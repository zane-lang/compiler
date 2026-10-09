/* The Zane runtime's ABI (docs/design/lowering.md L17): what emitted code
   calls, and the one function it defines. A program's `main` is `zane_main`,
   which the runtime's C `main` calls once the runtime is ready. Everything
   else here is what an intrinsic lowers to. */

#ifndef ZANE_H
#define ZANE_H

#include <stdint.h>

/* `@primitives$String`, a value type, and `@primitives$List<T>`, a
   reference type: each a handle to its bytes or elements. A string has no
   terminator, and its length is in bytes; a list's is in elements. `room`
   is the size of the block the handle owns, or 0 when it owns none: a
   literal's bytes are the program's own and are never returned. */
typedef struct {
	const char *bytes;
	int64_t length, room;
} zane_text;

typedef struct {
	char *items;
	int64_t count, room;
} zane_list;

/* A scope's region, and the jobs of one walk over a value's blocks: what a
   walk is handed, kept opaque here. */
typedef struct zane_mark zane_mark;
typedef struct zane_work zane_work;

/* A walk over the blocks one type's values own (memory.md §3.6): the
   compiler emits four for each type that owns any (docs/design/lowering.md
   §9). Each takes the place the value is at, what the walk works with --
   the region a copy or a move puts blocks in, or the value an overwrite
   writes -- and a number: where a move's blocks leave from, or the size of
   the value an overwrite writes. A walk follows a nested value's blocks by
   calling the walk of its type, `depth` deeper, or past a fixed depth by
   handing it to `work` (`zane_defer`), so a value nested any number of
   boxes deep is walked without the machine stack growing with it. */
typedef void (*zane_walk)(char *at, char *with, int64_t extra, zane_work *work, int64_t depth);

typedef struct {
	zane_walk copy, end, move, overwrite;
} zane_type;

/* What the program defines. */
void zane_main(void);

/* main.c */

/* arena.c */
extern _Thread_local zane_mark *zane_open;
int64_t zane_scope_enter(void);
zane_mark *zane_region_at(const void *at);
char *zane_alloc(zane_mark *region, int64_t size, int64_t align);
char *zane_alloc_held(zane_mark *region, int64_t size, int64_t align);
void zane_free(char *block, int64_t size, int64_t align);

/* block.c */
void zane_defer(zane_work *work, void (*walk)(char *, char *, int64_t, zane_work *, int64_t),
                char *at, char *with, int64_t extra);
void zane_defer_return(zane_work *work, char *block, int64_t size, int64_t align);
void zane_copy(char *value, const zane_type *type);
void *zane_box(int64_t size, int64_t align);
void zane_print(const zane_text *text);
void zane_text_join(zane_text *out, const zane_text *left, const zane_text *right);
int64_t zane_text_equal(const zane_text *left, const zane_text *right);
void zane_text_i32(zane_text *out, int32_t value);
void zane_text_i64(zane_text *out, int64_t value);
void zane_text_f32(zane_text *out, float value);
void zane_text_f64(zane_text *out, double value);
int64_t zane_parse_i64(const zane_text *text, int64_t *out);
int64_t zane_parse_f64(const zane_text *text, double *out);
void zane_arguments(zane_list *out);

/* value.c */
int64_t zane_constant_begin(int64_t *state);
void zane_constant_end(int64_t *state, char *value, const zane_type *type);
int64_t zane_leaves(const char *block, zane_mark *region, int64_t from);
void zane_arrive(char *slot, const zane_type *type);
void zane_promote(char *value, const zane_type *type, int64_t depth);
void zane_overwrite(char *slot, char *incoming, int64_t size, const zane_type *type);

/* list.c */
void zane_list_new(zane_list *out);
void *zane_list_push(zane_list *list, int64_t stride);
void *zane_list_at(zane_list *list, int64_t index, int64_t stride);
void *zane_array_at(char *array, int64_t index, int64_t count, int64_t stride);
void zane_out_of_range(void);

/* slot.c */
void *zane_slot(int64_t scope, int64_t size, int64_t align, const zane_type *type);

/* spawn.c */
int64_t zane_set_threads(int64_t count);
void zane_set_threads_auto(void);
void *zane_frame(int64_t scope, int64_t size, int64_t align);
void zane_spawn(char *frame, void (*run)(char *), char *dest, const zane_type *type,
                int64_t size);

/* snapshot.c */
void zane_snapshot(char *out, const char *from, int64_t size);
void zane_writeback(char *at, char *copy, int64_t size, const zane_type *type);
void zane_join(char *frame);
void zane_scope_drain(int64_t scope);

#endif
