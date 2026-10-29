#include <stdint.h>

long long once_count = 4;
long long once(long long x) { return x + once_count; }
long long use_once(void);

long long once_starts = 0;
__attribute__((constructor)) static void once_start(void) { once_starts++; }
long long once_started(void) { return once_starts; }

static long long once_state;
__attribute__((constructor)) static void once_set(void) { once_state = 9; }
static inline long long once_value(void) { return once_state; }

static long long once_helped;
static void once_help(void) { once_helped = 11; }
__attribute__((constructor)) static void once_helper(void) { once_help(); }
static inline long long once_helped_value(void) { return once_helped; }

#ifdef __APPLE__
long long once_alias(long long x) { return once(x); }
#else
long long once_alias(long long x) __attribute__((alias("once")));
#endif

#if defined(__GLIBC__) && defined(__x86_64__)
static long long (*once_resolve(void))(long long) { return once; }
long long once_indirect(long long x) __attribute__((ifunc("once_resolve")));
#else
long long once_indirect(long long x) { return once(x); }
#endif
