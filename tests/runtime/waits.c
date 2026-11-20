/* A waiting call holds back only its caller (concurrency.md §3.4), tested
   in C on its own: the timer a `register` waits on (zane_tick), and the
   stand-in thread the pool starts for a pool thread while that thread
   waits. The pool in this process has one thread from its start. Each check prints `yes` when it
   holds and `no` when it does not. */

#include "walks.h"

#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

static int64_t test_now(void) {
#ifdef _WIN32
	LARGE_INTEGER count, rate;
	QueryPerformanceCounter(&count);
	QueryPerformanceFrequency(&rate);
	return (int64_t)((double)count.QuadPart * 1e9 / (double)rate.QuadPart);
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
#endif
}

static void check(int ok) { puts(ok ? "yes" : "no"); }

static const int64_t MS = 1000000, S = 1000000000;

static int64_t started, set, done, saw;

/* A spawned `register` on a 1 ms timer, which runs until the flag is set or
   two seconds have passed. */
static void waiter(char *frame) {
	(void)frame;
	__atomic_store_n(&started, 1, __ATOMIC_RELEASE);
	int64_t deadline = zane_tick_start(MS);
	for (int i = 0; i < 2000 && !__atomic_load_n(&set, __ATOMIC_ACQUIRE); i++) deadline = zane_tick(MS, deadline);
	__atomic_store_n(&saw, __atomic_load_n(&set, __ATOMIC_ACQUIRE), __ATOMIC_RELEASE);
	__atomic_store_n(&done, 1, __ATOMIC_RELEASE);
}

static void setter(char *frame) {
	(void)frame;
	__atomic_store_n(&set, 1, __ATOMIC_RELEASE);
}

void zane_main(void) {
	/* An interval below 1 is always ready: no first deadline, no wait. */
	check(zane_tick_start(0) == 0 && zane_tick_start(-5) == 0);
	check(zane_tick(0, 7) == 7);

	/* The wait lasts until the deadline, and the next deadline is one
	   interval on. */
	int64_t first = zane_tick_start(3 * MS);
	int64_t next = zane_tick(3 * MS, first);
	int64_t after = test_now();
	check(after >= first && next > first && (next - first) % (3 * MS) == 0);

	/* A deadline already past waits not at all, and missed ticks merge: the
	   next deadline is the first after now. The deadline is 21 s past on a
	   10 s timer, so a wait for any deadline would last about 9 s. The
	   check fails on a correct runtime only if the system keeps this thread
	   from running for a whole second. */
	int64_t late = zane_tick_start(10 * S) - 31 * S;
	int64_t before = test_now();
	next = zane_tick(10 * S, late);
	check(test_now() - before < S && next > before && (next - late) % (10 * S) == 0);

	/* A deadline past the largest time an int64_t holds becomes that time,
	   both as the first deadline and as the one after a tick. The tick's
	   own deadline here is already past, so it waits not at all. */
	check(zane_tick_start(INT64_MAX) == INT64_MAX);
	check(zane_tick(INT64_MAX, 1) == INT64_MAX);

	/* With one thread, a call spawned while the first waits still runs: the
	   waiting thread has a stand-in. Nothing here joins either call before
	   the waiter is done, so this thread runs neither. */
	check(zane_set_threads(1) == 1);
	zane_mark *scope = zane_scope_enter(0);
	char *w = test_frame(scope, 8), *s = test_frame(scope, 8);
	zane_spawn(w, waiter, NULL, NULL, 0);
	while (!__atomic_load_n(&started, __ATOMIC_ACQUIRE)) zane_sleep(MS / 10);
	zane_spawn(s, setter, NULL, NULL, 0);
	while (!__atomic_load_n(&done, __ATOMIC_ACQUIRE)) zane_sleep(MS / 10);
	zane_scope_drain(scope);
	check(saw == 1);
}
