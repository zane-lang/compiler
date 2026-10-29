#include <stdbool.h>
#include <zane_ffi.h>

typedef struct { double x, y, z; } vec3;
typedef struct { int32_t id; float weights[3]; vec3 at; } pair;
typedef struct { int32_t tag; int64_t n; } tagged;

int64_t twice(int64_t x);
int16_t narrow(uint8_t byte, short half);
float halve(float x);
bool odd(int n);
int32_t from_bool(bool b);
double sum(const double *xs, zane_span ys);
zane_bytes greet(zane_bytes who);
int64_t length(zane_bytes text);
vec3 vec_add(vec3 a, vec3 b);
pair pair_mirror(pair p);
tagged flip(tagged t);
void add_to(int64_t n);
void reset(void);
int64_t counter(void);
int64_t helper(void);
int64_t named(void);
