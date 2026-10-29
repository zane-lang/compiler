#include "state.h"

__asm__(".globl assembled_mark\nassembled_mark:\n");

void count_a(void) { shared_count++; }
