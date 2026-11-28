#include <zane_ffi.h>

typedef struct counter_t counter_t;

extern counter_t plugin_counter;

int64_t counter_next(counter_t *counter);

/* The plugin's own C, which the host looks up by its name: it calls the
   exported lambda `tally_add` by its C name. */
int64_t plugin_entry(int64_t x);
int64_t tally_add(int64_t a, int64_t b);
