#include "api.h"

struct counter_t { int64_t count; };
counter_t plugin_counter;

int64_t counter_next(counter_t *counter) { return ++counter->count; }

_Thread_local int64_t plugin_seen;

int64_t plugin_seen_twice(void) { return 2 * plugin_seen; }

int64_t plugin_entry(int64_t x) { return tally_add(x, tally_add(x, x)); }
