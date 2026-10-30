/* What the toolchain gives every package's C code (spec ffi.md §3.4): the
   views a string, an array or a list crosses into C as. */
#ifndef ZANE_FFI_H
#define ZANE_FFI_H

#include <stddef.h>
#include <stdint.h>

typedef struct zane_bytes { const uint8_t *data; size_t size; } zane_bytes;
typedef struct zane_span  { const void    *data; size_t count; } zane_span;

#endif
