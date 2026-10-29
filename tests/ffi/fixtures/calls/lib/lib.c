#include "lib.h"

int64_t total = 100;

int64_t helper(void) { return total + 2; }
int64_t named(void) __attribute__((alias("helper")));
