/* Defines a function for each NAME and FACTOR, by including itself twice
   through `__FILE__`, which names the source by its fixed path. */
#ifndef FACTOR
#include "api.h"
#include <string.h>

#define NAME twice
#define FACTOR 2
#include __FILE__
#undef NAME
#undef FACTOR

#define NAME thrice
#define FACTOR 3
#include __FILE__
#undef NAME
#undef FACTOR

zane_bytes source_name(void) {
	static const char name[] = __FILE__;
	return (zane_bytes){ (const uint8_t *)name, strlen(name) };
}
#else
int64_t NAME(int64_t x) { return FACTOR * x; }
#endif
