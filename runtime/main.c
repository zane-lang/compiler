#include "zane_internal.h"

/* An integer division by zero (docs/lowering.md §9): what the program wrote
   so far is kept, and it stops with a failing status. */
void zane_divide_by_zero(void) {
	fflush(stdout);
	fputs("division by zero\n", stderr);
	exit(1);
}

/* A mistake of the compiler's, not the program's: the program stops. */
void zane_broken(const char *what) {
	fflush(stdout);
	fprintf(stderr, "zane runtime: %s\n", what);
	abort();
}

/* A program whose output did not all reach stdout did not succeed: a write
   that failed earlier leaves the stream's error indicator set, even when the
   final flush has nothing left to fail on. The program's own scope is open
   around `main`, and when it returns every other scope has drained, and
   every call it spawned has returned. What its own region still holds --
   floated hosts, and what they own, which may have changed since they
   floated -- goes with the program. */
int main(void) {
	zane_self = zane_context_new();
	zane_scope_enter();
	zane_program = zane_mark_at(zane_self, 0);
	zane_main();
	if (zane_self->depth != 1) zane_broken("a scope was left without draining");
	return fflush(stdout) == 0 && !ferror(stdout) ? 0 : 1;
}
