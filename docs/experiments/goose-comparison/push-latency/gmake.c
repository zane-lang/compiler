#include <string.h>
#include <stdint.h>
/* A 4-byte link from base - 1, stored unaligned as the packed node has it. */
static inline void link(uint8_t *at, void *to, uint8_t *base) { uint32_t v = (uint32_t)((uint8_t *)to - (base - 1)); memcpy(at, &v, 4); }
typedef struct { uint8_t tag; uint32_t l, r; } __attribute__((packed)) T;
struct { uint8_t *top; int64_t len; uint8_t *base; } G;
T *gmake(int64_t d) {
  uint8_t *top = G.top; int64_t len = G.len; uint8_t *base = G.base;
  if (d == 0) { T *t = (T *)top; t->tag = 0; G.top = top + 9; G.len = len + 1; return t; }
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { G.top = top; G.len = len; l = gmake(d - 1); r = gmake(d - 1); top = G.top; len = G.len; }
  T *n = (T *)top; n->tag = 1;
  link(top + 1, l, base); link(top + 5, r, base);
  top += 9; len++; G.top = top; G.len = len; return n;
}
