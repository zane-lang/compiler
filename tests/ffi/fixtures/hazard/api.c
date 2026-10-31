#include "api.h"

static int64_t count;

int64_t zane_counter_next(void) { return ++count; }
