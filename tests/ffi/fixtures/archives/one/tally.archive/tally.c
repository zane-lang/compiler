/* The vendored library `tally`, version 1, as both packages hold it:
   built into `tally.a`, which the package's `archive` row names. It
   defines a function, an alias of it and, where the C library resolves
   one, an indirect function; it calls `tally_hook`, which the package's
   own C defines, and `cbrt`, which the `system` row's library does. */
#include <stdint.h>

#define TALLY_VERSION 1

double cbrt(double);
long long tally_hook(void);

long long tally_version(void) { return TALLY_VERSION * 100 + tally_hook(); }

long long tally_root(long long x) { return (long long)cbrt((double)x) + TALLY_VERSION; }

#ifdef __APPLE__
long long tally_alias(void) { return tally_version(); }
#else
long long tally_alias(void) __attribute__((alias("tally_version")));
#endif

#if defined(__GLIBC__) && defined(__ELF__)
static long long (*tally_resolve(void))(void) { return tally_version; }
long long tally_indirect(void) __attribute__((ifunc("tally_resolve")));
#else
long long tally_indirect(void) { return tally_version(); }
#endif

/* Defined by `seed.h`, which only the package's glue compiles. */
extern long long tally_seed;
long long tally_seeded(void) { return tally_seed * 10 + TALLY_VERSION; }
