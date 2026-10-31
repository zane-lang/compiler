#include <stdint.h>

/* Private state an external function bumps and an inline function reads.
   The archive's member, optimized, splits its copy into one variable per
   field, `state.0` and `state.1`. */
static struct {
  int64_t x;
  int64_t y;
} state;
int64_t bump(void) {
  state.x++;
  state.y++;
  return state.x + state.y;
}
static inline int64_t sum(void) { return state.x + state.y; }
