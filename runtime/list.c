#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* Lists (memory.md §3.6)                                                 */
/* ---------------------------------------------------------------------- */

/* An index outside a list or an array (docs/design/lowering.md §9): what the program wrote so
   far is kept, and it stops with a failing status. Emitted code checks an
   index itself and calls this only when the index is outside. */
void zane_out_of_range(void) {
	fflush(stdout);
	fputs("index out of range\n", stderr);
	exit(1);
}

/* `@primitives$List(T)`: empty, owning no block. Emitted code makes the
   same empty handle itself (docs/design/lowering.md §9). */
void zane_list_new(zane_list *out) { *out = (zane_list){ NULL, 0, 0 }; }

/* The list's block made at least `needed` bytes. A full list's block
   doubles, from 128 bytes, in the region that holds its block (§3.6). Up to
   1 MiB it goes into a returned block of the doubled size, or grows in
   place when it is the last thing at the region's frontier with room after
   it in its chunk, or else into new bytes there. Past that it is oversized:
   it grows in place while its reservation holds the doubled size, and
   otherwise moves into an oversized block of its own with a reservation
   that does. Nothing references an element, which is roaming (memory.md
   §2.8.1), and the blocks the elements own stay where they are, so a move
   copies their bytes and nothing else. Out of line, so the push the
   program makes stays small. */
static void zane_list_grow(zane_list *list, int64_t needed, int64_t stride)
	__attribute__((noinline));

static void zane_list_grow(zane_list *list, int64_t needed, int64_t stride) {
	int64_t room = list->room ? list->room * 2 : 128;
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
		zane_stack *s = zane_find_stack(region, room, ZANE_LINE);
		zane_heap *h = &region->heap;
		int grows = !(s && s->top) && list->room && list->items + list->room == h->bump &&
		            room - list->room <= h->end - h->bump;
		/* The block grows where it is, so nothing in it moves. */
		if (grows) {
			h->bump += room - list->room;
			zane_unlock(region->context);
			list->room = room;
			return;
		}
		zane_unlock(region->context);
		items = zane_alloc(region, room, ZANE_LINE);
	}
	if (list->count) memcpy(items, list->items, (size_t)(list->count * stride));
	if (list->room) zane_free(list->items, list->room, ZANE_LINE);
	list->items = items;
	list->room = room;
}

/* Room for one more element, `stride` bytes wide, at the end: the address
   the caller then moves it into. Emitted code makes the same push itself
   while the block has room, and calls this only when it is full
   (docs/design/lowering.md §9). */
void *zane_list_push(zane_list *list, int64_t stride) {
	int64_t needed = (list->count + 1) * stride;
	if (__builtin_expect(needed > list->room, 0)) zane_list_grow(list, needed, stride);
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
