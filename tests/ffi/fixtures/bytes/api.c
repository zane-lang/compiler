#include "api.h"

uint8_t next_byte(uint8_t b) { return (uint8_t)(b + 1); }
unsigned char flip_bits(unsigned char b) { return (unsigned char)~b; }
signed char negate(signed char b) { return (signed char)-b; }
char upper(char c) { return c >= 'a' && c <= 'z' ? (char)(c - 32) : c; }
int8_t echo(int8_t b) { return b; }

int64_t byte_sum(const uint8_t *xs, zane_span ys) {
  int64_t s = xs[0] + xs[1] + xs[2] + xs[3];
  const uint8_t *p = ys.data;
  for (size_t i = 0; i < ys.count; i++) s += p[i];
  return s;
}

packet swap(packet p) { return (packet){ p.low, p.n * 2, p.tag }; }
uint8_t apply(uint8_t (*f)(uint8_t), uint8_t b) { return f(f(b)); }
packet remake(packet (*f)(packet), packet p) { return f(p); }
