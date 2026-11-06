/* Package constants that wait for each other across contexts, tested in C
   on their own (docs/design/lowering.md L16): a cycle of waits stops the
   program with its message instead of hanging. Each case runs in a child
   (system.h), which is stopped if it hangs, and prints `yes` when the child
   stopped with the message and status 1. */

#include "system.h"
#include "walks.h"

static void check(int ok) { puts(ok ? "yes" : "no"); }

static int64_t first, second;
static int arrived;

/* Both sides wait here until each has begun its own constant. */
static void meet(void) {
	__atomic_fetch_add(&arrived, 1, __ATOMIC_ACQ_REL);
	while (__atomic_load_n(&arrived, __ATOMIC_ACQUIRE) < 2) sched_yield();
}

/* A spawned call that makes `second` and reads `first` while it does. */
static void crosses(char *frame) {
	(void)frame;
	zane_constant_begin(&second);
	meet();
	zane_constant_begin(&first);
}

/* A spawned call that reads `first`. */
static void reads(char *frame) {
	(void)frame;
	zane_constant_begin(&first);
}

typedef struct {
	zane_task header;
	int64_t result;
} spawned;

/* Two contexts, each making its own constant and then reading the other's. */
static void across(void) {
	zane_constant_begin(&first);
	spawned s = { 0 };
	zane_spawn((char *)&s.result, crosses, NULL, NULL, 0);
	meet();
	zane_constant_begin(&second);
}

/* The program's context makes `first`, and joins a call that reads it: run
   here when `taken` is 0, and otherwise joined the moment a pool thread has
   taken it, before it may have its own context. */
static void through_join(int taken) {
	zane_constant_begin(&first);
	spawned s = { 0 };
	zane_spawn((char *)&s.result, reads, NULL, NULL, 0);
	if (taken)
		while (zane_state(&s.header) == ZANE_QUEUED) {}
	zane_join((char *)&s.result);
}

static const char *const cycle = "package constants read each other while they are made\n";

void zane_main(void) {
	if (child_case("across") || child_case("join")) {
		zane_set_threads(2);
		if (child_case("across")) across();
		else through_join(strcmp(child_arg(), "1") == 0);
		exit(2);
	}
	check(child_stops("across", "", CHILD_NULL, TEST_NO_FD, 1, cycle));
	check(child_stops("join", "0", CHILD_NULL, TEST_NO_FD, 1, cycle));
	/* The window between a pool thread taking the call and giving it its
	   context is short, so it is tried many times. */
	int all = 1;
	for (int i = 0; i < 50; i++) all &= child_stops("join", "1", CHILD_NULL, TEST_NO_FD, 1, cycle);
	check(all);
}
