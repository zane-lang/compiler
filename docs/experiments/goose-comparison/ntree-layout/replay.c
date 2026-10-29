#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
/* ntree's tree in several layouts, built and counted from one bump region,
   in cycles (least of `runs` runs of 10 rounds each):
   0 Zane's: each node a 24-byte list handle {items, count, room} in its
     parent's block of four, the block taken at the first push, after the
     first child's subtree;
   1 the same with the block taken before the children;
   2 Zane's shape with an 8-byte handle {4-byte self-relative link, count};
   5 Zane's shape with a 16-byte handle {items, count}, the room implied;
   3 Goose's: 17-byte nodes in pre-order, the children as 4-byte
     self-relative links inside the node;
   4 Goose's, each node padded to 24 bytes. */
static char *bump;
static void *take(size_t n) { void *p = bump; bump += n; return p; }

typedef struct { char *items; int64_t count, room; } handle;
static handle zgrow(int d, int early) {
  handle h = { 0, 0, 0 };
  if (d > 0) {
    if (early) { h.items = take(96); h.room = 96; }
    for (int k = 0; k < 4; k++) {
      handle c = zgrow(d - 1, early);
      if (!h.items) { h.items = take(96); h.room = 96; }
      memcpy(h.items + h.count * 24, &c, 24); h.count++;
    }
  }
  return h;
}
static long zcount(handle *h) {
  long t = 1;
  for (int k = 0; k < h->count; k++) t += zcount((handle *)(h->items + k * 24));
  return t;
}

typedef struct { char *items; int64_t count; } pair;
static pair pgrow(int d) {
  pair h = { 0, 0 };
  if (d > 0)
    for (int k = 0; k < 4; k++) {
      pair c = pgrow(d - 1);
      if (!h.items) h.items = take(64);
      memcpy(h.items + h.count * 16, &c, 16); h.count++;
    }
  return h;
}
static long pcount(pair *h) {
  long t = 1;
  for (int k = 0; k < h->count; k++) t += pcount((pair *)(h->items + k * 16));
  return t;
}

typedef struct { int32_t link, count; } small;
static void sgrow(small *at, int d) {
  at->link = 0; at->count = 0;
  if (d > 0) {
    small *block = take(4 * sizeof(small));
    for (int k = 0; k < 4; k++) sgrow(&block[k], d - 1);
    at->link = (int32_t)((char *)block - (char *)at); at->count = 4;
  }
}
static long scount(small *s) {
  long t = 1;
  small *block = (small *)((char *)s + s->link);
  for (int k = 0; k < s->count; k++) t += scount(&block[k]);
  return t;
}

static int gsize;
typedef struct __attribute__((packed)) { uint8_t len; int32_t e[4]; } gnode;
static gnode *ggrow(int d) {
  gnode *n = take(gsize); n->len = 0;
  if (d > 0)
    for (int k = 0; k < 4; k++) {
      gnode *c = ggrow(d - 1);
      n->e[n->len] = (int32_t)((char *)c - (char *)&n->e[n->len]); n->len++;
    }
  return n;
}
static long gcount(gnode *n) {
  long t = 1;
  for (int k = 0; k < n->len; k++) t += gcount((gnode *)((char *)&n->e[k] + n->e[k]));
  return t;
}

int main(int argc, char **argv) {
  int form = atoi(argv[1]), depth = argc > 2 ? atoi(argv[2]) : 10, runs = argc > 3 ? atoi(argv[3]) : 7;
  gsize = form == 4 ? 24 : 17;
  char *mem = mmap(0, 1L << 30, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  uint64_t best_grow = ~0ull, best_count = ~0ull; long total = 0;
  for (int run = 0; run < runs; run++) {
    uint64_t grow = 0, count = 0;
    for (int round = 0; round < 10; round++) {
      bump = mem;
      uint64_t a = __builtin_readcyclecounter();
      handle h; gnode *g = 0; small *s = 0; pair p;
      if (form == 5) p = pgrow(depth);
      else if (form >= 3) g = ggrow(depth);
      else if (form == 2) { s = take(sizeof(small)); sgrow(s, depth); }
      else h = zgrow(depth, form == 1);
      uint64_t b = __builtin_readcyclecounter();
      total += form == 5 ? pcount(&p) : form >= 3 ? gcount(g) : form == 2 ? scount(s) : zcount(&h);
      count += __builtin_readcyclecounter() - b; grow += b - a;
    }
    if (grow < best_grow) best_grow = grow;
    if (count < best_count) best_count = count;
  }
  const char *name[] = { "zane", "zane, block first", "zane, 8-byte handle", "goose", "goose, 24-byte node", "zane, 16-byte handle" };
  printf("%-20s grow %4.0fM  count %4.0fM cycles  %5.1f MB/round  (%ld)\n", name[form], best_grow / 1e6,
         best_count / 1e6, (bump - mem) / 1048576.0, total / runs);
}
