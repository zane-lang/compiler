#include <stdint.h>

/* A header defining a counter, a constructor of its own that bumps it and
   a function reading it, all of which the archive's member compiles too. */
int64_t started = 0;
__attribute__((constructor)) static void start(void) { started++; }
int64_t starts(void) { return started; }
