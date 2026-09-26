/* The runtime's scope arenas, tested in C on their own (docs/lowering.md
   L17). The runtime is included whole, and this file is the program it
   calls. Each check prints `yes` when it holds and `no` when it does not;
   the runtime's own `main` then checks every scope drained. */

#include "../../runtime/zane.c"

#include <string.h>

static void check(int ok) { puts(ok ? "yes" : "no"); }

void zane_main(void) {
	/* A slot is aligned as asked, and the next one follows it. */
	int64_t outer = zane_scope_enter();
	char *a = zane_slot(outer, 1, 1, NULL);
	int64_t *b = zane_slot(outer, 8, 8, NULL);
	check((uintptr_t)b % 8 == 0 && (char *)b > a);

	/* An inner scope bumps from where the outer one stopped, and draining
	   it hands the same memory to the next scope. */
	int64_t inner = zane_scope_enter();
	char *c = zane_slot(inner, 16, 8, NULL);
	zane_scope_drain(inner);
	inner = zane_scope_enter();
	check(zane_slot(inner, 16, 8, NULL) == c);
	zane_scope_drain(inner);

	/* More than a chunk of slots in one scope takes a second chunk, and
	   every slot stays usable. */
	inner = zane_scope_enter();
	enum { N = 3 * 65536 };
	static int64_t *slots[N];
	for (int i = 0; i < N; i++) {
		slots[i] = zane_slot(inner, 16, 8, NULL);
		slots[i][0] = i;
		slots[i][1] = -i;
	}
	int intact = zane_chunks >= 3;
	for (int i = 0; i < N; i++) intact = intact && slots[i][0] == i && slots[i][1] == -i;
	check(intact);

	/* Draining gives the chunks back to the next scope, and leaves what the
	   outer scope placed untouched. */
	uint32_t used = zane_chunks;
	zane_scope_drain(inner);
	check(zane_chunks < used);
	*b = 42;
	inner = zane_scope_enter();
	memset(zane_slot(inner, 1024, 8, NULL), 0xff, 1024);
	zane_scope_drain(inner);
	check(*b == 42);
	zane_scope_drain(outer);
}
