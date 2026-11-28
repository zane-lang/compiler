#include "api.h"

struct counter_t { int64_t count; };
counter_t plugin_counter;

int64_t counter_next(counter_t *counter) { return ++counter->count; }

int64_t plugin_entry(int64_t x) { return tally_add(x, tally_add(x, x)); }
