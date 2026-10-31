#include <immintrin.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static void movsb(char *d, const char *s, size_t n) { __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory"); }

static void avx(char *d, const char *s, size_t n) {
	size_t i = 0;
	for (; i + 32 <= n; i += 32) _mm256_storeu_si256((__m256i *)(d + i), _mm256_loadu_si256((const __m256i *)(s + i)));
	for (; i < n; i++) d[i] = s[i];
}

int main(int argc, char **argv) {
	size_t n = argc > 1 ? strtoul(argv[1], 0, 10) : 60000;
	int reps = 25000;
	size_t shifts[] = { 32, 64, 128, 4096 };
	char *buf = aligned_alloc(64, n + 8192);
	memset(buf, 1, n + 8192);
	const char *names[] = { "glibc memmove", "rep movsb", "avx2 loop" };
	for (int k = 0; k < 4; k++)
		for (int m = 0; m < 3; m++) {
			size_t sh = shifts[k];
			double t = now();
			for (int r = 0; r < reps; r++) {
				char *d = buf + 64, *s = buf + 64 + sh;
				if (m == 0) memmove(d, s, n);
				else if (m == 1) movsb(d, s, n);
				else avx(d, s, n);
				__asm__ volatile("" : : "r"(buf) : "memory");
			}
			t = now() - t;
			printf("shift %5zu  %-14s %6.2f GB/s\n", sh, names[m], (double)n * reps / t / 1e9);
		}
	return 0;
}
