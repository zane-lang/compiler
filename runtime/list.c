#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Lists (memory.md §3.6)                                                 */
/* ---------------------------------------------------------------------- */

/* An index outside a list or an array (docs/design/lowering.md §9): what the program wrote so
   far is kept, and it stops with a failing status. Emitted code checks an
   index itself and calls this only when the index is outside. */
void zane_out_of_range(void) {
	zane_flush_output();
	fputs("index out of range\n", stderr);
	exit(1);
}

/* `@primitives$List(T)` and `@primitives$ListRef(T)`: empty, owning no block. Emitted code makes the
   same empty handle itself (docs/design/lowering.md §9). */
void zane_list_new(zane_list *out) { *out = (zane_list){ NULL, 0, 0 }; }

/* The list's block made at least `needed` bytes. A full list's block
   doubles, from four elements' bytes (zane_list_first_room), in the region that holds its block (§3.6). Up to
   1 MiB it goes into a returned block of the doubled size, or grows in
   place when it is the last thing at the region's frontier with room after
   it, in its chunk or in the scope's frame stretched to hold it, to at
   most a chunk's size (arena.c), or else into new bytes there. Past that it is oversized:
   it grows in place while its reservation holds the doubled size, and
   otherwise moves into an oversized block of its own with a reservation
   that does. Nothing references an element, which is roaming (memory.md
   §2.8.1), and the blocks the elements own stay where they are, so a move
   copies their bytes and nothing else. An oversized block moved out of
   gives its memory back as the move goes (zane_list_move_out), so the
   list never holds both blocks' bytes at once. Out of line, so the push
   the program makes stays small. */
static void zane_list_grow(zane_list *list, int64_t needed, int64_t stride)
	__attribute__((noinline));

/* An oversized block's first `bytes` copied to `items`, a chunk at a time,
   each of its pages given back to the system once its bytes are copied, and
   the rest of it after the last. Its first page holds its mapping's header,
   which stays until its region drains and gives back its addresses
   (arena.c). Nothing takes the block again, so its region counts it no
   longer. */
static void zane_list_move_out(zane_mark *region, char *items, char *block, int64_t bytes) {
	zane_mapping *m = (zane_mapping *)(block - ZANE_LINE);
	uintptr_t page = zane_page_bytes();
	char *given = (char *)m + page;
	for (int64_t at = 0; at < bytes; at += ZANE_CHUNK) {
		int64_t n = bytes - at < ZANE_CHUNK ? bytes - at : ZANE_CHUNK;
		memcpy(items + at, block + at, (size_t)n);
		char *copied = (char *)((uintptr_t)(block + at + n) & ~(page - 1));
		if (copied > given) {
			zane_decommit_range(given, (size_t)(copied - given));
			given = copied;
		}
	}
	char *end = (char *)m + m->size;
	if (end > given) zane_decommit_range(given, (size_t)(end - given));
	zane_lock(region->context);
	region->heap.live--;
	zane_unlock(region->context);
}

/* The bytes of a list's first block when its first push asks for `bytes`
   of elements `stride` wide (zane_abi.h). */
static inline int64_t zane_list_first_room(int64_t bytes, int64_t stride) {
	int64_t room = 4 * stride;
	if (room < ZANE_LIST_LEAST) room = ZANE_LIST_LEAST;
	if (room > ZANE_LIST_FIRST) room = ZANE_LIST_FIRST;
	if (room < bytes) room = bytes;
	return (room + 7) / 8 * 8;
}

/* Whether the region holds a returned block of `room` bytes, which an
   allocation of the size takes before any new bytes (arena.c). */
static inline int zane_list_returned(zane_mark *region, int64_t room) {
	if (room <= 8 * ZANE_CLASSES) return region->heap.classes[room / 8 - 1] != NULL;
	zane_stack *s = region->stacks ? zane_find_stack(region, room, ZANE_LIST_ALIGN) : NULL;
	return s && s->top;
}

static void zane_list_grow(zane_list *list, int64_t needed, int64_t stride) {
	int64_t room = list->room ? list->room * 2 : zane_list_first_room(stride, stride);
	while (room < needed) room *= 2;
	zane_mark *region = zane_region_at(list->room ? (void *)list->items : (void *)list);
	zane_lock(region->context);
	char *items;
	if (room > ZANE_CHUNK - ZANE_LINE) {
		if (list->room > ZANE_CHUNK - ZANE_LINE && zane_extend(region, list->items, room)) {
			zane_unlock(region->context);
			list->room = room;
			return;
		}
		items = zane_alloc_growable(region, room);
		zane_unlock(region->context);
	} else {
		zane_heap *h = &region->heap;
		int grows = list->room && list->items + list->room == h->bump;
		if (grows) {
			grows = !zane_list_returned(region, room) &&
			        (room - list->room <= h->end - h->bump ||
			         (h->end == region->context->frontier && zane_stretch(region, list->items + room, ZANE_CHUNK)));
		}
		/* The block grows where it is, so nothing in it moves. */
		if (grows) {
			h->bump += room - list->room;
			zane_unlock(region->context);
			list->room = room;
			return;
		}
		/* The old block's stack is made first: a stack's record comes from
		   the frontier, and one made after the new block would stop that
		   block growing in place. */
		if (list->room > 8 * ZANE_CLASSES) zane_stack_of(region, list->room, ZANE_LIST_ALIGN);
		items = zane_alloc_held(region, room, ZANE_LIST_ALIGN);
		zane_unlock(region->context);
	}
	if (list->room > ZANE_CHUNK - ZANE_LINE) {
		zane_list_move_out(region, items, list->items, list->count * stride);
	} else {
		if (list->count) memcpy(items, list->items, (size_t)(list->count * stride));
		if (list->room) zane_free(list->items, list->room, ZANE_LIST_ALIGN);
	}
	list->items = items;
	list->room = room;
}

/* An empty list's first block, `room` bytes, when its handle is in the
   innermost scope's frame, or in no memory of the runtime's such as the
   machine stack, while the context is this thread's alone, so the block is
   that scope's and needs no lock (zane_region_at): a returned block of the
   size class first (§3.2), else the next bytes at the scope's frontier, in its
   frame stretched to hold them when the heap has no room there. 0 when
   none of that holds, and the list grows as any other does. */
static inline char *zane_list_first(zane_list *list, int64_t room) {
	zane_mark *m = zane_open;
	if (!m) return NULL;
	if ((char *)list < (char *)m || (char *)list >= m->context->frontier) {
		if (zane_page_entry(list)) return NULL;
	}
	zane_heap *h = &m->heap;
	char *block;
	char **top = &h->classes[room / 8 - 1];
	if (*top) {
		block = *top;
		*top = *(char **)block;
	} else {
		uintptr_t mask = ZANE_LIST_ALIGN - 1;
		uintptr_t start = ((uintptr_t)h->bump + mask) & ~mask;
		if (!h->bump || start + (uintptr_t)room > (uintptr_t)h->end) {
			char *frontier = m->context->frontier;
			if (h->bump && h->end != frontier) return NULL;
			if (!h->bump) start = ((uintptr_t)frontier + mask) & ~mask;
			if (!zane_stretch(m, (char *)(start + (uintptr_t)room), ZANE_STRETCHED)) return NULL;
		}
		block = (char *)start;
		h->bump = block + room;
	}
	h->live++;
	list->items = block;
	list->room = room;
	return block;
}

/* A push onto a full list: its block grown, then the push made. */
static void *zane_list_push_grown(zane_list *list, int64_t stride) __attribute__((noinline));

static void *zane_list_push_grown(zane_list *list, int64_t stride) {
	zane_list_grow(list, (list->count + 1) * stride, stride);
	return list->items + list->count++ * stride;
}

/* Room for one more element, `stride` bytes wide, at the end: the address
   the caller then moves it into. Emitted code makes the same push itself
   while the block has room, and calls this only when it is full
   (docs/design/lowering.md §9). An empty list's first block is taken here
   without a call, and anything else grows the list out of line, so this
   needs no frame of its own. */
void *zane_list_push(zane_list *list, int64_t stride) {
	if (__builtin_expect((list->count + 1) * stride <= list->room, 1)) return list->items + list->count++ * stride;
	if (!list->room && stride <= ZANE_LIST_FIRST) {
		char *block = zane_list_first(list, zane_list_first_room(stride, stride));
		if (block) {
			list->count = 1;
			return block;
		}
	}
	return zane_list_push_grown(list, stride);
}

/* As `zane_list_push`, with room made for `n` elements, this push's and
   the `n - 1` after it, which emitted code then makes as plain stores with
   no check of their own (docs/design/lowering.md §9). Emitted code calls
   this only when the block lacks that room. */
void *zane_list_reserve(zane_list *list, int64_t stride, int64_t n) {
	if (!list->room && n * stride <= ZANE_LIST_FIRST) {
		char *block = zane_list_first(list, zane_list_first_room(n * stride, stride));
		if (block) {
			list->count = 1;
			return block;
		}
	}
	if ((list->count + n) * stride > list->room) zane_list_grow(list, (list->count + n) * stride, stride);
	return list->items + list->count++ * stride;
}

/* The element at `index`, counted from 1 (control-flow.md §3.4). */
void *zane_list_at(zane_list *list, int64_t index, int64_t stride) {
	if (index < 1 || index > list->count) zane_out_of_range();
	return list->items + (index - 1) * stride;
}

/* The list closes over the element at `index`, counted from 1, which the
   caller has already moved out: the later elements move down one place,
   keeping their order, and the list keeps its block. Nothing references an
   element, so moving their bytes moves them. Emitted code makes the same
   removal itself, with the stride a constant (docs/design/lowering.md §9). */
void zane_list_remove(zane_list *list, int64_t index, int64_t stride) {
	char *at = list->items + (index - 1) * stride;
	memmove(at, at + stride, (size_t)((list->count - index) * stride));
	list->count--;
}

/* As `zane_list_remove`, but the last element moves into the place, so only
   one element moves and the order is not kept. */
void zane_list_swap_remove(zane_list *list, int64_t index, int64_t stride) {
	char *last = list->items + (list->count - 1) * stride;
	if (index < list->count) memcpy(list->items + (index - 1) * stride, last, (size_t)stride);
	list->count--;
}

/* The element at `index` of an array of `count` elements laid out inline,
   counted from 1 like a list's. */
void *zane_array_at(char *array, int64_t index, int64_t count, int64_t stride) {
	if (index < 1 || index > count) zane_out_of_range();
	return array + (index - 1) * stride;
}
