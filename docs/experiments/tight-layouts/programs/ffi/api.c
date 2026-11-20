#include "api.h"

#define OPAQUE(x) __asm__ volatile("" : "+r"(x))

__attribute__((noinline)) vec3 vec_step(vec3 v) {
  double x = v.x; OPAQUE(x);
  return (vec3){ v.y, v.z, x + 1 };
}
__attribute__((noinline)) tagged tag_step(tagged t) {
  int32_t tag = t.tag; OPAQUE(tag);
  return (tagged){ (tag + 1) & 7, t.n + tag };
}
__attribute__((noinline)) nested nest_step(nested n) {
  int32_t first = n.first; OPAQUE(first);
  return (nested){ (first + 1) & 7, { n.inner.tag ^ 1, n.inner.n + first }, n.last };
}
__attribute__((noinline)) ordered ord_step(ordered o) {
  int32_t tag = o.tag; OPAQUE(tag);
  return (ordered){ o.n + tag, (tag + 1) & 7 };
}
