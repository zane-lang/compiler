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

/* ---------------------------------------------------------------------- */
/* Pooled variants (docs/experiments/goose-comparison)                    */
/* ---------------------------------------------------------------------- */

/* Experimental. A pooled variant's root is a list of bytes whose block
   holds its nodes, all of one size, the root last. A block's room is a
   whole number of words, so a pool's nodes may leave a few dead bytes
   where two joined pools meet. A node's links to the
   nodes below it are 32-bit offsets from the link to its target, so a pool
   appended onto another keeps them. A pool's block is made exactly as
   large as its nodes, at its region's frontier, so the pools a depth-first
   build makes lie end to end, and joining two that do copies nothing. An
   oversized pool copied onto another gives its pages back as it goes. */

/* The root's node. */
char *zane_pool_root(zane_list *pool, int64_t size) { return pool->items + pool->count - size; }

/* The node a link names. */
char *zane_link(char *link) { return link + *(int32_t *)link; }

/* Whether another thread may reach `c`, as zane_lock asks. */
static int zane_pool_guarded(zane_context *c) { return c != zane_self || c->shared > 0; }

/* The region a block is in, found without the page map's lookup when it is
   the innermost scope's. */
static zane_mark *zane_pool_region(void *block) {
	zane_mark *m = zane_open;
	if (m) {
		uintptr_t entry = zane_page_entry(block);
		if (entry == (uintptr_t)m) return m;
		zane_context *c = m->context;
		if (entry == ((uintptr_t)c | 1) && c->top == m && (char *)block >= (char *)m && !zane_pool_guarded(c)) return m;
	}
	return zane_region_at(block);
}

/* The region a new pool for the handle at `out` is made in, as a list's
   first block is (zane_list_first). */
static zane_mark *zane_pool_home(zane_list *out) {
	zane_mark *m = zane_open;
	if (m && (((char *)out >= (char *)m && (char *)out < m->context->frontier) || !zane_page_entry(out))) return m;
	return zane_region_at(out);
}

/* `pool`'s block made `total` bytes: in place when it ends at its region's
   frontier, else moved to a block of exactly that size there, or grown as
   a list grows once that passes a chunk. */
static void zane_pool_reserve(zane_list *pool, int64_t total) {
	if (total <= pool->room) return;
	total = (total + 7) & ~(int64_t)7;
	zane_mark *r = zane_pool_region(pool->items);
	zane_heap *h = &r->heap;
	zane_lock(r->context);
	if (pool->items + pool->room == h->bump &&
	    (pool->items + total <= h->end ||
	     (h->end == r->context->frontier && total <= ZANE_CHUNK - ZANE_LINE &&
	      zane_stretch(r, pool->items + total, ZANE_CHUNK)))) {
		h->bump = pool->items + total;
		zane_unlock(r->context);
		pool->room = total;
		return;
	}
	if (total > ZANE_CHUNK - ZANE_LINE || pool->room > ZANE_CHUNK - ZANE_LINE) {
		zane_unlock(r->context);
		zane_list_grow(pool, total, 1);
		return;
	}
	char *block = zane_pool_frontier(r, total);
	zane_unlock(r->context);
	memcpy(block, pool->items, (size_t)pool->count);
	zane_free(pool->items, pool->room, ZANE_LIST_ALIGN);
	pool->items = block;
	pool->room = total;
}

/* A node of `size` bytes, copied from `node`, made the root of a pool in
   `out` that holds the `n` child pools too, each of which is moved in.
   Children whose blocks lie end to end are joined where they are; any
   other is copied onto the largest. Each child's root is linked from the
   new node at `links[i]` bytes in. The new node's address. */
static char *zane_pool_make(zane_list *out, const char *node, int64_t size, int64_t n, zane_list **children,
                            const int64_t *links) {
	int64_t roots[4];
	zane_list pool;
	if (n == 0) {
		zane_mark *r = zane_pool_home(out);
		zane_lock(r->context);
		pool = (zane_list){ zane_pool_frontier(r, size), 0, (size + 7) & ~(int64_t)7 };
		zane_unlock(r->context);
	} else {
		int order[4];
		for (int i = 0; i < n; i++) {
			int j = i;
			while (j > 0 && children[order[j - 1]]->items > children[i]->items) {
				order[j] = order[j - 1];
				j--;
			}
			order[j] = i;
		}
		/* The children's blocks in address order, each run that lies end to
		   end joined into one, and the largest run taken as the pool. */
		zane_list runs[4];
		int first[4], count = 0;
		for (int k = 0; k < n; k++) {
			zane_list *c = children[order[k]];
			zane_list *last = count ? &runs[count - 1] : NULL;
			if (last && last->items + last->room == c->items) {
				roots[order[k]] = (c->items - last->items) + c->count - size;
				last->count = (c->items - last->items) + c->count;
				last->room += c->room;
				zane_mark *r = zane_pool_region(c->items);
				zane_lock(r->context);
				r->heap.live--;
				zane_unlock(r->context);
			} else {
				roots[order[k]] = c->count - size;
				first[count] = k;
				runs[count++] = *c;
			}
		}
		int base = 0;
		for (int k = 1; k < count; k++)
			if (runs[k].count > runs[base].count) base = k;
		int64_t total = runs[base].count + size;
		for (int k = 0; k < count; k++)
			if (k != base) total += runs[k].count;
		pool = runs[base];
		zane_pool_reserve(&pool, total);
		for (int k = 0; k < count; k++) {
			if (k == base) continue;
			int64_t at = pool.count;
			if (runs[k].room > ZANE_CHUNK - ZANE_LINE)
				zane_list_move_out(zane_pool_region(runs[k].items), pool.items + at, runs[k].items, runs[k].count);
			else {
				memcpy(pool.items + at, runs[k].items, (size_t)runs[k].count);
				zane_free(runs[k].items, runs[k].room, ZANE_LIST_ALIGN);
			}
			int end = k + 1 < count ? first[k + 1] : n;
			for (int q = first[k]; q < end; q++) roots[order[q]] += at;
			pool.count += runs[k].count;
		}
		for (int i = 0; i < n; i++) *children[i] = (zane_list){ NULL, 0, 0 };
	}
	zane_pool_reserve(&pool, pool.count + size);
	char *made = pool.items + pool.count;
	memcpy(made, node, (size_t)size);
	pool.count += size;
	for (int i = 0; i < n; i++) {
		int64_t distance = (pool.items + roots[i]) - (made + links[i]);
		if (distance != (int32_t)distance) zane_broken("a pooled variant past 2 GiB");
		*(int32_t *)(made + links[i]) = (int32_t)distance;
	}
	*out = pool;
	return made;
}

/* `zane_pool_make` for a node with up to four links; `n` says how many of
   the child pools and link offsets after it are given. */
char *zane_pool_node(zane_list *out, const char *node, int64_t size, int64_t n, zane_list *c0, int64_t l0,
                     zane_list *c1, int64_t l1, zane_list *c2, int64_t l2, zane_list *c3, int64_t l3) {
	int64_t room = (size + 7) & ~(int64_t)7;
	if (n == 0) {
		zane_mark *m = zane_pool_home(out);
		zane_heap *h = &m->heap;
		if (h->bump && h->bump + room <= h->end && !zane_pool_guarded(m->context)) {
			char *made = h->bump;
			h->bump += room;
			h->live++;
			memcpy(made, node, (size_t)size);
			*out = (zane_list){ made, size, room };
			return made;
		}
	} else if (n == 2 && c0->items + c0->room == c1->items) {
		zane_mark *m = zane_pool_region(c1->items);
		zane_heap *h = &m->heap;
		if (c1->items + c1->room == h->bump && h->bump + room <= h->end && !zane_pool_guarded(m->context)) {
			char *items = c0->items, *made = h->bump;
			h->bump += room;
			h->live--;
			memcpy(made, node, (size_t)size);
			char *r0 = c0->items + c0->count - size, *r1 = c1->items + c1->count - size;
			*(int32_t *)(made + l0) = (int32_t)(r0 - (made + l0));
			*(int32_t *)(made + l1) = (int32_t)(r1 - (made + l1));
			*c0 = *c1 = (zane_list){ NULL, 0, 0 };
			*out = (zane_list){ items, made + size - items, made + room - items };
			return made;
		}
	}
	zane_list *children[4] = { c0, c1, c2, c3 };
	int64_t links[4] = { l0, l1, l2, l3 };
	return zane_pool_make(out, node, size, n, children, links);
}

/* How many nodes the subtree at `node` has, each link in a node of case
   `c` at the 4-byte words set in `masks[c]`. */
static int64_t zane_pool_count(const char *node, const int64_t *masks) {
	int32_t c = *(const int32_t *)node;
	int64_t mask = c >= 0 && c < 4 ? masks[c] : 0, n = 1;
	for (int w = 0; mask; w++, mask >>= 1)
		if (mask & 1) n += zane_pool_count(zane_link((char *)node + 4 * w), masks);
	return n;
}

/* The subtree at `node` copied onto the end of `pool`, children first, as
   a build would have laid it out. Its copy's offset. */
static int64_t zane_pool_place(zane_list *pool, const char *node, int64_t size, const int64_t *masks) {
	int32_t c = *(const int32_t *)node;
	int64_t mask = c >= 0 && c < 4 ? masks[c] : 0, children[64];
	for (int w = 0; mask >> w; w++)
		if ((mask >> w) & 1) children[w] = zane_pool_place(pool, zane_link((char *)node + 4 * w), size, masks);
	int64_t at = pool->count;
	char *made = pool->items + at;
	memcpy(made, node, (size_t)size);
	for (int w = 0; mask >> w; w++)
		if ((mask >> w) & 1) *(int32_t *)(made + 4 * w) = (int32_t)(children[w] - (at + 4 * w));
	pool->count += size;
	return at;
}

/* The subtree whose top node is `node`, `size` bytes each, copied into a
   pool of its own in `out`, made in the region `out` is in. */
void zane_pool_copy(zane_list *out, const char *node, int64_t size, int64_t m0, int64_t m1, int64_t m2,
                    int64_t m3) {
	int64_t masks[4] = { m0, m1, m2, m3 };
	int64_t bytes = zane_pool_count(node, masks) * size;
	if (bytes > ZANE_CHUNK - ZANE_LINE) {
		*out = (zane_list){ NULL, 0, 0 };
		zane_list_grow(out, bytes, 1);
	} else {
		zane_mark *r = zane_pool_home(out);
		zane_lock(r->context);
		*out = (zane_list){ zane_pool_frontier(r, bytes), 0, (bytes + 7) & ~(int64_t)7 };
		zane_unlock(r->context);
	}
	zane_pool_place(out, node, size, masks);
}
