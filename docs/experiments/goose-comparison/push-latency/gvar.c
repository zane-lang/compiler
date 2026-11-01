#include <stdint.h>
#include <string.h>
/* A 4-byte link from base - 1, stored unaligned as the packed node has it. */
static inline void link(uint8_t *at, void *to, uint8_t *base) { uint32_t v = (uint32_t)((uint8_t *)to - (base - 1)); memcpy(at, &v, 4); }
typedef struct { uint8_t tag; uint32_t l, r; } __attribute__((packed)) T;
typedef struct { uint8_t *top; int64_t len; uint8_t *base; } S;
S G2;
/* 1: Goose's make, the stack by pointer */
T *g1(int64_t d, S *g) {
  uint8_t *top = g->top; int64_t len = g->len; uint8_t *base = g->base;
  if (d == 0) { T *t = (T *)top; t->tag = 0; g->top = top + 9; g->len = len + 1; return t; }
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { g->top = top; g->len = len; l = g1(d - 1, g); r = g1(d - 1, g); top = g->top; len = g->len; }
  T *n = (T *)top; n->tag = 1;
  link(top + 1, l, base); link(top + 5, r, base);
  top += 9; len++; g->top = top; g->len = len; return n;
}
/* 2: as 1, without the d == 0 case, the stores before the calls, and the count (len) */
T *g2(int64_t d, S *g) {
  uint8_t *top, *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { top = g->top; l = (T *)top; l->tag = 0; top += 9; r = (T *)top; r->tag = 0; top += 9; }
  else { l = g2(d - 1, g); r = g2(d - 1, g); top = g->top; }
  T *n = (T *)top; n->tag = 1;
  link(top + 1, l, base); link(top + 5, r, base);
  g->top = top + 9; return n;
}
/* 3: as 1 without the d == 0 case only */
T *g3(int64_t d, S *g) {
  uint8_t *top = g->top; int64_t len = g->len; uint8_t *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { g->top = top; g->len = len; l = g3(d - 1, g); r = g3(d - 1, g); top = g->top; len = g->len; }
  T *n = (T *)top; n->tag = 1;
  link(top + 1, l, base); link(top + 5, r, base);
  top += 9; len++; g->top = top; g->len = len; return n;
}
/* 4: as 3, without the stores before the calls */
T *g4(int64_t d, S *g) {
  uint8_t *top = g->top; int64_t len = g->len; uint8_t *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { l = g4(d - 1, g); r = g4(d - 1, g); top = g->top; len = g->len; }
  T *n = (T *)top; n->tag = 1;
  link(top + 1, l, base); link(top + 5, r, base);
  top += 9; len++; g->top = top; g->len = len; return n;
}
