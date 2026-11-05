#include <zane_ffi.h>
#include <stdbool.h>

typedef struct texts_t texts_t;

extern texts_t zane_texts;

zane_bytes texts_upper(texts_t *t, zane_bytes s);
zane_bytes texts_prefix(texts_t *t, zane_bytes s, int64_t n);
zane_bytes texts_fixed(texts_t *t);
zane_bytes texts_empty(texts_t *t);
int64_t texts_kept(texts_t *t, zane_bytes s);
zane_bytes texts_pure(zane_bytes s);
