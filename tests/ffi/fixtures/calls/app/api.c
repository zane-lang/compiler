#include "api.h"

#include <string.h>

static int64_t count;
int64_t total;

int64_t twice(int64_t x) { count++; return 2 * x; }
int16_t narrow(uint8_t byte, short half) { return (int16_t)(byte + half); }
float halve(float x) { return x / 2; }
bool odd(int n) { return n & 1; }
int32_t from_bool(bool b) { return b ? 1 : 0; }

double sum(const double *xs, zane_span ys) {
  double s = xs[0] + xs[1] + xs[2] + xs[3];
  const int64_t *p = ys.data;
  for (size_t i = 0; i < ys.count; i++) s += (double)p[i];
  return s;
}

zane_bytes greet(zane_bytes who) {
  static uint8_t buf[64];
  memcpy(buf, "hello, ", 7);
  memcpy(buf + 7, who.data, who.size);
  return (zane_bytes){ buf, 7 + who.size };
}

int64_t length(zane_bytes text) { return (int64_t)text.size; }
vec3 vec_add(vec3 a, vec3 b) { return (vec3){ a.x + b.x, a.y + b.y, a.z + b.z }; }

pair pair_mirror(pair p) {
  pair q = p;
  q.id = -p.id;
  q.weights[0] = p.weights[2];
  q.weights[2] = p.weights[0];
  q.at = (vec3){ -p.at.x, -p.at.y, -p.at.z };
  return q;
}

tagged flip(tagged t) { return (tagged){ -t.tag, t.n + 1 }; }
void add_to(int64_t n) { total += n; count++; }
void reset(void) { count = 0; total = 0; }
int64_t counter(void) { return count + total; }
int64_t helper(void) { return 1; }
int64_t named(void) __attribute__((alias("helper")));
