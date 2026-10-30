/* `jump`, written in file-scope assembly: it jumps to `landing`, a C
   function of another source, with the argument it was called with. */

#include "defined.h"

#if defined(__aarch64__)
#define JUMP "b"
#else
#define JUMP "jmp"
#endif

__asm__(".text\n"
        ".globl " SYMBOL(jump) "\n"
        ".p2align 4\n"
        SYMBOL(jump) ":\n"
        "\t" JUMP " " SYMBOL(landing) "\n");

int plain(void) { return 1; }
