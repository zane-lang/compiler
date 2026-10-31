#include <stdint.h>

/* A header of nothing but declarations, an inline function and a static
   constructor bumping a counter the archive defines: the member including
   it shares no external definition with the glue, and runs the
   constructor too. */
extern int64_t runs;
__attribute__((constructor)) static void bump(void) { runs++; }
static inline int64_t counted(void) { return runs; }
