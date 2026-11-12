#include "api.h"

int64_t text_byte(zane_bytes text, int64_t index) { return text.data[index]; }
int64_t text_length(zane_bytes text) { return (int64_t)text.size; }
