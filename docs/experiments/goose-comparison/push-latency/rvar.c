#include <stdint.h>
#include <string.h>
typedef struct { uint8_t *top; int64_t len; uint8_t *base; } S;
typedef struct { uint8_t tag; uint32_t l, r; } __attribute__((packed)) T;
/* 5: the stack by pointer, handed back in a register with the node */
typedef struct { T *n; S *g; } R5;
R5 g5(int64_t d, S *g) {
  uint8_t *top, *base = g->base; T *l, *r;
  if (d - 1 == 0) { top = g->top; l = (T *)top; l->tag = 0; top += 9; r = (T *)top; r->tag = 0; top += 9; }
  else { R5 a = g5(d - 1, g); l = a.n; R5 b = g5(d - 1, a.g); r = b.n; g = b.g; top = g->top; }
  T *n = (T *)top; n->tag = 1;
  *(uint32_t *)(top + 1) = (uint32_t)((uint8_t *)l - (base - 1));
  *(uint32_t *)(top + 5) = (uint32_t)((uint8_t *)r - (base - 1));
  g->top = top + 9; return (R5){ n, g };
}
/* 6: Zane's shape with items and count passed in registers, the new count returned: no memory round trip */
typedef struct { int64_t at, count; } R6;
R6 z6(int64_t d, char *it, int64_t count) {
  int64_t l, r;
  if (d - 1 == 0) { it[count] = 0; it[count + 9] = 0; l = count; r = count + 9; count += 18; }
  else { R6 a = z6(d - 1, it, count); l = a.at; R6 b = z6(d - 1, it, a.count); r = b.at; count = b.count; }
  it[count] = 1;
  int32_t a = (int32_t)(l - (count + 1)), b = (int32_t)(r - (count + 5));
  memcpy(it + count + 1, &a, 4); memcpy(it + count + 5, &b, 4);
  return (R6){ count, count + 9 };
}
