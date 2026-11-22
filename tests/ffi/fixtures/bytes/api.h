#include <stdbool.h>
#include <zane_ffi.h>

typedef struct { uint8_t tag; int32_t n; unsigned char low; } packet;

uint8_t next_byte(uint8_t b);
unsigned char flip_bits(unsigned char b);
signed char negate(signed char b);
char upper(char c);
int8_t echo(int8_t b);
int64_t byte_sum(const uint8_t *xs, zane_span ys);
packet swap(packet p);
uint8_t apply(uint8_t (*f)(uint8_t), uint8_t b);
packet remake(packet (*f)(packet), packet p);
