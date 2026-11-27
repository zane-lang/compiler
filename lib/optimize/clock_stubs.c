/* The build machine's monotonic clock, in nanoseconds, which a `comptime`
   call reads as the running program reads its own (spec effects.md §5.6):
   the same clock `zane_monotonic_ns` reads in runtime/workers.c. */
#include <stdint.h>
#include <caml/alloc.h>
#include <caml/mlvalues.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

CAMLprim value zane_optimize_monotonic_ns(value unit) {
	(void)unit;
#ifdef _WIN32
	LARGE_INTEGER count, rate;
	QueryPerformanceFrequency(&rate);
	QueryPerformanceCounter(&count);
	int64_t ns = (int64_t)(count.QuadPart / rate.QuadPart) * 1000000000 +
	             (int64_t)(count.QuadPart % rate.QuadPart) * 1000000000 / rate.QuadPart;
#else
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	int64_t ns = (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
#endif
	return caml_copy_int64(ns);
}
