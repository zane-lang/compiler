/* The runtime's scope arenas, tested in C on their own (docs/design/lowering.md
   L17). The runtime is linked whole, and this file is the program it
   calls. Each check prints `yes` when it holds and `no` when it does not;
   the runtime's own `main` then checks every scope drained. */

#include "scopes.h"

#include <string.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* `depth` scopes nested inside the innermost, each with a slot, whose
   records and slots are kept in order, outermost first. */
static void nest(zane_mark **records, int64_t **slots, int depth) {
	for (int i = 0; i < depth; i++) {
		records[i] = zane_scope_enter(0);
		slots[i] = test_slot(records[i], 8, 8, NULL);
		*slots[i] = i;
	}
}

static void unnest(zane_mark **records, int depth) {
	for (int i = depth - 1; i >= 0; i--) zane_scope_drain(records[i]);
}

void zane_main(void) {
	zane_context *self = zane_self;

	/* The context's range starts at a 1 MiB boundary, and every MiB of it
	   and of its guard is the context's in the chunk map. */
	int listed = (uintptr_t)self->base % ZANE_CHUNK == 0;
	for (char *at = self->base; at < self->limit + ZANE_GUARD; at += ZANE_CHUNK)
		listed = listed && *zane_page(at, 0) == ((uintptr_t)self | 1);
	check(listed && self->limit - self->base == zane_fixed_region);

	/* A slot is aligned as asked, and the next one follows it. */
	zane_mark *outer = zane_scope_enter(0);
	char *a = test_slot(outer, 1, 1, NULL);
	int64_t *b = test_slot(outer, 8, 8, NULL);
	check((uintptr_t)b % 8 == 0 && (char *)b > a);

	/* A scope's frame starts with its record, where the scope around it
	   stopped, and draining it hands the same memory to the next scope. */
	zane_mark *inner = zane_scope_enter(0);
	char *c = test_slot(inner, 16, 8, NULL);
	check((char *)inner > (char *)b && c > (char *)inner && inner->outer == outer &&
	      inner->depth == outer->depth + 1);
	zane_scope_drain(inner);
	inner = zane_scope_enter(0);
	check(test_slot(inner, 16, 8, NULL) == c);
	zane_scope_drain(inner);

	/* Several MiB of slots in one scope become usable as they are first
	   touched, and every slot stays intact. */
	inner = zane_scope_enter(0);
	enum { N = 3 * 65536 };
	static int64_t *slots[N];
	for (int i = 0; i < N; i++) {
		slots[i] = test_slot(inner, 16, 8, NULL);
		slots[i][0] = i;
		slots[i][1] = -i;
	}
	int intact = self->frontier - (char *)inner >= 3 * ZANE_CHUNK && self->committed > (char *)slots[N - 1];
	for (int i = 0; i < N; i++) intact = intact && slots[i][0] == i && slots[i][1] == -i;
	check(intact);

	/* Draining moves the frontier back to the scope's record, and leaves
	   what the outer scope placed untouched. */
	zane_scope_drain(inner);
	check(self->frontier == (char *)inner && self->top == outer);
	*b = 42;
	inner = zane_scope_enter(0);
	memset(test_slot(inner, 1024, 8, NULL), 0xff, 1024);
	zane_scope_drain(inner);
	check(*b == 42);

	/* An address is found in the scope whose frame holds it, however deep:
	   past the 32,768 scopes the runtime once kept at most. */
	enum { DEEP = 100000 };
	static zane_mark *records[DEEP];
	static int64_t *held[DEEP];
	nest(records, held, DEEP);
	int found = records[DEEP - 1]->depth == outer->depth + DEEP;
	for (int i = 0; i < DEEP; i += 997) found = found && zane_region_at(held[i]) == records[i] && *held[i] == i;
	found = found && zane_region_at(held[0]) == records[0] && zane_region_at(held[DEEP - 1]) == records[DEEP - 1];
	found = found && zane_region_at(b) == outer && zane_region_at(records[5]) == records[5];
	unnest(records, DEEP);
	check(found && self->top == outer);
	zane_scope_drain(outer);
}
