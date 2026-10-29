#include <zane_ffi.h>

typedef struct counter_t counter_t;

counter_t *counter_new(void);
void counter_free(counter_t *c);
