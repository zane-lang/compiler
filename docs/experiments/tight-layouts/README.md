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
- `ZANE_PACK=niche`: as `all`, and a sum whose other cases a spare byte
  of its one payload can name has no tag at all (step 4).

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
- `measure.py [N] [PASSES] [RUNS] [MODE…]`: `bench/layouts` built once per mode,
  timed and its peak memory read (`SHAPES=1,2` picks shapes).
- `bench/niches`: a program that builds, matches, copies and stores sums
  of every niche kind; every mode must print the same.
- `arm64.sh`: the check and the measurements on another machine, through
  the Shell workflow (step 5).

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
  a compiler that can prove no alignment at all: an upper bound, which
  step 3 narrows.

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

## Step 3: alignment kept where it is known

**Design.** Step 1 marks every plain read and write in the module as at
any byte. That stays the starting point, since a reference, a place lent
to a callee and a member inside a packed value can each be at any byte,
and nothing in the IR tells them from an aligned pointer. What changed is
that each load of a pointer that always names something aligned now says
so with LLVM's `!align` metadata (`List_handle.aligned`):

- a runtime record's or context's pointer field (`Emit.field`) and the open
  scope read from `zane_open`, which name records and frames;
- a block taken from a size class's free list or a region's frontier, in
  emit and in the walks (`Walks.take`): every block is at least a word and
  aligned to one (`runtime/arena.c`);
- a list's block (`List_handle.items`), aligned to a word
  (`ZANE_LIST_ALIGN`), and a box's block (`Walks.load_box`).

LLVM's `-O2` already gives back the alignment of a read or write whose
address it can trace to a stack slot, a global or an `llvm.assume`d frame;
with these facts it traces the rest of the runtime's bookkeeping and every
element of a list whose stride keeps it aligned, while an element of a
13-byte stride stays at any byte. The facts hold with or without packing,
but are said only under `ZANE_PACK`, so the default build is unchanged;
`ZANE_PACK_HINTS=0` leaves them unsaid, as step 2 did.

In `bench/layouts`'s optimized IR under `structs`, reads and writes marked
at any byte go from 362 (of 854) to 111. What is left is the members of
packed values, which are at any byte, and reads through a pointer loaded
from a place whose own alignment is unknown.

**Correctness.** `fixtures.sh` and `ffi.sh` with `ZANE_PACK=structs` and
with `ZANE_PACK=all`: the same results as in step 1. `pixi run just
test-compiler` passes with the switches unset.

**Results.** `measure.py 10000000 10 5` with five modes interleaved
(`results-step3.txt`):

| shape | default | `structs`, no facts | `structs` | `all`, no facts | `all` |
| --- | --- | --- | --- | --- | --- |
| 1 `Pair` | 0.354 s | 0.330 s | 0.315 s | 0.329 s | 0.318 s |
| 2 `Flagged` | 0.353 s | 0.268 s | 0.273 s | 0.253 s | 0.247 s |
| 3 `Trio` | 0.439 s | 0.403 s | 0.409 s | 0.391 s | 0.408 s |
| 4 `Outer` | 0.515 s | 0.378 s | 0.384 s | 0.369 s | 0.385 s |
| 5 `Maybe` | 0.373 s | 0.360 s | 0.381 s | 0.235 s | 0.241 s |
| 6 `Wide` | 0.417 s | 0.404 s | 0.407 s | 0.386 s | 0.392 s |
| 7 `Trio` scattered | 1.104 s | 1.135 s | 1.128 s | 1.187 s | 1.120 s |
| 8 `Wide` scattered | 1.547 s | 1.538 s | 1.514 s | 1.522 s | 1.559 s |

The facts move no shape by more than the noise, in either direction.
Callgrind (1,000,000 values, 2 passes, `structs`) counts 3 instructions
fewer with them in each shape: the facts change the runtime's bookkeeping
code, not the loops.

`tests/perf/run --build optimized` with the facts
(`perf-structs-hints.txt`, `perf-all-hints.txt`) against step 2's runs
without them: `scopes` 1.1% fewer cycles (all of it instructions), `removal`
0.3% more (instructions too), every other program within 0.12%, and the
same under `structs` and `all`.

## Step 4: byte niches

**Design.** Under `ZANE_PACK=niche`, a sum with one case that has a payload
and others that have none is laid out as that payload alone, when the
payload has a byte with enough values it never holds (`Ty.byte_niche`,
`Ty.spare`, in `lib/cgt/nodes.ml`): another case is one of those values at
that byte, the first of them for the first such case, and so on. A spare
byte is

- a `Bool`'s, which holds 0 or 1, so 254 values are left;
- a packed sum's tag, which holds one value per case;
- what a byte-niche sum leaves of its own spare byte, so a niche sum
  inside a niche sum takes no byte either (`Twice` below);

found through a struct's members (the first that has one) and an array's
first element. This generalizes `Ref32.niche`, which does the same for a
sum of nothing and a box or reference, with 0 for nothing.

What had to follow:

- the sum's LLVM type is its payload's with the spare `Bool` an `i8`
  (`Emit.with_byte`): a `Bool` read as `i1` from a byte that holds 2 does
  not keep the 2, so a value of the sum moves only as bytes, and only a
  case's payload, which holds 0 or 1 there, is read as its own type;
- a case is built as its payload's bytes, or as zero bytes with the case's
  value at the spare byte; a match reads that byte and takes the case its
  value names, or the one with the payload when it names none; the payload
  is at the sum's own address;
- an owned-block position under a byte-niche sum carries its tag as the
  byte's offset and its range of values (`Layout.byte_niche_tag`), which a
  walk tests (`Walks.present`) and the optimizer decodes (`Layout.tag_case`).

**Correctness.** `bench/niches` prints the same in all eight builds
(default, `structs`, `all`, `niche`, each unoptimized and optimized) under
`ZANE_CHECK=1`; its lists' elements, as `--cgt` reports them:

| type | default | `all` | `niche` |
| --- | --- | --- | --- |
| `Maybe { some Flagged; none }` | 24 bytes | 10 | 9 |
| `Several { first; value Flagged; second; third }` | 24 | 10 | 9 |
| `Twice { inner Maybe; outer }` | 32 | 11 | 9 |
| `Entry { named Named; blank }`, `Named` holding a `String` | 40 | 26 | 25 |
| `Holder { Bool; Entry; Int }` | 56 | 35 | 34 |

`fixtures.sh ZANE_PACK=niche`: all 140 builds the same as without it.
`ffi.sh ZANE_PACK=niche`: as in step 1.

**Results.** Two shapes join `bench/layouts`: 9, `Chosen { some Flagged;
none }`, a third of them none; and 10, `Nested { inner Chosen; outer }`, a
fifth of them outer. `measure.py 10000000 10 5 default ZANE_PACK=all
ZANE_PACK=niche` (`results-step4.txt`):

| shape | default | `all` | `niche` |
| --- | --- | --- | --- |
| 9 `Chosen` | 0.474 s, 231 MiB | 0.239 s, 97 MiB | 0.193 s, 88 MiB |
| 10 `Nested` | 0.610 s, 308 MiB | 0.539 s, 108 MiB | 0.246 s, 88 MiB |

The other shapes have no niche and ran as in step 3. One reading is noise:
shape 5, `Maybe { some Int; none }`, ran 23% slower under `niche` than under
`all`, but its code is the same in both builds and Callgrind counts the same
instructions to within 0.01%.

Callgrind, 1,000,000 values and 2 passes:

| shape | default | `all` | `niche` |
| --- | --- | --- | --- |
| 9 `Chosen` | 41.7 M | 40.1 M | 40.4 M |
| 10 `Nested` | 63.5 M | 76.7 M | 59.5 M |

A packed sum inside a packed sum (`Nested` under `all`) costs instructions:
its inner tag and payload are at odd offsets in the outer one's room, read
a piece at a time, so it runs barely faster than the default build for all
its smaller footprint. Without a tag at all, `niche` reads it as one
`Flagged` and runs 2.2 times as fast as `all`.

`tests/perf/run --build optimized` under `niche` (`perf-niche.txt`): the
same as `all` to within 0.04% in every program, none of which has a sum a
byte niche fits (`copies`'s `Tree` has a payload in both cases).

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
- **Code with no padded value is unchanged**: no perf program moved under
  `structs`, and only `copies` (5% faster) under `all`.
- **A byte niche removes a sum's tag where its payload has a spare
  byte**: a `Bool`, an enum, or another such sum. It saves the last byte
  `all` leaves (10 → 9 for an optional `Flagged`), and much more time when
  sums nest, since a packed sum inside a packed sum is read a piece at a
  time and a niche one is read whole (`Nested`: 2.2 times as fast as
  `all`, 2.5 times the default build).
- **A packed sum's room must be words**, not bytes, or LLVM moves its
  payload a byte at a time: that cost `copies` 22% until step 2.
- **Losing alignment information costs nothing measurable on x86**:
  marking every access as at any byte (steps 1 and 2) and keeping the
  alignment wherever it is known (step 3) run the same, to within 1% in
  simulated cycles and within the noise in time. The facts are cheap to
  keep and sound, so a real implementation would keep them, but not for
  speed here.

## What remains

- An ARM64 run: an element at any byte is free on current x86 cores, and
  the measurements here say nothing about other targets, where losing
  alignment information could matter more than it does here.
- More spare values: a box's or a reference's pointer is never null and
  aligned, so it leaves 0 and the low bits; a sum with two payloads could
  put its tag in a spare byte of the larger one when the smaller fits
  around it.
