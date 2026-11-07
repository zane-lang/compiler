#include <stddef.h>
#include <stdint.h>

typedef struct zane_bytes { const uint8_t *bytes; size_t length; } zane_bytes;

zane_bytes own_rest(const char *text);
