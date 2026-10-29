// binarytrees in the shape Goose compiles it to (implementation notes §6.7,
// §6.10; spec §1.3 and C.1): nodes pushed at a data stack's top, a global
// pointer kept in a register through each frame and stored once; no
// capacity check, since the stack is a reservation larger than any tree;
// 9-byte nodes, leaves built in their parent. SELF=1 makes links
// self-relative, as Zane's are; otherwise they count from the pool's base,
// as Goose's `in pool` links do.
//
//   clang -O2 [-DSELF=1] -o goose_shape goose_shape.c && ./goose_shape 16
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#ifndef SELF
#define SELF 0
#endif
static char *top, *base;
static int64_t make(int64_t d) {
	char *t = top;
	if (d == 0) { *t = 0; top = t + 9; return t - base; }
	int64_t l, r;
	if (d == 1) { t[0] = 0; t[9] = 0; l = t - base; r = l + 9; t += 18; }
	else { l = make(d - 1); r = make(d - 1); t = top; }
	int64_t at = t - base;
#if SELF
	int32_t a = (int32_t)(l - (at + 1)), b = (int32_t)(r - (at + 5));
#else
	int32_t a = (int32_t)l, b = (int32_t)r;
#endif
	t[0] = 1; memcpy(t + 1, &a, 4); memcpy(t + 5, &b, 4);
	top = t + 9; return at;
}
static int64_t check(const char *n) {
	if (*n == 0) return 1;
	int32_t a, b; memcpy(&a, n + 1, 4); memcpy(&b, n + 5, 4);
#if SELF
	return 1 + check(n + 1 + a) + check(n + 5 + b);
#else
	return 1 + check(base + a) + check(base + b);
#endif
}
static int64_t tree(int64_t d) { top = base; int64_t at = make(d); return check(base + at); }
int main(int argc, char **argv) {
	int n = atoi(argv[1]);
	base = mmap(NULL, (size_t)1 << 31, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	char *lbase = mmap(NULL, (size_t)1 << 31, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	printf("stretch %ld\n", (long)tree(n + 1));
	char *sb = base; base = lbase; top = lbase; int64_t la = make(n); base = sb;
	for (int d = 4; d <= n; d += 2) {
		int64_t it = 1L << (n - d + 4), t = 0;
		for (int64_t i = 0; i < it; i++) t += tree(d);
		printf("%ld %d %ld\n", (long)it, d, (long)t);
	}
	sb = base; base = lbase; printf("long %ld\n", (long)check(lbase + la)); base = sb;
}
