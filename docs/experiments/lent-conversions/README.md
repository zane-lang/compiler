# Lent conversions: a per-byte loop over a string

What [`lowering.md`](../../design/lowering.md) L11, "Lent conversions",
gains a loop that reads a string one byte at a time through a wrapper's
implicit conversion, as `core`'s `String` and LangArena's helpers do:

```zane
implicit Str(text Text) => text._value;
I64 _byte(text Str, index I64) foreign "text_byte";
I64 byte(text Text, index I64) => _byte(text, index);
```

Before, each `byte(text, i)` copied the whole string to give `_byte` its
`@primitives$String`, so reading every byte of an n-byte string was O(n²).
Now `_byte` reads `text._value` where `text` keeps it.

`bench/` is the program: it doubles a one-byte string N times, N read from
its argument so no build folds it, and sums its bytes. `run [ZANEC] [N ...]`
builds it optimized and plain and times each size.

## Results

Linux x86-64, wall time in seconds; the compiler before is main at 90ebb2b.

| bytes | before, optimized | after, optimized | before, plain | after, plain |
|---:|---:|---:|---:|---:|
| 2^15 | 0.028 | 0.002 | 0.029 | 0.002 |
| 2^16 | 0.100 | 0.002 | 0.122 | 0.003 |
| 2^17 | 0.440 | 0.002 | 0.432 | 0.003 |
| 2^18 | 1.667 | 0.002 | 1.514 | 0.004 |
| 2^19 | 6.415 | 0.002 | 6.439 | 0.004 |

Instructions under Callgrind, optimized build, whole process:

| bytes | before | after |
|---:|---:|---:|
| 2^14 | 271,805,660 | 459,802 |
| 2^16 | 4,324,242,900 | 725,845 |
| 2^18 | | 1,783,269 |
| 2^20 | | 5,079,377 |

Before grows 16× per 4× more bytes; after, past the program's start, about
4 instructions per byte.

The same loop written against `core` (v0.25 at 6c65a05), LangArena's
`hash` before its workaround: `Int byte(text String, index Int) =>
Int(_ffiByte(text, index))` over 2^18 bytes takes 1.665 s before and 0.005 s
after, optimized, with the same hash.
