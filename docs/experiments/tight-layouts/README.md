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

Since step 13 the `niche` layout is the compiler's only one, and the
switches are gone: the scripts here that set `ZANE_PACK` or `ZANE_UNSWITCH`
now measure the same build in every mode, and reproduce the numbers below
only on the commits that recorded them. The squash merge of PR 353 (`2baf718`
on `main`) left out the branch's history: `506bb97` on the PR branch is the
last commit that reads the switches, and `0b88f63` removed them. Get it with
`git fetch origin pull/353/head` and `git checkout 506bb97`. `programs.py`,
`platform.sh`, `aligned.sh`, `arm64.sh`, `compile.py` and `langbench.py` exit
unless `ZANE_TIGHT_LAYOUTS_HISTORICAL=1` is set. To compare layouts on
current `main`, build two compilers and use `wall14.py`.

Before step 13, the switch was read where a layout is made, so a build with
it and one without are different programs. The default build and the test suite are
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

## Step 5: AArch64

**How.** `pixi.toml` solves for `linux-64`, `osx-64`, `osx-arm64` and
`win-64`, so the AArch64 machine at hand is GitHub's `macos-latest` runner
(Apple silicon). The Shell workflow (`.github/workflows/shell.yml`) runs a
command in the pixi environment; on this branch it takes a `runner` input,
and on macOS runs the command through `pixi run`, since macOS's bash 3.2
cannot read the bash completions the shell hook sources. `arm64.sh` builds
the compiler, checks `bench/niches` in every mode and runs `measure.py`.
Dispatched as runner `macos-latest`, command
`docs/experiments/tight-layouts/arm64.sh`, against this branch.

**Correctness.** `bench/niches` printed the same in all eight builds, under
`ZANE_CHECK=1` (run 43071348356).

**Results.** `measure.py 10000000 10 5` over five modes (run 43071348356,
`results-arm64.txt`); time, then peak memory, which is the same as on x86:

| shape | default | `structs`, no facts | `structs` | `all` | `niche` |
| --- | --- | --- | --- | --- | --- |
| 1 `Pair` | 0.113 s | 0.072 s | 0.070 s | 0.069 s | 0.072 s |
| 2 `Flagged` | 0.124 s | 0.083 s | 0.081 s | 0.086 s | 0.087 s |
| 3 `Trio` | 0.133 s | 0.167 s | 0.166 s | 0.162 s | 0.168 s |
| 4 `Outer` | 0.141 s | 0.101 s | 0.105 s | 0.108 s | 0.102 s |
| 5 `Maybe` | 0.105 s | 0.109 s | 0.105 s | 0.080 s | 0.083 s |
| 6 `Wide` | 0.132 s | 0.128 s | 0.128 s | 0.130 s | 0.134 s |
| 7 `Trio` scattered | 0.926 s | 0.879 s | 0.894 s | 0.891 s | 0.888 s |
| 8 `Wide` scattered | 0.922 s | 0.888 s | 0.923 s | 0.892 s | 0.909 s |
| 9 `Chosen` | 0.124 s | 0.132 s | 0.127 s | 0.081 s | 0.081 s |
| 10 `Nested` | 0.168 s | 0.152 s | 0.179 s | 0.144 s | 0.145 s |

- **Sequential passes gain more than on x86**: `Pair` 38%, `Flagged` 35%,
  `Outer` 28%, `Maybe` and `Chosen` about a third under `all`.
- **`Trio` loses 25%**, where x86 gained. Its loop differs from the
  default build's in two ways: the element's address is a multiply-add by
  13 rather than a shift by 4, and its `Int` is read at every byte offset
  in turn. A control settles which (run 43073543508, 9 runs): shape 11,
  `Quads { I32; I32; I32; Bool }`, has `Trio`'s 13-byte stride and no
  8-byte member.

  | shape | default | `structs` |
  | --- | --- | --- |
  | 3 `Trio` | 0.199 s | 0.243 s |
  | 11 `Quads` | 0.192 s | 0.158 s |
  | 1 `Pair` | 0.156 s | 0.105 s |

  `Quads` gains 18% and `Trio` loses 22% on the same stride. That looked
  like the cost of an 8-byte read at an odd offset, but it is not settled:
  `Flagged` (9 bytes) reads its `Int` at every offset in turn too, and
  gains 35%; and `Quads` differs from `Trio` in its loop as well, since
  `trios` serves the scattered shape too, so its loop picks its index
  between two computations, one a division, before multiplying it by the
  stride. Step 6 separates the two. (The runner of this run was slower
  than the first one's throughout; only rows within one run compare.)
- **Scattered reads gain a little** (3-5%), where x86 gained nothing.
- **The alignment facts make no difference here either**: `structs` with
  and without them is the same to within the noise.
- **The niche saves memory but no time over `all` here**: `Nested` runs
  the same under `all` and `niche` (0.144 s, 0.145 s), so the piecewise
  reads of a packed sum inside a packed sum that cost x86 2.2 times cost
  this core nothing.

## Step 6: `Trio`'s loss is its loop, and unswitching fixes it

**Isolating.** Shape 12 is `Trio` in a loop of its own, with no scattered
branch (run 43074938173, AArch64, 9 runs, `results-arm64.txt`):

| shape | default | `structs` |
| --- | --- | --- |
| 3 `Trio`, the loop it shares with shape 7 | 0.229 s | 0.252 s |
| 12 `Trio`, a loop of its own | 0.142 s | 0.123 s |
| 2 `Flagged` | 0.134 s | 0.094 s |
| 11 `Quads` | 0.176 s | 0.146 s |

In a loop of its own, packed `Trio` gains 13%: the layout is not the cost.
`trios` picks each index between `j` and the scattered one with a
loop-invariant flag, so LLVM cannot step a pointer through the list and
computes the address from the index on every element: with a 16-byte
stride a shift folded into the add, with 13 a multiply-add. Apple's cores
pay for the multiply-add on every element; x86 hid it.

**Design.** Non-trivial loop unswitching copies a loop once for each way a
loop-invariant condition goes, so each copy has an index LLVM steps. `-O3`
runs it and `-O2`, which the optimized build is, does not.
`Passes.nontrivial` turns `simple-loop-unswitch<no-nontrivial;trivial>`
into `simple-loop-unswitch<nontrivial;trivial>` in the optimized and tier 1
pipelines: on under `ZANE_PACK`, off with `ZANE_UNSWITCH=0`, and on in any
build, the default included, with `ZANE_UNSWITCH=1`. Compiled for
`aarch64-apple-darwin`, `trios` gains a second copy of its loop whose
sequential reads step a pointer by 13, two elements a turn.

**Correctness.** `fixtures.sh` with `ZANE_PACK=structs` and with
`ZANE_PACK=niche`, which now unswitch: all 140 builds the same.
`bench/niches` the same under both.

**Results, AArch64** (run 43076494289, 7 runs; this runner was noisy:
`Pair`, whose loop unswitching does not touch, moves by 20% between two
modes, so only differences larger than that count):

| shape | default | default, unswitched | `structs`, not unswitched | `structs` | `niche` |
| --- | --- | --- | --- | --- | --- |
| 3 `Trio` | 0.193 s | 0.153 s | 0.248 s | 0.158 s | 0.156 s |
| 6 `Wide` | 0.197 s | 0.125 s | 0.207 s | 0.136 s | 0.129 s |
| 7 `Trio` scattered | 1.426 s | 1.293 s | 1.435 s | 1.247 s | 1.260 s |
| 9 `Chosen` | 0.171 s | 0.181 s | 0.185 s | 0.187 s | 0.117 s |
| 10 `Nested` | 0.250 s | 0.242 s | 0.251 s | 0.242 s | 0.186 s |

Packed `Trio` goes from 28% slower than the default build to 18% faster.

**Results, x86** (`results-step6-x86.txt`, 5 runs):

| shape | default | default, unswitched | `structs`, not unswitched | `structs` |
| --- | --- | --- | --- | --- |
| 3 `Trio` | 0.417 s | 0.350 s | 0.376 s | 0.316 s |
| 6 `Wide` | 0.382 s | 0.317 s | 0.397 s | 0.310 s |
| 7 `Trio` scattered | 1.105 s | 0.940 s | 1.134 s | 0.972 s |
| 8 `Wide` scattered | 1.461 s | 1.206 s | 1.560 s | 1.257 s |

The shapes whose loop is shared gain 15-20% from unswitching on both
machines, packed or not; the others do not move. On the perf programs
(`perf-default-unswitch.txt`, the default build with `ZANE_UNSWITCH=1`),
`division` takes 1.2% fewer cycles and `kept` 0.3% more; no other program
moves by more than 0.11%.

## Step 7: the whole suite under `niche`

`just test-compiler`'s steps, run with `ZANE_PACK=niche`. The dune tests
ran in their own build directory (`--build-dir _build_niche`, with
`DUNE_CACHE=disabled`), so dune's cache could not replay a default run.
The first run found two bugs, both fixed here:

- **Memoization refused packed keys.** `Memo.fixed` treated every
  `Ty.Packed` as holding an address, so `moves`, a recursion over a
  variant, lost its table in all three builds. A packed type is now as
  fixed as what it packs.
- **A struct too large to measure crashed `tight`.** `beyondLimitField`
  died with `Too_large` (exit 3) instead of the size error, because
  `tight` measured the struct first. It now leaves such a struct
  unpacked for the size check to refuse.

`tight` also packs a struct only when packing makes it smaller. A struct
with no padding keeps its natural type and alignment. That took 14
golden layouts and two alignment tests off the list without changing
any padded shape's layout.

What still differs, and why each is expected:

| Test | Count | Why |
| --- | --- | --- |
| codegen and ffi `.cgt` goldens | 15 | They print the layout: `packed <…>` types, `@1` instead of `@8` offsets. |
| `tests/unit` layout tests | 7 | They assert the default order and padding. |
| `abi_test` (3 targets) | 1 | It expects a fieldless variant as `{ i32 }`; packed, its tag is `<{ i8 }>`. |
| `facts_test` alignment | 1 | It expects `align 8` on every `i64` access, which the blanket alignment-1 pass removes (step 3). |

No program's output changed:
- tests/runtime, tests/semantics, tests/parser and tests/nesting pass;
- so do the tiers tests, the memory probes and reclaim.

The default build (`ZANE_PACK` unset) passes `just test-compiler` after
the fixes.

What making it the default would take: regenerate the goldens and the
unit tests' expectations. Also replace the blanket alignment-1 pass with
each access's own alignment. Steps 3 and 6 measured no speed cost to
the blanket pass, but it hides from LLVM every alignment the emitter
knew.

## Step 8: what packing costs at the C boundary

`bench/ffi` passes structs to C by value, 100 million times in a loop.
The C functions are `noinline` and hide one input behind an empty `asm`,
so LLVM cannot fold the calls away. Four shapes:

- **`Vec3`**: three `F64`. It has no padding, so every layout passes it
  as it is.
- **`Tagged`** and **`Nested`**: they have padding, and the default
  layout already reorders their fields. The crossing converts them
  member by member in both layouts; packing changes only what the
  conversion reads from.
- **`Ordered`** (`{I64, I32}`): already in C's order, with tail padding.
  The default passes it as it is. Packing makes it 12 bytes against C's
  16, so only the packed layout converts it.

On x86 (`results-step8-ffi.txt`), best of 7, then best of 15
interleaved for the two that moved:

| Shape | Plain | Optimized |
| --- | --- | --- |
| `Vec3` | +1% | −1% |
| `Tagged` | −4%, then 0% | +6%, then +12% |
| `Nested` | −4% | −5% |
| `Ordered` | +12%, then +14% | −2%, then −1% |

`Ordered`'s plain build is the one steady cost, about 0.4 ns a
crossing. Its optimized build folds the conversion into the call. The
`Tagged` optimized numbers moved by ±10% between runs of the same pair
of binaries, so they are noise. Both layouts emit the same member-wise
conversion for it.

The one cost packing adds at the boundary is a C-ordered struct with
tail padding converted where it used to be passed as is. It shows only
unoptimized. Code that crosses into C in a hot loop with such a struct
loses about a third of a nanosecond a call in a `zane run` build.

## Step 9: compile time and code size

`compile.py` builds every `tests/perf` program three times in each mode,
plain and with `--optimize`. It reports the best wall time and the
stripped executable's size, summed over the programs.

The first run found a bug in this experiment's own code. Optimized
`niche` builds took 6.1× as long: `division` 6s → 48s, `stress` 11s →
84s. Plain builds took 16% longer. The blanket alignment-1 pass (step
3) printed every load and store to text to find the atomic ones. Each
print renumbers the whole function, so the cost grew with the square of
function size. The pass now reads the access's ordering through a
stub, `Llvm_extra.is_atomic`. Atomic accesses still keep their
alignment: `memo/spawning`'s eight atomic accesses stay `align 8`. The
niche suite's failure list is unchanged.

After the fix (`results-step9-compile.txt`, x86):

| Mode | Plain time | Plain size | Optimized time | Optimized size |
| --- | --- | --- | --- | --- |
| default | 0.94 s | 1269.9 KiB | 22.28 s | 1085.9 KiB |
| default + unswitch | +0.7% | 0.0% | +0.3% | +0.1% |
| niche (unswitching on) | −0.8% | +0.1% | −0.8% | −2.8% |
| niche, `ZANE_UNSWITCH=0` | −0.4% | +0.1% | −0.6% | −2.8% |

Neither packing nor unswitching costs compile time; every difference
is within 1%. Unswitching adds 0.1% of code in these programs. Packing
makes optimized executables 2.8% smaller and unoptimized ones 0.1%
larger. Most of an executable is the runtime and the C library, so the
compiled code itself shrinks more than 2.8%.

## Step 10: realistic programs, and langbench against `core`

`main` gained four perf programs shaped like real code
(zane-lang/compiler#351), and they were merged into this branch:
- `particles`: a list of structs mixing `Float`s with a flag;
- `tokens`: `{kind, start, length}` tokens;
- `entities`: entities whose components are optional;
- `paths`: a graph search with an optional predecessor per node.

Every perf program was measured under Callgrind, as the perf gate
counts it (`tests/perf/run --fresh --build optimized`), in four modes.
The rows are in `perf10-*.txt`, and every output matched its golden:

| Program | Default cycles | Default + unswitch | Niche | Niche, `ZANE_UNSWITCH=0` | Niche L1 misses |
| --- | --- | --- | --- | --- | --- |
| entities | 43,249,220 | +1.3% | −10.6% | −10.7% | −29.0% |
| paths | 55,174,291 | 0.0% | −6.6% | −6.6% | −33.4% |
| particles | 34,920,250 | 0.0% | −5.0% | −5.1% | −17.4% |
| copies | 41,087,272 | 0.0% | −5.0% | −5.0% | −19.8% |
| tokens | 50,814,073 | 0.0% | −3.4% | −3.4% | −12.2% |
| division | 72,691,474 | −1.2% | −1.2% | 0.0% | −0.1% |
| scopes | 27,044,228 | 0.0% | −1.1% | −1.1% | 0.0% |
| removal | 222,360,210 | 0.0% | +0.3% | +0.3% | 0.0% |
| kept | 1,040,071 | +0.3% | +0.3% | +0.1% | −0.2% |
| the other 11 | | within 0.1% | within 0.1% | within 0.1% | within 1.5% |

All four realistic programs get cheaper under niche, through fewer cache
misses. The largest rise anywhere is +0.3%, well inside the gate's 1%.
Unswitching alone is a wash on these programs: `division` −1.2%,
`entities` +1.3%.

**langbench**, built against `core`'s head with `--optimize`:
- `langbench.py` times langbench's programs by wall clock.
- `langbench_cycles.py` measures them under Callgrind at each test's
  check size.

Six of the 16 fail to compile in every mode: `trialdiv`, `ntree`,
`spectralnorm`, `allocfree`, `gameloop` and `particles`. langbench has
not been migrated to the compiler's current ownership rules and syntax,
so these failures have nothing to do with packing. The wall clock here moved rows by up to
±20% between runs (`results-step10-langbench-x86.txt`; a rerun at 21
runs put `listgrowth`'s +16.6% at −2.8%). The Callgrind counts
(`results-step10-langbench-cycles.txt`) are the reliable ones:

| Test | Default + unswitch | Niche |
| --- | --- | --- |
| treecopy | 0.00% | −4.64% |
| nbody | −0.36% | −0.37% |
| concscan | +0.08% | +0.07% |
| the other 6 | within 0.07% | within 0.08% |

## Step 11: every supported platform

`platform.sh` ran through the Shell workflow on each runner. It builds
the compiler, then:
- checks `bench/niches` in every mode;
- runs `measure.py` (medians of 5) over default, `ZANE_UNSWITCH=1` and
  niche;
- times the perf programs by wall clock (`programs.py`, best of 7);
- times langbench against `core` (`langbench.py`, best of 5).

Two fixes to the workflow made Windows run, both on this branch only:
- its permission check now runs in bash;
- the command is started through `pixi run`, since on Windows `pixi
  shell-hook` writes for cmd.

The Intel Mac (`macos-15-intel`) is left out, at the maintainer's call,
because that runner is very slow.

Results, by machine:

| Machine | File |
| --- | --- |
| Linux, AMD EPYC 7763 (Zen 3) | `results-step11-linux-x86.txt`, `results-step11-linux-unswitch-split.txt` |
| Linux, AMD EPYC 9V45 (Zen 5) | `results-step11-linux-epyc-scaled.txt` |
| Windows x86-64 | `results-step11-windows-x86.txt` |
| macOS, Apple M1 | `results-step11-macos-arm64.txt` |

On every machine, `bench/niches` prints the same in every mode,
unoptimized and optimized.

**Layouts (`measure.py`).** Packed values take 25–71% less peak memory
everywhere. Niche time against default:

| Shape | EPYC 7763 | Windows | M1 |
| --- | --- | --- | --- |
| Pair | −9% | +1% | −35% |
| Flagged | −22% | −8% | −34% |
| Trio | −11% | −18% | −32% |
| Outer | −29% | −21% | −31% |
| Chosen | −50% | −37% | −38% |
| Nested | −52% | −37% | −4% |
| Trio scattered | −13% | −13% | −8% |
| the rest | −24% to 0% | +3% to −26% | −37% to −4% |

ARM's `Trio`, 28% slower before step 6, is 32% faster. Nothing is
slower by more than Windows' +3% on `Trio plain loop`.

**The perf programs by wall clock.** At their gate sizes most of them
run 1–30 ms, so best-of-7 differences of a few percent are noise. The
realistic ones were rerun at 10–100× their size, best of 15, twice on
each runner:

| Program | Zen 3 niche | Zen 3 niche, no unswitch | Zen 3 default + unswitch | Zen 5 niche | Zen 5 default + unswitch | Xeon (container) niche | M1 niche |
| --- | --- | --- | --- | --- | --- | --- | --- |
| particles | −6.7%, −6.0% | −5.9%, −5.6% | +1.0%, +1.2% | −5.0%, −5.8% | +1.3%, +2.4% | −6.8% | −7.1% |
| tokens | | | | −3.5%, −3.3% | +0.4%, −0.2% | −1.9% | +0.2% |
| entities | +5.1%, +5.9% | +4.7%, +4.7% | +8.2%, +7.9% | +13.6%, +14.2% | +9.2%, +10.9% | +0.3%, −0.9%, +3.2% | −8.3% |
| paths | +1.2%, +1.6% | +1.2%, +1.1% | +0.7%, −0.1% | −12.4%, −2.4% | −8.4%, +0.8% | −7.8% | −1.6% |

(Windows, unscaled: `entities` +10.7%, `paths` −9.5%.)

`entities` is the one loss, and it has two parts:

- **Packing**, about +5% on Zen 3 with unswitching off. Its components
  are optional values whose payload has no spare byte: `Position` is
  two `Int`s. So each packs as a one-byte tag and 16 bytes, and every
  `Int` in it sits at an odd address. Its working set fits in L2, so the
  memory saved buys little, while the unaligned 8-byte accesses, and
  stores the core cannot forward to the load after them, cost cycles.
  Callgrind models neither, which is why it counted −10.6%. The M1,
  which handles unaligned accesses more cheaply, gains 8%.
- **Unswitching**, +7% to +11% on every x86 machine, on the default
  layout too. In `zane_main` it unswitches the loops `irce` (LLVM's
  pass that splits a loop to remove its range checks) had already split
  into pre-, main and post-loops. The code is no larger (194 blocks
  against 197), and Callgrind counts +1.3%. The cost is in something it
  does not model: loop alignment, or what the predictor makes of the
  new shape. Finding which one needs hardware counters, which none of
  these machines exposes.

**langbench by wall clock:**
- Everywhere: within ±3%, except a few rows short enough to be noise.
- M1: `entities` −7.5% and `concscan` −12.7% under niche, but `nbody`
  +7.4%.
- Zen 3: `treecopy` −6.2%.

## Step 12: sums with no niche kept aligned

`ZANE_PACK=aligned` is `niche` with one difference: a sum with no niche
keeps its natural layout, so its payload stays at its own alignment.
Padded structs are still packed, and byte niches still taken. The idea
was to remove step 11's `entities` loss on x86, whose optional
components have no niche.

Under `aligned`:
- all 140 fixture builds print the same;
- the FFI fixtures match, apart from the three `ffi.sh` cannot run in
  any mode;
- `bench/niches` prints the same;
- every perf program matches its golden.

In Callgrind (`perf12-aligned.txt`, unswitching off), `entities`,
`paths` and `copies` count exactly the default's cycles: their sums are
laid out as the default lays them out. `particles` (−5.1%) and `tokens`
(−2.1%) keep their gains.

Each runner (`aligned.sh`) measured the shapes as medians of 7. It
timed the realistic programs scaled up, as best of 15, twice. Default,
niche and aligned all ran with unswitching off. The files are
`results-step12-*.txt`.

| Program, against default | EPYC 7763 niche | EPYC 7763 aligned | Windows niche | Windows aligned | M1 niche | M1 aligned |
| --- | --- | --- | --- | --- | --- | --- |
| particles | −7.9%, −8.7% | −7.0%, −8.1% | −11.6%, −10.9% | −11.0%, −10.4% | −5.1%, −2.3% | −5.7%, −0.1% |
| tokens | −3.8%, −3.0% | −1.7%, −1.7% | −1.3%, −1.2% | −1.0%, −0.5% | see below | see below |
| entities | −0.1%, −1.5% | +0.1%, −1.0% | +1.9%, +8.7% | −3.9%, +1.2% | −9.6%, −9.2% | +6.7%, +3.0% |
| paths | −1.4%, −1.8% | +5.0%, +3.1% | −11.6%, −9.2% | −5.9%, −4.3% | −9.6%, −9.9% | −0.5%, −2.7% |

The shapes match between the two modes except `Maybe`, a sum with no
niche:

| Machine | Niche | Aligned |
| --- | --- | --- |
| EPYC 7763 | −26% time, −43% memory | the default's |
| Windows | −23% time, −41% memory | the default's |
| M1 | −22% time, −43% memory | the default's |

What this shows:

- **`aligned` loses more than it saves.** `entities`' x86 loss does not
  reproduce under niche once unswitching is off. On this EPYC it is
  −0.1% and −1.5%; step 11's +4.7% was one runner instance. Windows is
  the one x86 machine with a loss left: +1.9% and +8.7%, two runs 7
  points apart. Against that, aligned gives up `Maybe`'s gains on every
  machine, `entities`' −9% and `paths`' −10% on the M1, and `paths`' −9%
  to −12% on Windows.
- **The runners' noise floor is about ±5%.** `paths` under aligned,
  whose Callgrind count is the default's to the cycle, measured +5.0%
  and +3.1% on the EPYC.
- **Unswitching is needed for `Trio` on ARM.** Without it, under both
  packed modes:

  | Shape | EPYC 7763 | Windows | M1 |
  | --- | --- | --- | --- |
  | Trio | +6% | +7% | +20% |
  | Wide | −3% | +1% | +12% |

  Step 11 showed what it costs: `entities` +7% to +11% on every x86
  machine, while on the M1 it does not hurt `entities` at all.
- **`tokens` at 50× on macOS printed different output across runs in
  every mode, the default included.** The same command printed one
  output on Linux and Windows. That points at the macOS runtime at that
  size (20 million tokens), not at layouts, and is left to its own
  investigation.

## Step 13: the niche layout made the default

Step 12 settled the shape: `niche`, with non-trivial unswitching only for
AArch64. The change that makes it the compiler's only layout
(`0b88f63` and its follow-ups) also replaced two pieces of this
experiment that were good enough to measure with but not to ship:

- **Per-access alignment.** The blanket pass set every non-atomic load and
  store to alignment 1. `lib/codegen/alignment.ml` now gives each the
  smaller of its type's alignment and what its address is known to be:
  - a stack slot or a global at its own alignment;
  - a getelementptr as far as its constant offset and each index's known
    factor divide its base's;
  - a pointer read back from a stack slot as the least of what is stored
    there;
  - an `!align` load, a parameter's `align`, and the runtime's frames,
    blocks and pushed list slots as `runtime/` places them.

  In the `facts` fixtures every `i64` access keeps `align 8` except in
  the walk helpers, which are given an address that may be anywhere.
- **Truthful parameter attributes.** A by-address borrow and a place
  parameter claimed their type's alignment. Under packing either may be
  a member at any byte of a packed value, so that claim could be false,
  and LLVM is entitled to rely on it. They now claim none; the `sret`
  slot, the caller's own, keeps its alignment.

`just test-compiler` passes. Its layout goldens, unit tests and
attribute tests were brought to the new layout, with new unit tests for
packing, the one-byte tag and byte niches.

**The perf gate.** Measuring every program's three builds with `main`'s
compiler and this one in the same container gives one rise:

| Program | Build | Change |
| --- | --- | --- |
| entities | tiered | +7.5% |
| entities | optimized | −10.7% |
| paths | tiered | −7.9% |
| copies | plain | −6.7% |
| particles | optimized | −5.1% |
| tokens | optimized | −3.4% |

No other row rises by 0.5% or more. Every row that falls by more than
0.5% is a build of `copies`, `entities`, `particles`, `paths`, `tokens` or
`scopes`. Against CI's own rows, a local run also
shows `depths`, `kept` and `repeats` up 2–8%. Those programs are small
enough that the dynamic loader's start-up is most of their count, and it
differs between this container and CI. Built with `main`'s compiler here,
`kept` counts 454,000 instructions and with this one 454,059.

`entities` tiered runs 8% fewer instructions but mispredicts 2.4× as
often in Callgrind's branch simulator. In its sweep loop, `dead(health)`
compiles to a branch on the packed health's one-byte tag, around the
payload compare, where the unpacked layout's build picks with a
conditional move. The load is safe either way: the same loop loads the
payload unconditionally a few instructions later. So this is LLVM's
choice for the unaligned field, not a fault in the code. The optimized
build has the same branch (+52% mispredicts) and still comes out 10.7%
ahead through 29% fewer first-level misses. (Step 14 corrects both
readings: the branch is instruction combining's, and the optimized sweep
has none.)

## Step 14: the branch is instruction combining's sinking

[zane-lang/compiler#354](https://github.com/zane-lang/compiler/issues/354)
asked why step 13's `entities` lost 7.5% tiered while it gained 10.7%
optimized. Measured with Callgrind as `tests/perf` measures, each
conditional branch's mispredicts read from `--dump-instr=yes`:

- **The optimized sweep has no branch.** On `main` at `2baf718`, its loop
  tests every component with `setcc` and `cmov`. Its extra mispredicts
  are in the movement and damage loops. Tier 1's sweep branches three
  times: on the health's tag (`dead`) and on the velocity's tag and the
  position's `x` (`stranded`, `grounded`). Those three are 280,000 of its
  751,000 mispredicts.
- **The pass pipelines do not differ in it.** Tier 1's pipeline over the
  optimized build's IR gives the optimized loop, and the optimized pipeline
  over tier 1's IR gives tier 1's branches. The input differs: in the
  optimized build `main` is inlined into `zane_main`, so its loops go
  through the function passes a second time, and that second round
  recovers the selects. Tier 1 runs `main` through them once.
- **The branch is made by instruction combining.** After SROA, the case
  that reads the health's payload holds only an `extractvalue` of the
  whole-value load and a compare, which the CFG simplifier would make a
  `select`. Instruction combining runs first. It splits the load of
  `<{ i8, i64 }>`, a struct with no padding, into a load of the tag and a
  load of the room, and sinks the room's load into that case, the one
  block that uses it. The next CFG simplifier cannot show that load is
  safe to make before the tag is tested, so the branch stays. The old
  `{ i32, [2 x i64] }` has padding after its tag. Instruction combining
  does not split a load with padding, so the room stayed an
  `extractvalue`.

What was tried, as estimated cycles against `main`, every program and
build (`perf14-main.txt` against `perf14-no-sinking.txt`,
`perf14-freeze.txt` and `perf14-early-simplifycfg.txt`):

| Change | `entities` tiered | `entities` optimized | Other rows past 0.3% |
| --- | --- | --- | --- |
| `-instcombine-code-sinking=false` | −23.9% | −7.5% | `floats` −4.7%, `scopes` −2.6%/−4.7%, `particles` −3.2%/−3.1%, `stress` −0.7%, `division` −0.4%, `growth` +2.5%, `flips` optimized +0.4% |
| `freeze` every multi-piece sum read through a pointer | −10.4% | +5.7% | none |
| a speculating CFG simplifier before the first instruction combining | +2.5% | +24.3% | `particles` −1.7%, `division` +1.2%, `stress` +0.4% |

- **`freeze`** keeps the room's load beside the tag's, since the frozen
  value's members are used in both blocks. But a frozen value is no
  longer known to equal memory, so `hurt`'s `none => health` stores the
  tag and the room back on every pass, where it stored nothing before.
- **The early simplifier** fixes `dead` alone. `stranded`'s test on the
  position is still sunk, and the pipeline's order changes elsewhere.
- **`!unpredictable` or branch weights** cannot help: the `select` is
  held back by the load's safety, not by its cost.
- **An `llvm.assume` that the address is dereferenceable** is used only
  for a pointer that cannot be freed, and LLVM takes any pointer in a
  function that may free as one that can.

Turning sinking off is what shipped (`Passes.llvm_options`). Tier 1's
sweep is then the optimized build's loop, instruction for instruction.
`growth`'s +2.5% is one instruction per push in its fill loop, where
LLVM picks another exit test for the induction variable (`lea; inc; cmp
$1` for `cmp; je`). Code is 1.4% larger over the perf programs
(`division` +3.0%, `stress` +2.4%, the rest within ±0.6%).

**Wall clock, in the container** (Intel Xeon @ 2.10 GHz, best and
median of 15, at 10× the gate size, three runs): `entities` −20% to −25%
optimized and −35% to −41% tiered, against `main`, far past the
container's noise. `growth` at 10× swung from −25% to +16% between runs,
so it says nothing either way. These runs cannot show what step 11 found
on real x86: whether packing's unaligned 8-byte accesses, and the stores
the core cannot forward, cost more than Callgrind counts. `wall14.py`
times one program's optimized and tiered builds by two compilers,
interleaved; on a real x86 machine, with `main`'s compiler copied aside
as `zanec-main`:

    python3 docs/experiments/tight-layouts/wall14.py zanec-main _build/default/bin/zanec/zanec.exe entities 10 15
    python3 docs/experiments/tight-layouts/wall14.py zanec-main _build/default/bin/zanec/zanec.exe growth 10 15

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
- **On AArch64 (Apple silicon) packing pays more**: sequential passes over
  padded values gain a third or more. Its one loss, `Trio`, was a loop
  whose index a loop-invariant flag picks, so its address was a
  multiply by the odd stride on every element; with non-trivial loop
  unswitching packed `Trio` is 18% faster than the default build there.
- **Non-trivial unswitching pays on AArch64, and costs on x86**: 15-20%
  on the benchmark's shared loops on both machines, but on every x86
  machine of step 11 it made `entities` 7-11% slower, on the default
  layout too. Step 13 turns it on for AArch64 targets alone.
- **Losing alignment information costs nothing measurable, on x86 or on
  AArch64**:
  marking every access as at any byte (steps 1 and 2) and keeping the
  alignment wherever it is known (step 3) run the same, to within 1% in
  simulated cycles and within the noise in time. The facts are cheap to
  keep and sound, so a real implementation would keep them, but not for
  speed here.

- **A packed sum's case needs instruction combining's sinking off** to
  stay a `select`. Its load has no padding to keep it whole, so the room's
  load is split off and sunk into the case that reads it, where LLVM
  cannot show it safe to make before the tag is tested. The cost shows
  wherever a loop runs a function's passes once, as tier 1 does (step 14).

## What remains

- The Shell workflow's `runner` input and its macOS step live on this
  branch only; `main`'s workflow runs on `ubuntu-latest` alone.
- More spare values: a box's or a reference's pointer is never null and
  aligned, so it leaves 0 and the low bits; a sum with two payloads could
  put its tag in a spare byte of the larger one when the smaller fits
  around it.
