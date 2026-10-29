#include <stdint.h>
#include <string.h>
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
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  top += 9; len++; g->top = top; g->len = len; return n;
}
/* 2: as 1, without the d == 0 case and the stores before the calls */
T *g2(int64_t d, S *g) {
  uint8_t *top, *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { top = g->top; l = (T *)top; l->tag = 0; top += 9; r = (T *)top; r->tag = 0; top += 9; }
  else { l = g2(d - 1, g); r = g2(d - 1, g); top = g->top; }
  T *n = (T *)top; n->tag = 1;
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  g->top = top + 9; return n;
}
/* 3: as 1 without the d == 0 case only */
T *g3(int64_t d, S *g) {
  uint8_t *top = g->top; int64_t len = g->len; uint8_t *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { g->top = top; g->len = len; l = g3(d - 1, g); r = g3(d - 1, g); top = g->top; len = g->len; }
  T *n = (T *)top; n->tag = 1;
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  top += 9; len++; g->top = top; g->len = len; return n;
}
/* 4: as 3, without the stores before the calls */
T *g4(int64_t d, S *g) {
  uint8_t *top = g->top; int64_t len = g->len; uint8_t *base = g->base;
  T *l, *r;
  if (d - 1 == 0) { l = (T *)top; l->tag = 0; top += 9; len++; r = (T *)top; r->tag = 0; top += 9; len++; }
  else { l = g4(d - 1, g); r = g4(d - 1, g); top = g->top; len = g->len; }
  T *n = (T *)top; n->tag = 1;
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  top += 9; len++; g->top = top; g->len = len; return n;
}
