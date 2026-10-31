#include "lib.h"

#include <stdlib.h>

int64_t total = 100;

int64_t helper(void) { return total + 2; }
int64_t named(void) __attribute__((alias("helper")));

static int64_t warmed;
__attribute__((constructor)) static void warm(void) { warmed = 1; }
int64_t was_warmed(void) { return warmed; }

int64_t parsed(void) {
	int (*volatile parse)(const char *) = atoi;
	return parse("42");
}
