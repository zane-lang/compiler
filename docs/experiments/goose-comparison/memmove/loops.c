#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef char b16 __attribute__((vector_size(16), aligned(1), may_alias));

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

__attribute__((noinline, no_builtin)) static void one(char *to, const char *from, int64_t n) {
#pragma clang loop unroll(disable)
	for (int64_t i = 0; i + 16 <= n; i += 16) *(b16 *)(to + i) = *(const b16 *)(from + i);
}

__attribute__((noinline, no_builtin)) static void four(char *to, const char *from, int64_t n) {
	int64_t i = 0;
	for (; i + 64 <= n; i += 64) {
		b16 a = *(const b16 *)(from + i), b = *(const b16 *)(from + i + 16);
		b16 c = *(const b16 *)(from + i + 32), d = *(const b16 *)(from + i + 48);
		*(b16 *)(to + i) = a;
		*(b16 *)(to + i + 16) = b;
		*(b16 *)(to + i + 32) = c;
		*(b16 *)(to + i + 48) = d;
	}
	for (; i + 16 <= n; i += 16) *(b16 *)(to + i) = *(const b16 *)(from + i);
}

__attribute__((noinline, no_builtin)) static void helper(char *to, const char *from, int64_t n) {
	int64_t i = 0;
	for (; i + 16 <= n; i += 16) *(b16 *)(to + i) = *(const b16 *)(from + i);
	for (; i < n; i++) to[i] = from[i];
}

__attribute__((noinline)) static void chunks(char *to, const char *from, int64_t n) {
	for (int64_t i = 0; i < n; i += 2048) memmove(to + i, from + i, (size_t)(n - i < 2048 ? n - i : 2048));
}

__attribute__((noinline)) static void whole(char *to, const char *from, int64_t n) { memmove(to, from, (size_t)n); }

int main(void) {
	int64_t n = 60000;
	int reps = 25000;
	char *buf = aligned_alloc(64, n + 8192);
	memset(buf, 1, n + 8192);
	void (*fs[])(char *, const char *, int64_t) = { one, four, helper, chunks, whole };
	const char *names[] = { "16B, not unrolled", "4x16B, loads first", "runtime helper", "memmove, 2 KB chunks", "memmove, whole" };
	for (int sh = 8; sh <= 128; sh *= 2)
		for (int m = 0; m < 5; m++) {
			double t = now();
			for (int r = 0; r < reps; r++) {
				fs[m](buf + 64, buf + 64 + sh, n);
				__asm__ volatile("" : : "r"(buf) : "memory");
			}
			t = now() - t;
			printf("shift %2d  %-20s %6.2f GB/s\n", sh, names[m], (double)n * reps / t / 1e9);
		}
	return 0;
}
