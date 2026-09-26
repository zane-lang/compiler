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

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. */
int main(void) {
	zane_main();
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
