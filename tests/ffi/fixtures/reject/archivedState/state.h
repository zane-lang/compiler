#include <stdint.h>

static int64_t shared_count;
static inline int64_t shared_value(void) { return shared_count; }
