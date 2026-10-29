#include <zane_ffi.h>

typedef struct clock_t_ clock_t_;

extern clock_t_ zane_clock;
int64_t clock_now(const clock_t_ *c);
