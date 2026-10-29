// The pooled binarytrees in plain C, to tell what the code's shape costs
// from what Zane's code generation adds (README.md, "Pooled variants"). The
// tree is built in one pool with relative 4-byte links, as Zane's pooled
// variants are; the macros switch between Zane's shape and Goose's:
//
//   NODE=16, TAG=int32_t   Zane's node: a 4-byte tag padded to 8, two links
//   NODE=9,  TAG=uint8_t   Goose's packed node: a 1-byte tag, two links
//   INLINE_LEAF=1          a depth-0 child built in its parent, no call
//   NO_CHECK=1             no room check on a push: the pool is reserved
//                          once at the largest size it reaches, as on a
//                          data stack
//   CHECK_LOOP=1           `check` walks each right child in a loop and
//                          calls only for the left, as Goose's compiles to
//   FRESH=64               each tree in a pool of its own from malloc, 64
//                          bytes at first and doubling with realloc
//   MAP=1                  the pools mapped writable with mmap, OFFSET bytes
//                          into their first page (default 16)
//   MAP=2                  the pools reserved inaccessible and made writable
//                          with mprotect, as Zane's runtime commits memory
//   ON_RETURN=1            no room check on a push; instead `make` leaves
//                          room for three nodes when it returns, the most
//                          one call pushes before it calls or returns
//
//   clang -O2 [-DNODE=9 -DTAG=uint8_t] [-DINLINE_LEAF=1] -o emu pooled_emulation.c
//   ./emu 16
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#ifndef MAP
#define MAP 0
#endif
#ifndef OFFSET
#define OFFSET 16
#endif
static char *mapped(size_t n) {
	n += 4096;
	char *p = mmap(NULL, n, MAP == 2 ? PROT_NONE : PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (p == MAP_FAILED || (MAP == 2 && mprotect(p, n, PROT_READ | PROT_WRITE))) abort();
	return p + OFFSET;
}
#ifndef NODE
#define NODE 16
#endif
#ifndef TAG
#define TAG int32_t
#endif
#define L0 (NODE == 9 ? 1 : 8)
#ifndef NO_CHECK
#define NO_CHECK 0
#endif
#if NO_CHECK
#define ROOM(p, need)
#else
#define ROOM(p, need) if ((need) > (p)->room) grow(p, need)
#endif
#ifndef ON_RETURN
#define ON_RETURN 0
#endif
#if ON_RETURN
#define PUSH(p, need)
#define LEAVE(p) ROOM(p, (p)->count + 3 * NODE)
#else
#define PUSH(p, need) ROOM(p, need)
#define LEAVE(p)
#endif
typedef struct { char *items; int64_t count, room; } pool;
__attribute__((noinline)) static void grow(pool *p, int64_t need) {
	int64_t r = p->room * 2; if (r < need) r = need;
	p->items = realloc(p->items, r); p->room = r;
}
static inline int64_t leaf(pool *p) {
	int64_t at = p->count; PUSH(p, at + NODE);
	*(TAG *)(p->items + at) = 0; p->count = at + NODE; return at;
}
static int64_t make(int64_t d, pool *p) {
	if (d == 0) { int64_t at = leaf(p); LEAVE(p); return at; }
#if INLINE_LEAF
	int64_t l = d == 1 ? leaf(p) : make(d - 1, p), r = d == 1 ? leaf(p) : make(d - 1, p);
#else
	int64_t l = make(d - 1, p), r = make(d - 1, p);
#endif
	int64_t at = p->count; PUSH(p, at + NODE);
	char *m = p->items + at;
	int32_t a = (int32_t)(l - (at + L0)), b = (int32_t)(r - (at + L0 + 4));
	*(TAG *)m = 1; memcpy(m + L0, &a, 4); memcpy(m + L0 + 4, &b, 4);
	p->count = at + NODE; LEAVE(p); return at;
}
#ifndef CHECK_LOOP
#define CHECK_LOOP 0
#endif
static int64_t check(const char *n) {
#if CHECK_LOOP
	int64_t total = 0;
	while (*(const TAG *)n != 0) {
		int32_t a, b; memcpy(&a, n + L0, 4); memcpy(&b, n + L0 + 4, 4);
		total += 1 + check(n + L0 + a);
		n = n + L0 + 4 + b;
	}
	return total + 1;
#else
	if (*(const TAG *)n == 0) return 1;
	int32_t a, b; memcpy(&a, n + L0, 4); memcpy(&b, n + L0 + 4, 4);
	return 1 + check(n + L0 + a) + check(n + L0 + 4 + b);
#endif
}
#ifndef FRESH
#define FRESH 0
#endif
static int64_t tree(int64_t d, pool *s) {
#if FRESH
	pool f = { malloc(FRESH), 0, FRESH }; int64_t at = make(d, &f), n = check(f.items + at); free(f.items); (void)s; return n;
#else
	s->count = 0; int64_t at = make(d, s); return check(s->items + at);
#endif
}
int main(int argc, char **argv) {
	int n = atoi(argv[1]);
	int64_t big = (NO_CHECK | MAP) ? ((int64_t)2 << (n + 2)) * NODE : 128;
	pool s = { MAP ? mapped(big) : malloc(big), 0, big };
	printf("stretch %ld\n", (long)tree(n + 1, &s));
	pool lp = { MAP ? mapped(big) : malloc(big), 0, big }; int64_t la = make(n, &lp);
	for (int d = 4; d <= n; d += 2) {
		int64_t it = 1L << (n - d + 4), t = 0;
		for (int64_t i = 0; i < it; i++) t += tree(d, &s);
		printf("%ld %d %ld\n", (long)it, d, (long)t);
	}
	printf("long %ld\n", (long)check(lp.items + la));
}
