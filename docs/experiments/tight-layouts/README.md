# Tight layouts

Whether dropping a value's tail padding pays: in every struct, so in every
place a value is stored (a list's elements, an array's, a member inside
another struct, a local), not only in a list's elements. With field
ordering (`docs/design/lowering.md` L5) a struct has no padding between its
members, so a struct without its tail padding is a packed one: no padding
at all and alignment 1. The switch `ZANE_PACK` turns it on:

- `ZANE_PACK=structs`: every value struct's layout is packed.
- `ZANE_PACK=all`: every sum's is too, its tag one byte rather than a
  4-byte tag padded to the payload at offset 8 (a niche sum is left as it
  is).

The switch is read where a layout is made, so a build with it and one
without are different programs. The default build and the test suite are
unchanged with it unset. Measured on `main` at `7e7c3ca` plus this
experiment, built with the pixi environment (LLVM 21).

Tools here, run from the repository root after `pixi run just build`:

- `fixtures.sh SWITCHES…`: every codegen fixture built with and without the
  switches, unoptimized and optimized, run under `ZANE_CHECK=1`, outputs
  compared.
- `ffi.sh SWITCHES…`: every FFI fixture built with the switches and
  compared with its golden output.
- `measure.py [N] [PASSES] [RUNS]`: `bench/layouts` built once per mode,
  timed and its peak memory read.

## Step 1: pack every value struct, then every sum

**Design.** `Nodes.Ty.tight` wraps a struct (and with `all`, a sum) in the
existing `Ty.Packed` layout, which the pooled-variant experiment
(`docs/experiments/goose-comparison`) added for its nodes.
`Type_layout.shape` and the Zane side of the C conversion
(`Callback.layout`) apply it, so a C-compatible value type still crosses in
C's layout, rebuilt field by field. What had to follow:

- every walk over a layout's members that matched only `Ty.Struct` (a
  constructor's record, the owned-block positions, the memo tables'
  scalar test and flattening, the optimizer's materializing and locating,
  a member-path store, the scalar-struct store split) takes a packed struct
  too, and a packed sum where a sum is walked;
- the owned-block walks read a packed sum's tag as a byte;
- a snapshot read through a place inside a packed value goes to the
  runtime, since a load at any byte is not atomic;
- every plain load and store in the module is marked as at any byte, since
  a value can now lie at any offset in a list, an array or another value,
  and a handle's or a box's fields are read through it. This is the cost of
  a compiler that can prove no alignment at all: an upper bound.

**Correctness.** `fixtures.sh ZANE_PACK=structs` and `fixtures.sh
ZANE_PACK=all`: all 140 builds (70 fixtures, unoptimized and optimized)
give the same output as without the switch. `ffi.sh` with either: every
FFI fixture matches its golden output, except `archives`, `callbackNull`
and `noObject`, which the script cannot run as their rules do (an archive
step, an expected abort) and which differ without the switch too.
`pixi run just test-compiler` passes with the switch unset.

**Results.** `bench/layouts` builds a list of 10,000,000 values pushed one
at a time and reads every one 10 times; shapes 7 and 8 read in a scattered
order (a stride of 7919 mod N). `measure.py` builds it with `--optimize`
once per mode, checks the three print the same checksum, and takes the
median of 5 runs, interleaved, on a 4-core Intel Xeon at 2.1 GHz in a
cloud container (so a few percent is noise: the control, shape 6, moves by
up to 3%):

    pixi run -- python3 docs/experiments/tight-layouts/measure.py 10000000 10 5

| shape | bytes, default → packed | default | `structs` | `all` |
| --- | --- | --- | --- | --- |
| 1 `Pair { Int; I32 }` | 16 → 12 | 0.330 s, 155 MiB | 0.285 s, 117 MiB | 0.293 s, 117 MiB |
| 2 `Flagged { Int; Bool }` | 16 → 9 | 0.363 s, 155 MiB | 0.220 s, 88 MiB | 0.227 s, 89 MiB |
| 3 `Trio { Bool; Int; I32 }` | 16 → 13 | 0.429 s, 155 MiB | 0.399 s, 127 MiB | 0.375 s, 127 MiB |
| 4 `Outer { Pair; I32 }` | 24 → 16 | 0.490 s, 232 MiB | 0.345 s, 155 MiB | 0.347 s, 155 MiB |
| 5 `Maybe { some Int; none }` | 16 → 9 (`all`) | 0.335 s, 155 MiB | 0.336 s, 155 MiB | 0.212 s, 89 MiB |
| 6 `Wide { Int; Int }` | 16 → 16 | 0.373 s, 155 MiB | 0.368 s, 155 MiB | 0.378 s, 155 MiB |
| 7 `Trio`, scattered | 16 → 13 | 1.113 s, 155 MiB | 1.132 s, 127 MiB | 1.152 s, 127 MiB |
| 8 `Wide`, scattered | 16 → 16 | 1.605 s, 155 MiB | 1.660 s, 155 MiB | 1.682 s, 155 MiB |

(`results-step1.txt` holds the script's own table.)

- **Memory falls by the bytes saved**, to within the list's growth: a
  quarter for `Pair`, 43% for `Flagged` and `Maybe`, a third for `Outer`,
  whose `Pair` member loses its tail inside it as well as in the list.
- **A sequential pass gets faster by about what it reads less**: 14% for
  `Pair`, 39% for `Flagged`, 30% for `Outer`, 37% for `Maybe`. These
  loops are bound by memory traffic, and an element at any byte costs x86
  nothing when the next one is read straight after it.
- **Scattered reads gain nothing.** Each one misses the cache wherever the
  element is, and a 13-byte element straddles two 64-byte lines in about
  one read in five, where a 16-byte one never does: the second miss eats
  what the smaller footprint saves. `Trio` scattered is 2-3% slower packed,
  within the noise of the control.
- **Dropping every alignment hint costs nothing measurable here**: `Wide`,
  whose layout packing leaves as it is, runs the same in every mode.

## What remains

- The repository's perf programs (`tests/perf/run --build optimized`) under
  each mode, in simulated cycles, for code that is not a list of padded
  structs.
