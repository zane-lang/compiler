#include "api.h"

struct clock_t_ { int64_t ticks; };

clock_t_ zane_clock = { 42 };

int64_t clock_now(const clock_t_ *c) { return c->ticks; }
