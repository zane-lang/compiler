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

static long long once_pointed;
static long long *once_target = &once_pointed;
__attribute__((constructor)) static void once_point(void) { *once_target = 13; }
static inline long long once_pointed_value(void) { return once_pointed; }

static long long once_shared;
void once_share(long long x) { once_shared = x; }
static inline long long once_shared_value(void) { return once_shared; }

static const long long once_token = 5;
const long long *once_token_at(void) { return &once_token; }
static inline long long once_token_same(void) { return once_token_at() == &once_token; }

static const long long once_pointee = 3;
static const long long *const once_pointer = &once_pointee;
static const char *const once_name = "once";
const long long *const *once_pointer_at(void) { return &once_pointer; }
const char *const *once_name_at(void) { return &once_name; }
static inline long long once_pointers_same(void) {
  return once_pointer_at() == &once_pointer && once_name_at() == &once_name;
}

struct once_record { long long value; };
static struct once_record once_kept;
void once_keep(long long x) { once_kept.value = x; }
static inline long long once_kept_value(void) { return once_kept.value; }

static long long once_five(void) { return 5; }
static long long (*once_call)(void) = once_five;
long long once_called(void) { return once_call(); }
static inline long long once_call_same(void) { return once_call == once_five; }

long long once_setups = 0;
__attribute__((constructor)) static void once_setup(void) { once_setups++; }
static void (*once_setup_ref)(void) = once_setup;
void (*once_setup_at(void))(void) { return once_setup_ref; }
long long once_setup_runs(void) { return once_setups; }
static inline long long once_setup_same(void) { return once_setup_ref == once_setup; }

long long once_external_setups = 0;
__attribute__((constructor)) void once_external_setup(void) { once_external_setups++; }
__attribute__((destructor)) void once_external_teardown(void) {}
long long once_external_runs(void) { return once_external_setups; }

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
