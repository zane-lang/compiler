#include <zane_ffi.h>

int64_t c_length(const char *text);
int64_t c_sum(const char *left, zane_bytes middle, const char *right);
zane_bytes c_echo(const char *text);
