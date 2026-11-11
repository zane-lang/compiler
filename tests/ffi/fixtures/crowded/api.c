/* `mmap`'s anonymous, unreserved mappings are not POSIX. */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE

#include "api.h"

#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <sys/auxv.h>
#endif
#endif

struct crowd_t { int64_t taken; };
crowd_t zane_crowd;

/* An address in the program's own image: the executable's, not that of a
   library this C may be linked into, as a tiered build's tier 1 is. */
static uintptr_t image(void) {
#ifdef _WIN32
    return (uintptr_t)GetModuleHandleW(NULL);
#elif defined(__APPLE__)
    return (uintptr_t)_dyld_get_image_header(0);
#else
    return (uintptr_t)getauxval(AT_PHDR);
#endif
}

/* Takes `bytes` at `at` exactly, with no access, or nothing when any of
   them are taken. */
static int take(uintptr_t at, size_t bytes) {
#ifdef _WIN32
    return VirtualAlloc((void *)at, bytes, MEM_RESERVE, PAGE_NOACCESS) != NULL;
#else
    int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE;
#ifdef MAP_FIXED_NOREPLACE
    flags |= MAP_FIXED_NOREPLACE;
#endif
    void *got = mmap((void *)at, bytes, PROT_NONE, flags, -1, 0);
    if (got == (void *)at) return 1;
    if (got != MAP_FAILED) munmap(got, bytes);
    return 0;
#endif
}

/* Every free 256 MiB piece, on a 256 MiB boundary, within 17 GiB of the
   image taken, as the system's own mappings may take them on macOS, which
   places a mapping right above the image: no free range of 2 GiB is left
   near it. Whether any was free. */
int64_t crowd_near_image(crowd_t *c) {
    uintptr_t piece = (uintptr_t)256 << 20, reach = (uintptr_t)17 << 30;
    uintptr_t at = image(), low = at > reach ? (at - reach) / piece * piece : piece;
    for (uintptr_t p = low; p < at + reach; p += piece) c->taken += take(p, piece);
    return c->taken > 0;
}
