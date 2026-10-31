#include <stdint.h>

__attribute__((used, section("plugins"))) static const int64_t first = 1;
__attribute__((used, section(".rodata.local"))) static const int64_t second = 2;
__attribute__((used, section("zane_hooks"))) const int64_t third = 3;
