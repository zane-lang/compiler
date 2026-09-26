/* The Zane runtime (docs/lowering.md L17): what every program links with.

   A program's `main` is `zane_main`, which the C `main` below calls once the
   runtime is ready. Everything else here is what an intrinsic lowers to. */

#include <stdint.h>
#include <stdio.h>

void zane_main(void);

/* `@runtime$Console`'s `print` (effects.md §6.6): exactly the view's length
   in bytes, with no terminator and nothing added. */
void zane_print(const char *bytes, int64_t length) {
	fwrite(bytes, 1, (size_t)length, stdout);
}

int main(void) {
	zane_main();
	return fflush(stdout) == 0 ? 0 : 1;
}
