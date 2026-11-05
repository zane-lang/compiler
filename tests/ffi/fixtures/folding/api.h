#include <stdbool.h>
#include <stdint.h>
#include <zane_ffi.h>

/* FNV-1a over a string's bytes. */
int64_t fold_checksum(zane_bytes text);

/* A buffer of numbers the program owns: made, pushed to, summed, set from
   another and freed. */
typedef struct buffer_t buffer_t;
buffer_t *buffer_new(int64_t first);
void buffer_push(buffer_t *buffer, int64_t x);
int64_t buffer_sum(const buffer_t *buffer);
void buffer_set(buffer_t *into, buffer_t *from);
void buffer_free(buffer_t *buffer);

/* A ticker outside the program, reached through a capability. */
typedef struct ticker_t { int64_t ticks; } ticker_t;
extern ticker_t zane_ticker;
int64_t ticker_next(ticker_t *ticker);

double fold_sine(double x);

int64_t fold_sorted(bool (*before)(int64_t, int64_t), zane_span xs);

zane_bytes fold_shout(zane_bytes text);
zane_bytes fold_version(void);

/* Three fields, which Zane lays out in another order than C. */
typedef struct { int32_t tag; int64_t n; int32_t k; } trio;
trio fold_trio(trio t);
int64_t fold_pick(int64_t (*f)(trio), trio t);
trio fold_remap(trio (*f)(trio), trio t);
