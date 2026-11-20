/* Copyright (C) 2026 The Zane Authors

   This file is part of the Zane runtime library. It is governed by the GNU
   General Public License, version 3, along with the Zane Compiler Runtime
   Library Exception; the compiler's LICENSE, at the root of its source and
   in share/ of its releases, holds both. */

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
void zane_list_new(zane_list *out) { *out = ZL_MAKE(NULL, 0, 0); }

/* The list's block made at least `needed` bytes. A full list's block
   doubles, from four elements' bytes (zane_list_first_room), in the region that holds its block (§3.6). Up to
   1 MiB it goes into a returned block of the doubled size, or grows in
   place when it is the last thing at the region's frontier with room after
   it, in its chunk or in the scope's frame stretched to hold it, to at
   most a chunk's size (arena.c), or else into new bytes there. Past that it is oversized:
   it grows in place while its reservation holds the doubled size, and
   otherwise moves into an oversized block with a reservation that does: one
   its region was given back, then one its context kept from a drained
   region, else a new one (zane_alloc_growable). Nothing references an element, which is roaming (memory.md
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
	zane_check_region(region);
	region->heap.live--;
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
	/* The room in the list's unit (ZL_ELEMENTS), and the block's bytes. */
	int64_t unit = zl_unit(stride), old = ZL_ROOM_BYTES(list, stride);
	int64_t units = ZL_ROOM(list) ? ZL_ROOM(list) * 2 : zane_list_first_room(stride, stride) / unit;
	while (units * unit < needed) units *= 2;
	if (zl_block_bytes(units, stride) > ZANE_LIST_SPAN_FROM)
		while (zl_block_bytes(units, stride) <= ZANE_CHUNK - ZANE_LINE) units *= 2;
#if defined(ZANE_FRAME_REFS)
	if (units > (int64_t)UINT32_MAX) zane_broken("a list past 2^32 - 1 elements");
#endif
	int64_t room = zl_block_bytes(units, stride);
	zane_mark *region = zane_region_at(ZL_ROOM(list) ? (void *)ZL_ITEMS(list) : (void *)list);
	zane_check_region(region);
	char *items;
	if (room > ZANE_CHUNK - ZANE_LINE) {
		if (old > ZANE_CHUNK - ZANE_LINE && zane_extend(region, ZL_ITEMS(list), room)) {
			list->room = units;
			return;
		}
		items = zane_alloc_growable(region, room);
	} else {
		zane_heap *h = &region->heap;
		int grows = old && ZL_ITEMS(list) + old == h->bump;
		if (grows) {
			grows = !zane_list_returned(region, room) &&
			        (room - old <= h->end - h->bump ||
			         (!zane_is_island(region) && h->end == region->context->frontier && zane_stretch(region, ZL_ITEMS(list) + room, ZANE_CHUNK)));
		}
		/* The block grows where it is, so nothing in it moves. */
		if (grows) {
			h->bump += room - old;
			list->room = units;
			return;
		}
		/* The old block's stack is made first: a stack's record comes from
		   the frontier, and one made after the new block would stop that
		   block growing in place. */
		if (old > 8 * ZANE_CLASSES) zane_stack_of(region, old, ZANE_LIST_ALIGN);
		items = zane_alloc_held(region, room, ZANE_LIST_ALIGN);
	}
	if (old > ZANE_CHUNK - ZANE_LINE) {
		zane_list_move_out(region, items, ZL_ITEMS(list), ZL_COUNT(list) * stride);
	} else {
		if (ZL_COUNT(list)) memcpy(items, ZL_ITEMS(list), (size_t)(ZL_COUNT(list) * stride));
		if (old) zane_free(ZL_ITEMS(list), old, ZANE_LIST_ALIGN);
	}
	ZL_SET_ITEMS(list, items);
	list->room = units;
}

/* An empty list's first block, `room` bytes, when its handle is in the
   innermost scope's frame, or in no memory of the runtime's such as the
   machine stack, so the block is that scope's (zane_region_at): a returned
   block of the size class first (§3.2), else the next bytes at the scope's
   frontier, in its frame stretched to hold them when the heap has no room
   there. Its callers take this path only when the elements it must hold
   fit in ZANE_LIST_FIRST bytes. 0 when none of that holds, and the list
   grows as any other does. */
static inline char *zane_list_first(zane_list *list, int64_t room, int64_t units) {
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
	ZL_SET_ITEMS(list, block);
	list->room = units;
	return block;
}

/* A push onto a full list: its block grown, then the push made. */
static void *zane_list_push_grown(zane_list *list, int64_t stride) __attribute__((noinline));

static void *zane_list_push_grown(zane_list *list, int64_t stride) {
	zane_list_grow(list, (ZL_COUNT(list) + 1) * stride, stride);
	return ZL_ITEMS(list) + list->count++ * stride;
}

/* Room for one more element, `stride` bytes wide, at the end: the address
   the caller then moves it into. Emitted code makes the same push itself
   while the block has room, and calls this only when it is full
   (docs/design/lowering.md §9). An empty list's first block is taken here
   without a call, and anything else grows the list out of line, so this
   needs no frame of its own.

   This, zane_list_reserve and zane_list_room may look at the address of
   `list`, but keep no pointer to it, or anything made from one, past the
   call: LLVM is told `captures(address)` (lib/codegen/runtime_facts.ml). */
void *zane_list_push(zane_list *list, int64_t stride) {
	if (__builtin_expect(ZL_FITS(list, 1, stride), 1)) return ZL_ITEMS(list) + list->count++ * stride;
	if (!ZL_ROOM(list) && stride <= ZANE_LIST_FIRST) {
		int64_t units = zane_list_first_room(stride, stride) / zl_unit(stride);
		char *block = zane_list_first(list, zl_block_bytes(units, stride), units);
		if (block) {
			list->count = 1;
			return block;
		}
	}
	return zane_list_push_grown(list, stride);
}

/* The bytes a list holds with `n` more elements, `stride` bytes wide. A
   count no block could hold, past half the address space or wrapping, stops
   the program here, before ZL_FITS wraps too and takes a block too small for
   room that the pushes after it no longer check (zane_list_room). */
static int64_t zane_list_needed(zane_list *list, int64_t n, int64_t stride) {
	int64_t count = 0, bytes = 0;
	if (__builtin_add_overflow(ZL_COUNT(list), n, &count) || __builtin_mul_overflow(count, stride, &bytes) ||
	    bytes > INT64_MAX / 2)
		zane_broken("out of memory for a list's elements");
	return bytes;
}

/* As `zane_list_push`, with room made for `n` elements, this push's and
   the `n - 1` after it, which emitted code then makes as plain stores with
   no check of their own (docs/design/lowering.md §9). Emitted code calls
   this only when the block lacks that room. */
void *zane_list_reserve(zane_list *list, int64_t stride, int64_t n) {
	if (!ZL_ROOM(list) && n * stride <= ZANE_LIST_FIRST) {
		int64_t units = zane_list_first_room(n * stride, stride) / zl_unit(stride);
		char *block = zane_list_first(list, zl_block_bytes(units, stride), units);
		if (block) {
			list->count = 1;
			return block;
		}
	}
	int64_t bytes = zane_list_needed(list, n, stride);
	if (!ZL_FITS(list, n, stride)) zane_list_grow(list, bytes, stride);
	return ZL_ITEMS(list) + list->count++ * stride;
}

/* Experimental (docs/experiments/goose-comparison): room made for `n` more
   elements, which a loop that pushes once each time round then pushes as
   plain stores with no check of their own. */
void zane_list_room(zane_list *list, int64_t stride, int64_t n) {
	if (n <= 0) return;
	int64_t bytes = zane_list_needed(list, n, stride);
	if (!ZL_FITS(list, n, stride)) zane_list_grow(list, bytes, stride);
}

/* `count` elements of `from`, from
   its element `start` (counted from 1), copied onto the end of `list`, as
   one copy. `from` may be `list` itself: its range is read after the block
   has grown. The elements own no blocks, so their bytes are all of them. */
void zane_list_append(zane_list *list, const zane_list *from, int64_t start, int64_t count, int64_t stride) {
	if (count < 0 || start < 1 || start - 1 > ZL_COUNT(from) - count) zane_out_of_range();
	if (count == 0) return;
	if (!ZL_FITS(list, count, stride)) zane_list_grow(list, zane_list_needed(list, count, stride), stride);
	memcpy(ZL_ITEMS(list) + ZL_COUNT(list) * stride, ZL_ITEMS(from) + (start - 1) * stride, (size_t)(count * stride));
	list->count += count;
}

/* `copyRange`: `count` elements of `from`, from its element `start`,
   copied over `list`'s own from its element `at` (both counted from 1), as
   one copy. A call cannot pass a list it writes as one it reads, so the
   two are different lists. Either range out of its list stops the
   program. The elements own no blocks, so their bytes are all of them. */
void zane_list_copy(zane_list *list, int64_t at, const zane_list *from, int64_t start, int64_t count, int64_t stride) {
	if (count < 0 || start < 1 || start - 1 > ZL_COUNT(from) - count || at < 1 || at - 1 > ZL_COUNT(list) - count)
		zane_out_of_range();
	if (count == 0) return;
	memmove(ZL_ITEMS(list) + (at - 1) * stride, ZL_ITEMS(from) + (start - 1) * stride, (size_t)(count * stride));
}

/* Whether `count` elements of
   `list` from its element `start` and of `other` from `other_start`
   (counted from 1) are the same bytes, 1 or 0, as one comparison. The
   elements own no blocks, so their bytes are all of them. */
int64_t zane_list_same(const zane_list *list, int64_t start, const zane_list *other, int64_t other_start, int64_t count,
                       int64_t stride) {
	if (count < 0 || start < 1 || start - 1 > ZL_COUNT(list) - count || other_start < 1 ||
	    other_start - 1 > ZL_COUNT(other) - count)
		zane_out_of_range();
	return memcmp(ZL_ITEMS(list) + (start - 1) * stride, ZL_ITEMS(other) + (other_start - 1) * stride,
	              (size_t)(count * stride)) == 0;
}

/* `hashRange`: a hash of the bytes of `count` elements of `list` from
   its element `start` (counted from 1). Blocks of
   32 bytes go to four lanes mixed independently, so the multiplies overlap
   rather than wait on each other; the words after them go to the first
   lane, and the tail and the length close it. A word is mixed in by
   xoring, a multiply by 2^64 / phi and a rotate, and the close is two
   multiply-xorshift rounds. Equal ranges hash alike within one run of a
   program; the value is not specified beyond that. */
static inline uint64_t zane_hash_mix(uint64_t h, uint64_t w) {
	h = (h ^ w) * UINT64_C(0x9E3779B97F4A7C15);
	/* A rotate written as shifts, LLVM turns into a second multiply by the
	   constant shifted; the builtin stays one `rol`. */
#if defined(__clang__)
	return __builtin_rotateleft64(h, 29);
#else
	return (h << 29) | (h >> 35);
#endif
}

static int64_t zane_bytes_hash(const unsigned char *p, size_t n);

int64_t zane_list_hash(const zane_list *list, int64_t start, int64_t count, int64_t stride) {
	if (count < 0 || start < 1 || start - 1 > ZL_COUNT(list) - count) zane_out_of_range();
	return zane_bytes_hash((const unsigned char *)ZL_ITEMS(list) + (start - 1) * stride, (size_t)(count * stride));
}

/* The same hash of a string's bytes,
   for a hash table's slots. */
int64_t zane_text_hash(const zane_text *text) {
	return zane_bytes_hash((const unsigned char *)text->bytes, (size_t)text->length);
}

static int64_t zane_bytes_hash(const unsigned char *p, size_t n) {
	uint64_t h = (uint64_t)n * UINT64_C(0x9E3779B97F4A7C15);
	if (n >= 32) {
		uint64_t a = h, b = h + 1, c = h + 2, d = h + 3;
		for (; n >= 32; n -= 32, p += 32) {
			uint64_t w[4];
			memcpy(w, p, 32);
			a = zane_hash_mix(a, w[0]);
			b = zane_hash_mix(b, w[1]);
			c = zane_hash_mix(c, w[2]);
			d = zane_hash_mix(d, w[3]);
		}
		h = zane_hash_mix(zane_hash_mix(zane_hash_mix(a, b), c), d);
	}
	/* The bytes left: the
	   words before the last 8 bytes, then the last 8 as one load that may
	   overlap the word before, so a key of 8 bytes or more takes no branch
	   on its length but the loop's; else two 4-byte words or three single
	   bytes. */
	size_t total = n;
	uint64_t w = 0;
	if (n >= 8) {
		for (; n > 8; n -= 8, p += 8) {
			uint64_t v;
			memcpy(&v, p, 8);
			h = zane_hash_mix(h, v);
		}
		memcpy(&w, p + n - 8, 8);
	} else if (n >= 4) {
		uint32_t lo, hi;
		memcpy(&lo, p, 4);
		memcpy(&hi, p + n - 4, 4);
		w = lo | (uint64_t)hi << 32;
	} else if (n > 0)
		w = p[0] | (uint64_t)p[n / 2] << 8 | (uint64_t)p[n - 1] << 16;
	h = (h ^ w ^ total) * UINT64_C(0x9E3779B97F4A7C15);
	h = (h ^ (h >> 32)) * UINT64_C(0xD6E8FEB86659FD93);
	h ^= h >> 32;
	return (int64_t)(h >> 1);
}

/* A list of integers sorted in
   place, ascending, as a standard library's sort is, written out for each
   element type so every comparison is an inline compare. A pattern-
   defeating quicksort: input already in order, or in strictly descending
   order, takes one pass; otherwise each round partitions a range around a
   median pivot (of three, or of three medians of three from 128 elements
   on) with a Lomuto partition that does not branch on the data, defers
   the larger side and goes on with the smaller. A range whose pivot is no
   greater than the element just before it holds nothing less than the
   pivot, so one partition moves the elements equal to it to the front,
   where they are done, and many equal keys cost linear passes. A range
   still being partitioned 2 log2(n) rounds deep is heapsorted; ranges of
   10 or fewer are insertion sorted. `kind` is what the elements are: 0 a
   signed 32-bit integer, 1 a signed 64-bit one, 2 an unsigned byte. */
#define ZANE_SORT(NAME, T)                                                             \
	static void NAME##_insert(T *a, int64_t n) {                                     \
		for (int64_t i = 1; i < n; i++) {                                            \
			T v = a[i];                                                              \
			int64_t j = i;                                                           \
			while (j > 0 && v < a[j - 1]) {                                          \
				a[j] = a[j - 1];                                                     \
				j--;                                                                 \
			}                                                                        \
			a[j] = v;                                                                \
		}                                                                            \
	}                                                                                \
	static void NAME##_sift(T *a, int64_t i, int64_t n) {                            \
		T v = a[i];                                                                  \
		for (int64_t c; (c = 2 * i + 1) < n; i = c) {                                \
			if (c + 1 < n && a[c] < a[c + 1]) c++;                                   \
			if (!(v < a[c])) break;                                                  \
			a[i] = a[c];                                                             \
		}                                                                            \
		a[i] = v;                                                                    \
	}                                                                                \
	static void NAME##_heap(T *a, int64_t n) {                                       \
		for (int64_t i = n / 2; i-- > 0;) NAME##_sift(a, i, n);                      \
		for (int64_t m = n - 1; m > 0; m--) {                                        \
			T t = a[0];                                                              \
			a[0] = a[m];                                                             \
			a[m] = t;                                                                \
			NAME##_sift(a, 0, m);                                                    \
		}                                                                            \
	}                                                                                \
	static int64_t NAME##_median(const T *a, int64_t x, int64_t y, int64_t z) {      \
		int l = a[x] < a[y];                                                         \
		if (l != (a[x] < a[z])) return x;                                            \
		return (a[y] < a[z]) != l ? z : y;                                           \
	}                                                                                \
	static int64_t NAME##_pivot(const T *a, int64_t n) {                             \
		int64_t n8 = n / 8, x = 0, y = n8 * 4, z = n8 * 7;                           \
		if (n < 128) return NAME##_median(a, x, y, z);                               \
		int64_t m8 = n8 / 8;                                                         \
		return NAME##_median(a, NAME##_median(a, x, x + m8 * 4, x + m8 * 7),         \
		                     NAME##_median(a, y, y + m8 * 4, y + m8 * 7),            \
		                     NAME##_median(a, z, z + m8 * 4, z + m8 * 7));           \
	}                                                                                \
	/* a[0] is the pivot: the elements after it that go before it (less,        \
	   or no greater when `equal`) moved to the front of a[1..], how many. */   \
	static int64_t NAME##_partition(T *a, int64_t n, int equal) {                    \
		T p = a[0];                                                                  \
		int64_t lt = 1;                                                              \
		if (equal)                                                                   \
			for (int64_t i = 1; i < n; i++) {                                        \
				T x = a[i];                                                          \
				a[i] = a[lt];                                                        \
				a[lt] = x;                                                           \
				lt += !(p < x);                                                      \
			}                                                                        \
		else                                                                         \
			for (int64_t i = 1; i < n; i++) {                                        \
				T x = a[i];                                                          \
				a[i] = a[lt];                                                        \
				a[lt] = x;                                                           \
				lt += x < p;                                                         \
			}                                                                        \
		return lt - 1;                                                               \
	}                                                                                \
	static void NAME##_sort(T *xs, int64_t n) {                                      \
		if (n <= 10) {                                                               \
			NAME##_insert(xs, n);                                                    \
			return;                                                                  \
		}                                                                            \
		int64_t r = 2;                                                               \
		if (xs[1] < xs[0]) {                                                         \
			while (r < n && xs[r] < xs[r - 1]) r++;                                  \
			if (r == n)                                                              \
				for (int64_t i = 0, j = n - 1; i < j; i++, j--) {                    \
					T t = xs[i];                                                     \
					xs[i] = xs[j];                                                   \
					xs[j] = t;                                                       \
				}                                                                    \
		} else                                                                       \
			while (r < n && !(xs[r] < xs[r - 1])) r++;                               \
		if (r == n) return;                                                          \
		int limit = 0;                                                               \
		for (int64_t m = n; m > 1; m >>= 1) limit += 2;                              \
		int64_t stack[3 * 64], top = 0, lo = 0, hi = n;                              \
		for (;;) {                                                                   \
			T *v = xs + lo;                                                          \
			int64_t len = hi - lo;                                                   \
			if (len > 10 && limit > 0) {                                             \
				limit--;                                                             \
				int64_t q = NAME##_pivot(v, len);                                    \
				T t = v[0];                                                          \
				v[0] = v[q];                                                         \
				v[q] = t;                                                            \
				if (lo > 0 && !(xs[lo - 1] < v[0])) {                                \
					int64_t m = NAME##_partition(v, len, 1);                         \
					t = v[0];                                                        \
					v[0] = v[m];                                                     \
					v[m] = t;                                                        \
					lo += m + 1;                                                     \
					continue;                                                        \
				}                                                                    \
				int64_t m = NAME##_partition(v, len, 0);                             \
				t = v[0];                                                            \
				v[0] = v[m];                                                         \
				v[m] = t;                                                            \
				if (m < len - 1 - m) {                                               \
					stack[top++] = lo + m + 1;                                       \
					stack[top++] = hi;                                               \
					stack[top++] = limit;                                            \
					hi = lo + m;                                                     \
				} else {                                                             \
					stack[top++] = lo;                                               \
					stack[top++] = lo + m;                                           \
					stack[top++] = limit;                                            \
					lo += m + 1;                                                     \
				}                                                                    \
				continue;                                                            \
			}                                                                        \
			if (len > 10) NAME##_heap(v, len);                                       \
			else NAME##_insert(v, len);                                              \
			if (top == 0) return;                                                    \
			limit = (int)stack[--top];                                               \
			hi = stack[--top];                                                       \
			lo = stack[--top];                                                       \
		}                                                                            \
	}
ZANE_SORT(zane_sort_i32, int32_t)
ZANE_SORT(zane_sort_i64, int64_t)
ZANE_SORT(zane_sort_u8, uint8_t)
#undef ZANE_SORT

void zane_list_sort(zane_list *list, int64_t kind) {
	int64_t n = ZL_COUNT(list);
	switch (kind) {
	case 0: zane_sort_i32_sort((int32_t *)ZL_ITEMS(list), n); break;
	case 1: zane_sort_i64_sort((int64_t *)ZL_ITEMS(list), n); break;
	default: zane_sort_u8_sort((uint8_t *)ZL_ITEMS(list), n); break;
	}
}

/* `sortBy`: a list of `I32`s, each an index into `keys` (a list of `I64`s, counted from 1), sorted stably by the key
   each names: a natural merge sort of the indices, comparing the keys they
   name. Runs,
   ascending or strictly descending (reversed), are found first, those
   shorter than 16 made 16 long by insertion; a pass then merges
   neighbouring runs, copying a pair whose halves are already in order as
   they are, until one run is left. */
static void zane_keyed_insert(int32_t *v, const int64_t *key, int64_t n, int64_t from) {
	for (int64_t i = from; i < n; i++) {
		int32_t x = v[i];
		int64_t kx = key[x], j = i;
		while (j > 0 && kx < key[v[j - 1]]) {
			v[j] = v[j - 1];
			j--;
		}
		v[j] = x;
	}
}

/* Two runs merged into `d`. Where the merge before it alternated sides
   often (`*chaotic`), each pick is a select, which no misprediction costs;
   where it did not, a branch, which the processor runs ahead of. */
static void zane_keyed_merge(const int32_t *l, int64_t nl, const int32_t *r, int64_t nr, int32_t *d, const int64_t *key,
                             int *chaotic) {
	if (key[l[nl - 1]] <= key[r[0]]) {
		memcpy(d, l, (size_t)nl * sizeof *d);
		memcpy(d + nl, r, (size_t)nr * sizeof *d);
		return;
	}
	int64_t a = 0, b = 0, k = 0, switches = 0;
	int last_r = 0;
	if (*chaotic) {
		while (a < nl && b < nr) {
			int32_t x = l[a], y = r[b];
			int take_r = key[y] < key[x];
			d[k++] = take_r ? y : x;
			b += take_r;
			a += !take_r;
			switches += take_r != last_r;
			last_r = take_r;
		}
	} else {
		int32_t x = l[0], y = r[0];
		int64_t kx = key[x], ky = key[y];
		for (;;) {
			if (ky < kx) {
				d[k++] = y;
				switches += !last_r;
				last_r = 1;
				if (++b == nr) break;
				y = r[b];
				ky = key[y];
			} else {
				d[k++] = x;
				switches += last_r;
				last_r = 0;
				if (++a == nl) break;
				x = l[a];
				kx = key[x];
			}
		}
	}
	*chaotic = switches * 4 > k;
	if (a < nl) memcpy(d + k, l + a, (size_t)(nl - a) * sizeof *d);
	else memcpy(d + k, r + b, (size_t)(nr - b) * sizeof *d);
}

void zane_list_sort_by(zane_list *list, const zane_list *keys) {
	int64_t n = ZL_COUNT(list), nk = ZL_COUNT(keys);
	if (n < 2) return;
	int32_t *values = (int32_t *)ZL_ITEMS(list);
	for (int64_t i = 0; i < n; i++)
		if (values[i] < 1 || values[i] > nk) zane_out_of_range();
	/* Indices from 1: the key of index x is key[x]. */
	const int64_t *key = (const int64_t *)ZL_ITEMS(keys) - 1;
	int32_t *v = values, *tmp = malloc((size_t)n * sizeof *tmp);
	/* The runs' ends, in order. */
	int64_t *ends = malloc((size_t)(n / 16 + 2) * sizeof *ends);
	if (!tmp || !ends) zane_broken("out of memory for a sort");
	int64_t runs = 0;
	for (int64_t lo = 0; lo < n;) {
		int64_t e = lo + 1;
		if (e < n && key[v[e]] < key[v[lo]]) {
			while (e + 1 < n && key[v[e + 1]] < key[v[e]]) e++;
			e++;
			for (int64_t a = lo, b = e - 1; a < b; a++, b--) {
				int32_t t = v[a];
				v[a] = v[b];
				v[b] = t;
			}
		} else {
			while (e < n && key[v[e]] >= key[v[e - 1]]) e++;
		}
		if (e - lo < 16) {
			int64_t to = lo + 16 < n ? lo + 16 : n;
			zane_keyed_insert(v + lo, key, to - lo, e - lo);
			e = to;
		}
		ends[runs++] = e;
		lo = e;
	}
	int32_t *src = v, *dst = tmp;
	int chaotic = 1;
	while (runs > 1) {
		int64_t start = 0, w = 0;
		for (int64_t i = 0; i < runs; i += 2) {
			int64_t mid = ends[i], end = mid;
			if (i + 1 < runs) {
				end = ends[i + 1];
				zane_keyed_merge(src + start, mid - start, src + mid, end - mid, dst + start, key, &chaotic);
			} else {
				memcpy(dst + start, src + start, (size_t)(end - start) * sizeof *dst);
			}
			ends[w++] = end;
			start = end;
		}
		runs = w;
		int32_t *t = src;
		src = dst;
		dst = t;
	}
	if (src != values) memcpy(values, src, (size_t)n * sizeof *values);
	free(ends);
	free(tmp);
}

/* The element at `index`, counted from 1 (control-flow.md §3.4). */
void *zane_list_at(zane_list *list, int64_t index, int64_t stride) {
	if (index < 1 || index > ZL_COUNT(list)) zane_out_of_range();
	return ZL_ITEMS(list) + (index - 1) * stride;
}

/* `n` bytes moved down from `from` to `to`, below it. A list's removal
   moves its later elements down by one element's size, and for a large
   move glibc's memmove uses `rep movsb`, which some Intel processors run at
   about a byte a cycle when the source is less than 64 bytes past the
   destination: on one, shifting a 60 KB list by 32 bytes ran at 3 GB/s
   (docs/experiments/goose-comparison). glibc takes `rep movsb` from 4 KiB
   on with AVX2. Past that, moved 2 KiB at a time, lowest first, each piece
   takes glibc's vector loop instead, at 59 GB/s there; each writes below
   what the next reads. */
static void zane_shift_down(char *to, const char *from, int64_t n) {
	if (from - to >= 64 || n <= 4096) {
		memmove(to, from, (size_t)n);
		return;
	}
	for (int64_t i = 0; i < n; i += 2048) memmove(to + i, from + i, (size_t)(n - i < 2048 ? n - i : 2048));
}

/* The list closes the gap left by the element at `index`, counted from 1,
   which the caller has already moved out: the later elements move down one
   place, keeping their order, and the list keeps its block. Nothing
   references an element, so moving their bytes moves them. Emitted code makes
   the same removal itself, with the stride a constant
   (docs/design/lowering.md §9). */
void zane_list_remove(zane_list *list, int64_t index, int64_t stride) {
	char *at = ZL_ITEMS(list) + (index - 1) * stride;
	zane_shift_down(at, at + stride, (ZL_COUNT(list) - index) * stride);
	list->count--;
}

/* As `zane_list_remove`, but the last element moves into the place, so only
   one element moves and the order is not kept. */
void zane_list_swap_remove(zane_list *list, int64_t index, int64_t stride) {
	char *last = ZL_ITEMS(list) + (ZL_COUNT(list) - 1) * stride;
	if (index < ZL_COUNT(list)) memcpy(ZL_ITEMS(list) + (index - 1) * stride, last, (size_t)stride);
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
   holds its nodes, all of one size, each after the nodes below it, so the
   root is last. A node's links to the nodes below it are 32-bit offsets
   from the link to its target, so a pool copied onto the end of another
   keeps them. A function that returns a pooled variant is given the pool
   to build it in, and builds every node there (lower.ml, `into`). */

/* The root's node. */
char *zane_pool_root(zane_list *pool, int64_t size) { return ZL_ITEMS(pool) + pool->count - size; }

/* The node a link names. A link may be at any byte of a packed node. */
char *zane_link(char *link) {
	int32_t distance;
	memcpy(&distance, link, 4);
	return link + distance;
}

/* A node's tag: its first byte, a packed node's whole tag and the low byte
   of a 4-byte one, on the little-endian targets Zane builds for. */
static int zane_pool_tag(const char *node) { return *(const uint8_t *)node; }

/* The most bytes a pool holds, so that every link in it fits 32 bits. */
enum { ZANE_POOL_MOST = INT32_MAX };

/* Experimental pool reuse (`ZANE_POOL_REUSE=1` when the program runs): a
   new pool starts as large as this thread's last pool grew, up to a
   chunk, so a loop that builds trees of one size grows its pool once.
   Each new pool's block is at its region's frontier, where the last one
   was when its region drained, so it is the same memory, warm. */
static _Thread_local int64_t zane_pool_hint;
static int zane_pool_reusing = -1;

static int zane_pool_reuse(void) {
	if (zane_pool_reusing < 0) {
		const char *v = getenv("ZANE_POOL_REUSE");
		zane_pool_reusing = v && strcmp(v, "1") == 0;
	}
	return zane_pool_reusing;
}

/* The region a block is in, found without the page map's lookup when it is
   the innermost scope's. */
static zane_mark *zane_pool_region(void *block) {
	zane_mark *m = zane_open;
	if (m) {
		uintptr_t entry = zane_page_entry(block);
		if (entry == (uintptr_t)m) return m;
		zane_context *c = m->context;
		if (entry == ((uintptr_t)c | 1) && c->top == m && (char *)block >= (char *)m) return m;
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

/* `pool`'s block made at least `total` bytes, and at least twice its room:
   in place when it ends at its region's frontier, else moved to a block of
   that size there, or grown as a list grows once that passes a chunk. An
   empty handle gets its first block where `zane_pool_new` makes one. */
__attribute__((noinline)) void zane_pool_reserve(zane_list *pool, int64_t total) {
	if (total <= pool->room) return;
	if (total > ZANE_POOL_MOST) zane_broken("a pooled variant past 2 GiB");
	if (!ZL_ITEMS(pool)) {
		zane_mark *r = zane_pool_home(pool);
		zane_check_region(r);
		total = (total + 7) & ~(int64_t)7;
		*pool = ZL_MAKE(zane_pool_frontier(r, total), pool->count, total);
		return;
	}
	if (total < 2 * pool->room) total = 2 * pool->room;
	if (total > ZANE_POOL_MOST) total = ZANE_POOL_MOST;
	total = (total + 7) & ~(int64_t)7;
	if (total <= ZANE_CHUNK - ZANE_LINE && total > zane_pool_hint) zane_pool_hint = total;
	zane_mark *r = zane_pool_region(ZL_ITEMS(pool));
	zane_heap *h = &r->heap;
	zane_check_region(r);
	if (ZL_ITEMS(pool) + pool->room == h->bump &&
	    (ZL_ITEMS(pool) + total <= h->end ||
	     (!zane_is_island(r) && h->end == r->context->frontier && total <= ZANE_CHUNK - ZANE_LINE &&
	      zane_stretch(r, ZL_ITEMS(pool) + total, ZANE_CHUNK)))) {
		h->bump = ZL_ITEMS(pool) + total;
		pool->room = total;
		return;
	}
	if (total > ZANE_CHUNK - ZANE_LINE || pool->room > ZANE_CHUNK - ZANE_LINE) {
		zane_list_grow(pool, total, 1);
		return;
	}
	char *block = zane_pool_frontier(r, total);
	memcpy(block, ZL_ITEMS(pool), (size_t)pool->count);
	zane_free(ZL_ITEMS(pool), pool->room, ZANE_LIST_ALIGN);
	ZL_SET_ITEMS(pool, block);
	pool->room = total;
}

/* The block at `items` no longer counted as out in its region. */
static void zane_pool_abandon(char *items) {
	zane_mark *r = zane_region_at(items);
	zane_check_region(r);
	r->heap.live--;
}

/* A pool for the handle at `out`, empty, its first block made in the
   region the handle's value is made in, so a build that a callee makes
   into it grows it there (docs/experiments). */
void zane_pool_new(zane_list *out) {
	zane_mark *r = zane_pool_home(out);
	int64_t room = zane_pool_hint > ZANE_LIST_FIRST && zane_pool_reuse() ? zane_pool_hint : ZANE_LIST_FIRST;
	zane_check_region(r);
	*out = ZL_MAKE(zane_pool_frontier(r, room), 0, room);
}

/* A pool for the handle at `out` as `zane_pool_new` makes one, in a block
   that never needs to grow (`zane_alloc_unbounded`), for code that pushes
   into it without checking its room (lib/codegen/pool_cache.ml). */
void zane_pool_new_unbounded(zane_list *out) {
	zane_mark *r = zane_pool_home(out);
	zane_check_region(r);
	*out = ZL_MAKE(zane_alloc_unbounded(r), 0, ZANE_POOL_MOST - ZANE_LINE);
}

/* A node of `size` bytes, copied from `node`, put at the end of `pool`,
   after the `n` subtrees it links to, whose top nodes are at the offsets
   `o0`..`o3`; its link to each is written `l0`..`l3` bytes into it. Its
   offset. */
int64_t zane_pool_push(zane_list *pool, const char *node, int64_t size, int64_t n, int64_t o0, int64_t l0,
                       int64_t o1, int64_t l1, int64_t o2, int64_t l2, int64_t o3, int64_t l3) {
	int64_t at = pool->count;
	if (__builtin_expect(at + size > pool->room, 0)) zane_pool_reserve(pool, at + size);
	char *made = ZL_ITEMS(pool) + at;
	memcpy(made, node, (size_t)size);
	int64_t to[4] = { o0, o1, o2, o3 }, links[4] = { l0, l1, l2, l3 };
	for (int i = 0; i < n; i++) {
		int32_t distance = (int32_t)(to[i] - (at + links[i]));
		memcpy(made + links[i], &distance, 4);
	}
	pool->count = at + size;
	return at;
}

/* The pool `from` holds, its nodes `size` bytes each, moved onto the end
   of `pool`: copied, its links relative so they hold. Its block is no
   longer out, though its bytes stay where they are until its region
   drains. Its top node's offset there. */
int64_t zane_pool_append(zane_list *pool, zane_list *from, int64_t size) {
	if (from->count < size) zane_broken("an empty pooled variant");
	int64_t at = pool->count;
	if (at + from->count > pool->room) zane_pool_reserve(pool, at + from->count);
	memcpy(ZL_ITEMS(pool) + at, ZL_ITEMS(from), (size_t)from->count);
	pool->count = at + from->count;
	if (from->room) zane_pool_abandon(ZL_ITEMS(from));
	*from = ZL_MAKE(NULL, 0, 0);
	return pool->count - size;
}

/* How many nodes the subtree at `node` has, each link in a node of case
   `c` at the bytes set in `masks[c]`. */
static int64_t zane_pool_count(const char *node, const int64_t *masks) {
	int c = zane_pool_tag(node);
	uint64_t mask = c < 4 ? (uint64_t)masks[c] : 0;
	int64_t n = 1;
	for (int w = 0; mask; w++, mask >>= 1)
		if (mask & 1) n += zane_pool_count(zane_link((char *)node + w), masks);
	return n;
}

/* The subtree at `node` copied onto the end of `pool`, children first, as
   a build would have laid it out. Its copy's offset. */
static int64_t zane_pool_place(zane_list *pool, const char *node, int64_t size, const int64_t *masks) {
	int c = zane_pool_tag(node);
	uint64_t mask = c < 4 ? (uint64_t)masks[c] : 0;
	int64_t children[64];
	for (int w = 0; mask >> w; w++)
		if ((mask >> w) & 1) children[w] = zane_pool_place(pool, zane_link((char *)node + w), size, masks);
	int64_t at = pool->count;
	char *made = ZL_ITEMS(pool) + at;
	memcpy(made, node, (size_t)size);
	for (int w = 0; mask >> w; w++)
		if ((mask >> w) & 1) {
			int32_t distance = (int32_t)(children[w] - (at + w));
			memcpy(made + w, &distance, 4);
		}
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
		*out = ZL_MAKE(NULL, 0, 0);
		zane_list_grow(out, bytes, 1);
	} else {
		zane_mark *r = zane_pool_home(out);
		zane_check_region(r);
		*out = ZL_MAKE(zane_pool_frontier(r, bytes), 0, (bytes + 7) & ~(int64_t)7);
	}
	zane_pool_place(out, node, size, masks);
}

