#include <zane_ffi.h>

static int64_t primed_value;
__attribute__((constructor)) static void prime(void) { primed_value = 7; }
int64_t primed(void) { return primed_value; }
