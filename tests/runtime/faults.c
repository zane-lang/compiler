/* A store into a part of a context's range that is not usable yet, tested
   in C on its own (docs/design/lowering.md L17). The store faults, the
   runtime's handler makes the step usable, and the store runs again: it
   must land where it was meant to, and nowhere else. Each check prints
   `yes` when it holds and `no` when it does not.

   tests/runtime/valgrind_test.py runs this under Valgrind too. Valgrind
   hands a fault handler only the registers its translated code last wrote
   back, so an access that runs again after the handler may use an older
   address. On x86-64 the store here is written in assembly, in the shape
   that loses its address: the register holding it is overwritten after the
   store and before any branch, so Valgrind never writes it back, and what
   it last wrote back is a decoy's address. The runtime makes a context's
   whole range usable from the start under Valgrind, so the store never
   faults there (runtime/region.c, zane_reserve). LangArena's Maze tests
   crashed, and its Graph::BFS summed wrong, before it did. */

#include "scopes.h"

static void check(int ok) { puts(ok ? "yes" : "no"); }

/* 7 stored at `target`; the register that holds `target` held `decoy`
   when the code last branched. */
static void store_seven(int *target, int *decoy) {
#if defined(__x86_64__)
	__asm__ volatile("mov %[decoy], %%rax\n\t"
	                 "test %%rax, %%rax\n\t"
	                 "jz 1f\n\t"
	                 "mov %[target], %%rax\n\t"
	                 "movl $7, (%%rax)\n\t"
	                 "xor %%eax, %%eax\n\t"
	                 "1:\n\t"
	                 :
	                 : [target] "r"(target), [decoy] "r"(decoy)
	                 : "rax", "cc", "memory");
#else
	(void)decoy;
	*(volatile int *)target = 7;
#endif
}

static int decoy;

void zane_main(void) {
	zane_context *self = zane_self;
	zane_mark *scope = zane_scope_enter(0);
	/* A slot three steps past where the scope's frame starts, untouched
	   until the store, which the frame then holds. */
	char *at = (char *)(((uintptr_t)self->frontier + 3 * (uintptr_t)ZANE_STEP) / ZANE_STEP * ZANE_STEP) + 64;
	self->frontier = at + 64;
	int *target = (int *)at;
	store_seven(target, &decoy);
	check(*target == 7);
	check(decoy == 0);
	zane_scope_drain(scope);
}
