#include <stdint.h>

typedef struct { double x, y, z; } vec3;
typedef struct { int32_t tag; int64_t n; } tagged;
typedef struct { int64_t n; int32_t tag; } ordered;
typedef struct { int32_t first; tagged inner; float last; } nested;

vec3 vec_step(vec3 v);
tagged tag_step(tagged t);
nested nest_step(nested n);
ordered ord_step(ordered o);
