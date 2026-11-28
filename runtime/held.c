/* Copyright (C) 2026 The Zane Authors

   This file is part of the Zane runtime library. It is governed by the GNU
   General Public License, version 3, along with the Zane Compiler Runtime
   Library Exception; the compiler's LICENSE, at the root of its source and
   in share/ of its releases, holds both. */

#include "zane_internal.h"

/* ---------------------------------------------------------------------- */
/* C-held objects (packages.md §8.5, docs/design/ffi.md F22)              */
/* ---------------------------------------------------------------------- */

/* An owner an exported lambda returns to C settles in a top-level scope of
   its own, which nests in no other scope, since a host creates and ends
   objects in any order. Its region is a subject region's kind
   (ZANE_ISLAND_DEPTH), which outlives no scope and has no frame, and its
   context is one of its own with no range, which keeps the region's warm
   chunks: the host rule (concurrency.md §4.7) lets one host call at a time
   write the object, so only that call allocates or returns a block in the
   region, and no lock guards it. The object's bytes are the first block of
   the region, so C's pointer to them finds the scope through the chunk
   map. */
/* A value an exported lambda with the object as its `this T mut` subject
   returned, whose lists C reads as views (packages.md §8.2): its blocks
   live in the object's scope until the next call that borrows the object
   mutably, or ends it, ends the value. */
typedef struct zane_lent {
	struct zane_lent *next;
	const zane_type *type;
	char value[];
} zane_lent;

typedef struct zane_c_held {
	zane_mark mark;
	zane_context context;
	zane_lent *lent;
} zane_c_held;

static zane_c_held *zane_c_held_of(const char *object) {
	zane_mark *m = zane_region_at(object);
	if (!m || !zane_is_island(m)) zane_broken("a pointer a host passed names no object it holds");
	return (zane_c_held *)m;
}

/* A new top-level scope, and the address of `size` bytes in it aligned to
   `align` for the object an exported lambda's result is written into. */
char *zane_c_held_new(int64_t size, int64_t align) {
	zane_c_held *h = calloc(1, sizeof *h);
	if (!h) zane_broken("out of memory for an object a host holds");
	h->mark.context = &h->context;
	h->mark.depth = ZANE_ISLAND_DEPTH;
	return zane_alloc_held(&h->mark, size < 8 ? 8 : size, align < 8 ? 8 : align);
}

/* The object at `object`, of `type`, written there by the call that made it:
   the blocks it owns move from the call's scopes into its own, where they
   stay while the host holds it. */
void zane_c_held_settle(char *object, const zane_type *type) {
	if (type) zane_move(object, type, &zane_c_held_of(object)->mark, 0);
}

/* The value at `value`, `size` bytes of `type`, which an exported lambda
   whose subject is the object at `object` returned: its blocks move into
   the object's scope, and it is kept there for C to read its lists through
   views. */
void zane_c_held_lend(char *object, char *value, int64_t size, const zane_type *type) {
	if (!type) return;
	zane_c_held *h = zane_c_held_of(object);
	zane_move(value, type, &h->mark, 0);
	zane_lent *l = malloc(sizeof *l + (size_t)size);
	if (!l) zane_broken("out of memory for a value a host reads");
	l->type = type;
	memcpy(l->value, value, (size_t)size);
	l->next = h->lent;
	h->lent = l;
}

/* Every value the object's subject calls lent C ends, and its blocks go
   back to the object's scope. */
static void zane_c_held_return(zane_c_held *h) {
	while (h->lent) {
		zane_lent *l = h->lent;
		h->lent = l->next;
		zane_end(l->value, l->type);
		free(l);
	}
}

/* A call that borrows the object at `object` mutably begins: the views C
   was given by the calls before it end (packages.md §8.5). */
void zane_c_held_renew(char *object) { zane_c_held_return(zane_c_held_of(object)); }

/* The object at `object` ended, by an exported lambda that took its owner,
   whose scope ended its value: its top-level scope drains, and its memory
   goes back whole (memory.md §3.1). When drains are checked, a block the
   object's value did not give back stops the program, as a scope's does. */
void zane_c_held_end(char *object) {
	zane_c_held *h = zane_c_held_of(object);
	zane_c_held_return(h);
	h->mark.heap.live--;
	if (zane_checking && h->mark.heap.live != 0) zane_broken("an object a host held drained with blocks still out");
	zane_unmap(&h->mark);
	zane_give_spares(&h->context);
	free(h);
}
