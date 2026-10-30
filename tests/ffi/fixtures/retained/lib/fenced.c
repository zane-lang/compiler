/* A source holding assembly, assembled as an object of its own, which a
   retained thunk reaches by the name that object defines. */

#include "lib.h"

int64_t fenced(int64_t x) {
  __asm__ volatile("" : "+r"(x));
  return x + 1;
}
