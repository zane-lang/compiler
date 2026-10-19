/* Package constants that wait for each other across contexts, tested in C
   on their own (docs/design/lowering.md L16): a cycle of waits stops the
   program with its message instead of hanging. Each case runs in a child,
   which an alarm stops if it hangs, and prints `yes` when the child stopped
   with the message and status 1. */

#include "walks.h"

#include <sys/wait.h>

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

/* Whether `run` in a child stops it with the cycle's message within ten
   seconds. */
static int stops(void (*run)(int), int arg) {
	int output[2];
	if (pipe(output) != 0) return 0;
	fflush(stdout);
	pid_t child = fork();
	if (child == 0) {
		close(output[0]);
		if (dup2(output[1], STDERR_FILENO) < 0) _exit(2);
		close(output[1]);
		alarm(10);
		zane_set_threads(2);
		run(arg);
		_exit(2);
	}
	close(output[1]);
	char text[128];
	size_t used = 0;
	ssize_t n;
	while (used < sizeof text - 1 && (n = read(output[0], text + used, sizeof text - 1 - used)) > 0)
		used += (size_t)n;
	text[used] = 0;
	close(output[0]);
	int status;
	return child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status) &&
	       WEXITSTATUS(status) == 1 &&
	       strcmp(text, "package constants read each other while they are made\n") == 0;
}

static void across_case(int arg) {
	(void)arg;
	across();
}

void zane_main(void) {
	check(stops(across_case, 0));
	check(stops(through_join, 0));
	/* The window between a pool thread taking the call and giving it its
	   context is short, so it is tried many times. */
	int all = 1;
	for (int i = 0; i < 50; i++) all &= stops(through_join, 1);
	check(all);
}
