#include <stdint.h>

/* A header defining a counter, an external constructor that bumps it and
   a function reading it, all of which the archive's member compiles too. */
int64_t started = 0;
__attribute__((constructor)) void start(void) { started++; }
int64_t starts(void) { return started; }
