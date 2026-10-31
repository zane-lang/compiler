#include "once.h"

long long use_once(void) { return once(1) + once_count; }
