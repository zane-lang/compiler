#include <stdint.h>
#ifdef __APPLE__
#define TEST_SECTION(name) __attribute__((used, section("__DATA," name)))
#define RODATA_SECTION TEST_SECTION("__rodata_local")
#else
#define TEST_SECTION(name) __attribute__((used, section(name)))
#define RODATA_SECTION TEST_SECTION(".rodata.local")
#endif

TEST_SECTION("plugins") static const int64_t first = 1;
RODATA_SECTION static const int64_t second = 2;
TEST_SECTION("zane_hooks") static const int64_t third = 3;
