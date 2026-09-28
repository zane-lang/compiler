#include "zane_internal.h"

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
