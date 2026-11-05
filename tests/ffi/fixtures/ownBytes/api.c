#include "api.h"

#include <string.h>

zane_bytes own_rest(const char *text) {
    size_t n = strlen(text);
    return n ? (zane_bytes){ (const uint8_t *)text + 1, n - 1 } : (zane_bytes){ (const uint8_t *)text, 0 };
}
