#include "api.h"

#include <string.h>

int64_t c_length(const char *text) { return (int64_t)strlen(text); }

int64_t c_sum(const char *left, zane_bytes middle, const char *right) {
    return (int64_t)strlen(left) * 10000 + (int64_t)middle.size * 100 + (int64_t)strlen(right);
}

static char echoed[1024];

zane_bytes c_echo(const char *text) {
    size_t n = strlen(text);
    if (n >= sizeof echoed) n = sizeof echoed - 1;
    memcpy(echoed, text, n);
    return (zane_bytes){ (const uint8_t *)echoed, n };
}
