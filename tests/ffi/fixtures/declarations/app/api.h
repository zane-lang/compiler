#include <stdbool.h>
#include <zane_ffi.h>

typedef struct { double x, y, z; } vec3;
typedef struct { int32_t id; float weights[3]; vec3 at; } pair;
typedef struct deflater_t deflater_t;
typedef struct { int32_t a; } twin;
struct twin { double b; };
struct cursor;

int64_t zane_crc32(int64_t crc, zane_bytes data);
vec3 vec_add(vec3 a, vec3 b);
pair pair_mirror(pair p);
int16_t narrow(uint8_t byte, short half);
bool odd(int n);
double sum(const double *xs, zane_span ys);
double fold(double (*f)(double, int32_t), double start);
zane_bytes name(int64_t id);
void reset(void);
deflater_t *deflater_new(int32_t level);
zane_bytes deflate(deflater_t *deflater, zane_bytes input);
int64_t deflater_total_in(const deflater_t *deflater);
int64_t deflater_compare(const deflater_t *deflater, const deflater_t *other);
void deflater_set(deflater_t *dst, deflater_t *src);
void deflater_free(deflater_t *deflater);
twin twin_typedef(twin t);
struct twin twin_tagged(struct twin t);
struct cursor *cursor_new(void);
void cursor_free(struct cursor *c);
