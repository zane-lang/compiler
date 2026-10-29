#include <stdint.h>
#include <zane_ffi.h>
typedef struct { int32_t small; int32_t big; } packed;
typedef struct { unsigned flags : 4; int32_t more; } bits;
typedef struct { _Alignas(16) int64_t x; int64_t y; } aligned;
int64_t two_args(int64_t a, int64_t b);
int64_t variadic(int64_t n, ...);
int64_t unprototyped();
int64_t takes_int(int n);
long takes_long(long n);
void takes_void_ptr(void *u);
double writable_array(double *xs);
int64_t takes_bytes(zane_bytes xs);
packed packed_pass(packed p);
bits bits_pass(bits b);
int64_t aligned_pass(int32_t n, aligned a);
extern int64_t not_a_function;
zane_span returns_list(void);
int32_t narrow_param(int32_t (*f)(int8_t));
int32_t narrow_result(int16_t (*f)(int32_t));
