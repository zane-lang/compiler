/* What a program defines for the runtime, and slots placed the way a test
   can place them. Emitted code lays a scope's frame out at compile time
   (lib/codegen/frames.ml); a test instead grows the innermost scope's
   frame by each slot it asks for, which places the same bytes, since the
   innermost frame is the last one in its context's range. */

#ifndef ZANE_TEST_SCOPES_H
#define ZANE_TEST_SCOPES_H

#include "zane_internal.h"

const int64_t zane_fixed_region = (int64_t)256 << 20, zane_spawned_fixed_region = (int64_t)8 << 20;

/* A zeroed slot at the end of the innermost scope's frame, listed for a
   checked drain when its value may own blocks. The next frame starts at a
   16-byte boundary, as every frame does. */
static inline void *test_slot(zane_mark *scope, int64_t size, int64_t align, const zane_type *type) {
	zane_context *c = zane_self;
	if (scope != c->top) zane_broken("a slot placed in a scope that is not innermost");
	zane_lock(c);
	char *at = (char *)(((uintptr_t)c->frontier + (uintptr_t)align - 1) / (uintptr_t)align * (uintptr_t)align);
	if (size > c->limit - at) zane_too_deep_in(c);
	c->frontier = (char *)(((uintptr_t)at + (uintptr_t)size + 15) / 16 * 16);
	zane_unlock(c);
	memset(at, 0, (size_t)size);
	if (zane_checking && type) zane_hold(at, type);
	return at;
}

/* A spawned call's frame, after the zeroed header the runtime fills. */
static inline void *test_frame(zane_mark *scope, int64_t size) {
	zane_task *t = test_slot(scope, (int64_t)sizeof(zane_task) + size, 8, NULL);
	return t + 1;
}

#endif
