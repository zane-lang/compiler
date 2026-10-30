#include <stdint.h>
#include <stdio.h>

/* A static constructor reaching only the C library, which no member
   including the header can fold away, and an inline function. */
__attribute__((constructor)) static void unbuffer(void) { setvbuf(stdout, 0, _IONBF, 0); }
static inline int64_t unbuffered(void) { return 1; }
