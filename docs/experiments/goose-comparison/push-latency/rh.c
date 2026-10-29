#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
typedef struct { uint8_t *top; int64_t len; uint8_t *base; } S;
typedef struct { void *n; S *g; } R5; typedef struct { int64_t at, count; } R6;
extern S G; void *gmake(int64_t); void *g1(int64_t, S *);
R5 g5(int64_t, S *); R6 z6(int64_t, char *, int64_t);
typedef struct { char *items; int64_t count, room; } pool; int64_t zmake(int64_t, pool *);
int main(int argc, char **argv) {
  int which = atoi(argv[1]), depth = atoi(argv[2]); long iters = atol(argv[3]);
  char *mem = mmap(0, 1<<30, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  static S s; static pool p; long sum = 0;
  uint64_t t0 = __builtin_readcyclecounter();
  for (long i = 0; i < iters; i++) {
    G.base = G.top = s.base = s.top = (uint8_t *)mem + 64; G.len = s.len = 0; p.items = mem + 64; p.count = 0;
    long r = which == 0 ? (long)((char *)gmake(depth) - mem) : which == 1 ? (long)((char *)g1(depth, &s) - mem)
           : which == 5 ? (long)((char *)g5(depth, &s).n - mem) : which == 6 ? z6(depth, mem + 64, 0).at : zmake(depth, &p);
    sum += r;
  }
  uint64_t t1 = __builtin_readcyclecounter();
  const char *n[] = { "goose (global)", "goose, by pointer", "", "", "", "pointer handed back", "count in registers", "zane IR" };
  printf("%-20s %.2f cycles/node (%ld)\n", n[which], (double)(t1-t0)/iters/((2L<<depth)-1+0.0), sum);
}
