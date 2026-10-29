# Experiment: Zane against Goose on allocation-heavy work

Status: **experimental**. The runtime and codegen changes here are made outside
the spec's rules where that helps, and the spec repo is not updated to match.
This file is the record: what changed, why, and what each step measured.

## Setup

- **Goose** v2026.3 (<https://github.com/aardappel/goose>), compiled to C and
  built with `goose build -O2 --cc clang`. It has data stacks, no heap,
  reusable pools, 4-byte self-relative links, and threads that share nothing.
- **Tests**: the spec repo's `langbench/` (16 tests, `tests.py` gives the
  sizes and expected outputs), with Goose ports in this directory
  (`*.goose`). Every port matches the expected output at both the check size
  and the full size. treecopy's port copies with a recursive `copy_tree` into
  a fresh pool, because Goose's `copy()` does not support an array of
  self-relative refs.
- **Zane** programs are built by a zanec at v0.20 (`4c93b70`, the langbench's
  language version) against `core` v0.5, with this branch's runtime and codegen
  changes ported onto it. The `zane-base` column is unchanged v0.20.
- **C** is built with `clang -O2`.
- **Runner**: `run.py` does one untimed run, then 5 timed runs, and reports
  the median wall time and peak RSS. Set the paths in its environment
  variables, then run it inside the compiler's devbox (clang 19):
  `devbox run -- python3 -u docs/experiments/goose-comparison/run.py`.
- **Machine**: a cloud container. Wall clock there moves by about ±15% from
  run to run. Treat instruction counts (callgrind) and page faults
  (`ru_minflt`) as the firm signal, and wall time as a rough one.
- **gameloop** is left out: its Zane program is wrong as it stands, and the
  fix is tracked in zane-lang/spec#245.

## Steps

### 0. Baseline (v0.20)

Zane trailed Goose on binarytrees, listgrowth, ntree, treecopy and allocfree,
and used 158 MB of peak memory on entities and concscan against C's 94 MB.

### 1. An outgrown oversized list block gives its memory back as it moves (`3952bab`)

When a list grows past its reservation, it moves into a new oversized block.
Before this step, the old block's pages stayed resident until the region
drained, so for a moment the list held both copies. `zane_list_move_out` now
copies the old block a chunk at a time and decommits each chunk's pages once
they are copied.

- entities and concscan peak memory: 158 → 94 MB, level with C.

### 2. Warm reservations and an arrive fast path (`fa7839a`)

- **Warm reservations.** A drained region keeps up to `ZANE_WARM_SPANS` (2)
  list reservations in its context. The next large list reuses one instead of
  mapping fresh pages and faulting them in again. All of them are released
  when the context goes idle.
- **Arrive fast path.** `zane_arrive` returns at once when the slot is in the
  open scope's own region, which is the common case. Only the rare case goes
  out of line, to `zane_arrive_at`. Joining a snapshot moves its results with
  a full walk.

Measured:

| test | before | after |
| --- | --- | --- |
| listgrowth wall time | 0.655 s | 0.241 s (Goose 0.234 s) |
| listgrowth page faults | 313k | 16k |
| allocfree page faults | 78k | 8k |
| allocfree sys time | 0.12 s | 0.02 s |

### 3. Count-sized, word-aligned list blocks (`cd39939`)

Two changes:

- **First block sized by elements.** A list's first block used to be a fixed
  128 bytes. It now holds four elements, rounded to a word, clamped to
  32–128 bytes (`ZANE_LIST_LEAST`, `ZANE_LIST_FIRST`), or more when the first
  push reserves more. The runtime (`zane_list_first_room`) and the inline
  push (`Emit.first_room`) compute the same size.
- **Blocks aligned to a word.** Every list block below oversized is now
  word-aligned (`ZANE_LIST_ALIGN` = 8) instead of 64-byte-aligned (no Zane
  type is aligned past 8). So a block of up to 128 bytes comes from the
  region's size-class free list, the same place a box's block comes from. The
  inline first block pops that list too, where it used to send any region
  with a returned block to the runtime.

Oversized blocks still start one `ZANE_LINE` past their mapping's header.

Effect on ntree, where each node is a list of four 24-byte children (96 bytes,
which used to take a 128-byte block):

| ntree | before | after |
| --- | --- | --- |
| peak RSS | 44.9 MB | 34.3 MB (Goose 24.9 MB) |
| instructions | 2.25 G | 1.41 G (Goose 0.77 G) |
| user time | 0.249 s | 0.169 s (Goose 0.107 s) |

The other tests' instruction counts are unchanged to within 0.1%.

## Results after step 3

The run after step 3: median wall time in seconds, peak RSS in MB.

| test | zane-base | zane | goose | C |
| --- | --- | --- | --- | --- |
| binarytrees | 0.121 / 14.3 | 0.116 / 14.3 | 0.052 / 9.9 | 0.357 / 10.3 |
| entities | 0.539 / 158.4 | 0.587 / 94.4 | 0.496 / 93.8 | 0.571 / 93.8 |
| listgrowth | 0.652 / 63.8 | 0.217 / 63.8 | 0.237 / 63.2 | 0.628 / 63.0 |
| ntree | 0.301 / 44.9 | 0.202 / 34.3 | 0.129 / 24.9 | 0.762 / 60.9 |
| treecopy | 0.208 / 30.3 | 0.203 / 30.3 | 0.119 / 18.2 | 0.390 / 34.3 |
| allocfree | 0.672 / 33.2 | 0.395 / 33.3 | 0.386 / 44.2 | 2.005 / 55.6 |
| particles | 0.145 / 10.0 | 0.134 / 10.0 | 0.141 / 10.0 | 0.177 / 10.0 |
| concscan | 0.251 / 158.4 | 0.249 / 94.4 | 2.440 / 185.4 | 0.202 / 93.8 |

The compute-bound tests (trialdiv, mandelbrot, fannkuch, nbody, spectralnorm)
are level across Zane, Goose and C, as they were at the baseline.

### Instruction counts and user time

Instruction counts are from callgrind, at the full sizes. User time, sys time
and page faults are medians of 7 runs.

| test | zane-base | zane | goose |
| --- | --- | --- | --- |
| binarytrees instructions | 867 M | 866 M | 659 M |
| ntree instructions | 2248 M | 1414 M | 771 M |
| treecopy instructions | 749 M | 749 M | 845 M |
| allocfree instructions | 1256 M | 1256 M | 760 M |
| allocfree user / sys / faults | 0.54 / 0.12 s / 79k | 0.37 / 0.02 s / 8k | 0.38 / 0.02 s / 11k |

allocfree now matches Goose, on less memory. It executes the same
instructions as at the baseline, so all of its gain comes from step 2's page
faults: fewer faults and warm pages.

## Goose's enums against its struct ports

The binarytrees and treecopy ports model the tree as a struct with nullable
4-byte self-relative links: null links mean a leaf. Zane's programs use a
variant. To check how much that choice matters, each test was also ported
with a fixed-mode Goose `enum`, with its links written two ways:

- **`*_enum_ref.goose`** links with plain 8-byte references (`Tree&`), in
  the same local pools as the struct port.
- **`*_enum_pool.goose`** links with 4-byte pool-relative references
  (`Tree&<u32 in pool>`).

Goose rejects a fixed-mode enum holding self-relative links, because a copy
does not keep them (its spec §3.5, §3.9). A pool-relative link names a global
pool in its type, so these ports keep two enums over two global pools: the
long-lived tree and the scratch trees, or the original and the copies. They
drop a tree by emptying its pool (`pool = []`).

`run.py` runs these as the `goose-enum-ref` and `goose-enum-pool` columns.
Every form prints the expected output.

Instruction counts are from callgrind at the full sizes. Bytes per node is
the growth in peak RSS from one depth to the next, divided by the nodes
added, per tree alive. Wall time is the median of 9 runs.

| treecopy | wall | instructions | bytes/node |
| --- | --- | --- | --- |
| zane | 0.167 s | 749 M | 27.9 |
| goose (struct, self-relative u32) | 0.126 s | 845 M | 16.0 |
| goose-enum-ref (enum, 8-byte refs) | 0.156 s | 579 M | 25.2 |
| goose-enum-pool (enum, pool-relative u32) | 0.112 s | 515 M | 17.0 |

| binarytrees | wall | instructions |
| --- | --- | --- |
| zane | 0.117 s | 866 M |
| goose (struct) | 0.052 s | 659 M |
| goose-enum-ref | 0.060 s | 476 M |
| goose-enum-pool | 0.046 s | 528 M |

What this shows:

- **The struct ports did not flatter Goose.** Its enums run fewer
  instructions than its struct ports: one tag match against two null
  checks. With 4-byte links the enum is as dense as the struct (17 against
  16 bytes/node) and at least as fast.
- **On treecopy, link width accounts for the whole gap.** With 8-byte
  references, Goose's enum has nearly Zane's density (25.2 against 27.9
  bytes/node) and nearly Zane's time, while running fewer instructions.
  Narrowing the links to 4 bytes is what takes Goose from Zane's time to
  well below it.
- **On binarytrees, something besides link width matters.** Every Goose
  form stays at about half Zane's time, the 8-byte form included. Its peak
  RSS barely rises above the process baseline, while Zane's measured
  108 bytes/node. So the gap there sits in how Zane holds the many
  short-lived trees, not in the node encoding.

## What remains

| test | Zane ÷ Goose (wall) | what accounts for it |
| --- | --- | --- |
| binarytrees | ~2.2× | Zane executes 1.3× Goose's instructions. The rest is memory: Goose's nodes are 4-byte links in one pool. |
| ntree | ~1.6× | Zane executes 1.8× Goose's instructions and uses 1.4× its memory: a 24-byte list handle per node, plus each node's separate block. |
| treecopy | ~1.7× | Zane executes **fewer** instructions than Goose, so the gap is memory traffic: 30 MB against 18 MB, 8-byte pointers against 4-byte links. |
| allocfree | ~1.0× | Closed. |
| listgrowth | ~0.9× | Closed. |

What is left is mostly representation: link width, handle size, and whether
a tree's nodes sit in one pool or in separate blocks. The allocator's own
paths account for little of it.
