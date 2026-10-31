/* `hop`, written in file-scope assembly: it jumps to `landing`, a C
   function of another source of the package. */

#define TEXT(x) #x
#define SPELLED(x) TEXT(x)
#define SYMBOL(name) SPELLED(__USER_LABEL_PREFIX__) #name

#if defined(__aarch64__)
#define JUMP "b"
#else
#define JUMP "jmp"
#endif

__asm__(".text\n"
        ".globl " SYMBOL(hop) "\n"
        ".p2align 4\n"
        SYMBOL(hop) ":\n"
        "\t" JUMP " " SYMBOL(landing) "\n");
