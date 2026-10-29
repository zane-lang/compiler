#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <string.h>
#include <zane_ffi.h>

static inline int64_t gnu_found(void) {
	static const char text[] = "ab:c";
#ifdef __GLIBC__
	return strchrnul(text, ':') - text;
#else
	return strchr(text, ':') - text;
#endif
}
