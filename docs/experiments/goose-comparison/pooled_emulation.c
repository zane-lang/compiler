// The pooled binarytrees in plain C, to tell what the code's shape costs
// from what Zane's code generation adds (README.md, "Pooled variants"). The
// tree is built in one pool with relative 4-byte links, as Zane's pooled
// variants are; the macros switch between Zane's shape and Goose's:
//
//   NODE=16, TAG=int32_t   Zane's node: a 4-byte tag padded to 8, two links
//   NODE=9,  TAG=uint8_t   Goose's packed node: a 1-byte tag, two links
//   INLINE_LEAF=1          a depth-0 child built in its parent, no call
//
//   clang -O2 [-DNODE=9 -DTAG=uint8_t] [-DINLINE_LEAF=1] -o emu pooled_emulation.c
//   ./emu 16
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#ifndef NODE
#define NODE 16
#endif
#ifndef TAG
#define TAG int32_t
#endif
#define L0 (NODE == 9 ? 1 : 8)
typedef struct { char *items; int64_t count, room; } pool;
__attribute__((noinline)) static void grow(pool *p, int64_t need) {
	int64_t r = p->room * 2; if (r < need) r = need;
	p->items = realloc(p->items, r); p->room = r;
}
static inline int64_t leaf(pool *p) {
	int64_t at = p->count; if (at + NODE > p->room) grow(p, at + NODE);
	*(TAG *)(p->items + at) = 0; p->count = at + NODE; return at;
}
static int64_t make(int64_t d, pool *p) {
	if (d == 0) return leaf(p);
#if INLINE_LEAF
	int64_t l = d == 1 ? leaf(p) : make(d - 1, p), r = d == 1 ? leaf(p) : make(d - 1, p);
#else
	int64_t l = make(d - 1, p), r = make(d - 1, p);
#endif
	int64_t at = p->count; if (at + NODE > p->room) grow(p, at + NODE);
	char *m = p->items + at;
	int32_t a = (int32_t)(l - (at + L0)), b = (int32_t)(r - (at + L0 + 4));
	*(TAG *)m = 1; memcpy(m + L0, &a, 4); memcpy(m + L0 + 4, &b, 4);
	p->count = at + NODE; return at;
}
static int64_t check(const char *n) {
	if (*(const TAG *)n == 0) return 1;
	int32_t a, b; memcpy(&a, n + L0, 4); memcpy(&b, n + L0 + 4, 4);
	return 1 + check(n + L0 + a) + check(n + L0 + 4 + b);
}
static int64_t tree(int64_t d, pool *s) { s->count = 0; int64_t at = make(d, s); return check(s->items + at); }
int main(int argc, char **argv) {
	int n = atoi(argv[1]);
	pool s = { malloc(128), 0, 128 };
	printf("stretch %ld\n", (long)tree(n + 1, &s));
	pool lp = { malloc(128), 0, 128 }; int64_t la = make(n, &lp);
	for (int d = 4; d <= n; d += 2) {
		int64_t it = 1L << (n - d + 4), t = 0;
		for (int64_t i = 0; i < it; i++) t += tree(d, &s);
		printf("%ld %d %ld\n", (long)it, d, (long)t);
	}
	printf("long %ld\n", (long)check(lp.items + la));
}
