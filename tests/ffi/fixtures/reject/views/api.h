#include <stdint.h>
typedef struct zane_bytes { int value; } zane_bytes;
typedef struct zane_span { int64_t count; const void *data; } zane_span;
zane_bytes read_name(void);
int64_t count(zane_span s);
