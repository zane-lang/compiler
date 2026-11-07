/* What the toolchain gives every package's C code (spec ffi.md §3.4,
   §3.5): the views a string, an array or a list crosses into C as, and
   the allocator for the bytes of a string C returns. */
#ifndef ZANE_FFI_H
#define ZANE_FFI_H

#include <stddef.h>
#include <stdint.h>

typedef struct zane_bytes { const uint8_t *data; size_t size; } zane_bytes;
typedef struct zane_span  { const void    *data; size_t count; } zane_span;

/* After a declaration of a function or variable, another name for the one
   `target` names, which the same source defines with external linkage:
   `int64_t named(void) ZANE_ALIAS("helper");`. It is the same alias on
   every target, Mach-O's among them, whose C has no `alias` attribute. */
#define ZANE_ALIAS(target) __attribute__((annotate("zane.alias=" target)))

/* `size` bytes for a string a foreign call returns (spec ffi.md §3.5),
   from the region the string is made in: returned as a `zane_bytes` that
   starts at them, they become the string's without a copy. Called only on
   the thread of the call, and never freed by C. */
uint8_t *zane_bytes_alloc(size_t size);

#endif
