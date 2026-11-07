#include <stdint.h>
#define TEST_SECTION(name) __attribute__((used, section(name)))
#define RODATA_SECTION TEST_SECTION(".rodata.local")

TEST_SECTION("plugins") static const int64_t first = 1;
RODATA_SECTION static const int64_t second = 2;
TEST_SECTION("zane_hooks") const int64_t third = 3;
