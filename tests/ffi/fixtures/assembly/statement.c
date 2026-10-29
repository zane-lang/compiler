#include "api.h"

void barrier(void) { __asm__ volatile("" ::: "memory"); }

long long fenced(long long x) {
  barrier();
  __asm__ volatile("" : "+r"(x));
  return x + 1;
}
