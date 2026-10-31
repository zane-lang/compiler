#include <stdbool.h>
#include <zane_ffi.h>

typedef struct { int32_t x; int32_t y; double scale[2]; } point;
typedef struct { float v; } ratio;
typedef struct { int64_t xs[4]; } quad;
typedef struct { } nothing;
typedef struct { nothing e; int32_t x; } boxed;

double apply(double (*f)(double), double x);
int64_t sum_each(int64_t (*f)(int64_t), int64_t n);
int32_t count_if(bool (*p)(int32_t), int32_t n);
point map_point(point (*f)(point), point p);
void each(void (*f)(int64_t), int64_t n);
int64_t on_threads(int64_t (*f)(int64_t), int64_t x);
int64_t sorted(bool (*before)(int64_t, int64_t), const int64_t *xs);
ratio scale_ratio(ratio (*f)(ratio), ratio r);
quad rotate_quad(quad (*f)(quad), quad q);
boxed open_box(boxed (*f)(boxed), boxed b);
