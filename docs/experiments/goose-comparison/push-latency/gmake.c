#include <stdint.h>
typedef struct { uint8_t tag; uint32_t l, r; } __attribute__((packed)) T;
struct { uint8_t *top; int64_t len; uint8_t *base; } G;
T *gmake(int64_t d) {
  uint8_t *top = G.top; int64_t len = G.len; uint8_t *base = G.base;
  if (d == 0) { T *t = (T *)top; t->tag = 0; G.top = top + 9; G.len = len + 1; return t; }
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { G.top = top; G.len = len; l = gmake(d - 1); r = gmake(d - 1); top = G.top; len = G.len; }
  T *n = (T *)top; n->tag = 1;
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  top += 9; len++; G.top = top; G.len = len; return n;
}
