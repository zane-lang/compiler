#include "scale.h"
#ifdef ZANE_NEVER
#error "a row for another target applied"
#endif
int64_t scale(int64_t x) { return x * ZANE_SCALE; }
