#include <stdint.h>

/* Private state an external function bumps and an inline function reads,
   compiled into a member whose local symbols are stripped. */
static volatile int64_t state;
int64_t bump(void) { return ++state; }
static inline int64_t current(void) { return state; }
