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

## Step 2: the repository's perf programs, and a packed sum's room as words

**Results, first run.** `tests/perf/run --build optimized` under each mode
measures every program in `tests/perf` in Valgrind's estimated cycles,
which are the same on every run of one build. With `structs` no program
moved by more than 0.1%: none of them stores a struct with tail padding.
With `all`, `copies` (a tree of value variants copied and summed) was
21.7% slower and `stress` 5.1% slower, though `copies` missed the caches
less (first-level misses down 20%, last-level 17%): its instructions grew
by 38%, all of them in `sum`, the match over the tree.

**Design.** The packed sum's payload room was `[n x i8]`, as the
pooled-variant experiment's packed node had it. LLVM passes that by value
as one argument per byte, and reads an 8-byte payload out of it as eight
byte loads, shifted and joined. The room is now its 8-byte words, then a 4-,
2- and 1-byte integer for what is left (`<{ i8, i64 }>` for `copies`'s
`Tree`), a packed struct whose size is still exactly the room's. A payload
is read through the room's address, so nothing else changed.
`fixtures.sh ZANE_PACK=all` and `ffi.sh ZANE_PACK=all` give the same
results as before it.

**Results.** `tests/perf/run --build optimized`, cycles against the
default build (`perf-default.txt`, `perf-structs.txt` and `perf-all.txt`
hold the script's output; `perf-all-byte-room.txt` the first run's):

| program | default cycles | `structs` | `all` | `all`: instructions, L1 misses, LL misses |
| --- | --- | --- | --- | --- |
| borrows | 53,593,566 | +0.0% | +0.0% | +0.0%, +0.0%, -0.0% |
| copies | 41,087,214 | +0.0% | -5.0% | -1.5%, -19.8%, -16.9% |
| depths | 2,775,856 | +0.1% | -0.1% | +0.0%, -1.5%, +0.0% |
| division | 72,691,687 | +0.0% | +0.0% | +0.0%, -0.3%, -0.1% |
| flips | 204,168,810 | +0.0% | +0.0% | +0.0%, -0.2%, +0.0% |
| floats | 47,749,299 | +0.0% | +0.0% | +0.0%, -0.1%, +0.0% |
| growth | 78,726,309 | +0.0% | +0.0% | +0.0%, +0.0%, -0.0% |
| kept | 1,039,667 | +0.1% | +0.1% | +0.1%, -0.2%, +0.1% |
| leaves | 48,929,487 | +0.0% | +0.0% | +0.0%, -0.3%, -0.1% |
| removal | 222,360,213 | +0.0% | +0.0% | +0.0%, -0.4%, -0.1% |
| repeats | 3,673,214 | +0.0% | +0.0% | +0.0%, -0.4%, -0.1% |
| returns | 137,157,172 | +0.0% | +0.0% | +0.0%, +0.0%, -0.0% |
| scopes | 27,044,190 | +0.0% | +0.0% | +0.0%, -0.3%, -0.1% |
| stress | 1,944,429,585 | -0.0% | -0.0% | -0.0%, -0.3%, -0.0% |
| texts | 55,596,650 | +0.0% | -0.0% | +0.0%, -0.4%, +0.0% |
| trees | 24,473,022 | +0.0% | +0.0% | +0.0%, +0.1%, +0.0% |

`measure.py 10000000 10 5` again (`results-step2.txt`) gives step 1's
picture within the container's noise, which this run puts at about 5% on
the scattered control: memory down by the bytes saved, sequential passes
11% (`Pair`) to 32% (`Flagged`) faster, `Maybe` 30% faster under `all`,
scattered reads and the unpadded control unchanged.

## Findings

- **Dropping tail padding everywhere is packing everything**, once fields
  are ordered: no struct has padding between its members, so the tail is
  all that is left to drop, and an element at any byte then needs
  alignment 1.
- **It pays where values with a padded tail are stored in bulk and read
  in order**: memory falls by the bytes saved (a quarter to 43% in the
  shapes measured) and a pass that streams them gets faster by most of
  that. A struct inside a struct gains twice, since its tail goes in both
  (`Outer`: a third less memory, 24-30% faster).
- **Scattered reads gain nothing**: an element at any byte sometimes
  straddles two cache lines, and the second miss eats what the smaller
  footprint saves.
- **Code with no padded value is unchanged**, the module-wide loss of
  alignment hints included: no perf program moved under `structs`, and
  only `copies` (5% faster) under `all`.
- **A packed sum's room must be words**, not bytes, or LLVM moves its
  payload a byte at a time: that cost `copies` 22% until step 2.

## What remains

- Alignment hints back where a place is known aligned (a local's slot, a
  scalar list's element), to see whether a compiler that keeps them gains
  anything over this upper bound; none of the measurements here shows a
  cost to recover.
- An ARM64 run: an element at any byte is free on current x86 cores, and
  the measurements here say nothing about other targets.
- A tighter sum than a one-byte tag: a payload whose own bytes leave values
  unused could carry the tag (a niche), as `Ref32.niche` does for one
  shape.
