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

## Pooled variants (prototype, behind `ZANE_POOLED_VARIANTS=1`)

The Goose enum ports showed that most of treecopy's gap is link width and
node placement. This step tries Goose's representation in Zane: a recursive
variant's whole tree in one pool, with 32-bit links.

### Design

- **Which types.** A variant one of whose cases holds a boxed payload, that is
  a recursive variant (`Type_layout.pooled`). The struct inside the cycle
  (`Pair`, `Branch`) stops being boxed: its members of the variant's type
  are links inside the node.
- **The root** is an ordinary 24-byte list handle `{items, count, room}`
  over bytes. Its block holds the nodes, all one size, in post-order, so the
  root is the last node.
- **A node** is the variant's sum with its payload inline. Each member of the
  variant's own type is an `i32` offset from the link to the node it names.
  The offset is self-relative, so moving or copying a pool with `memcpy`
  keeps every link valid. This is the thing Goose rejects in a fixed-mode
  enum, and Zane can allow it because a variant's nodes are roaming: nothing
  outside the pool references them (memory.md §2.1, §2.8.1).
- **Building into a destination.** This extends lowering's rule L7 (a
  result is written into a destination its caller names) from a value's
  slot to the pool its nodes go in. A function that returns a pooled
  variant, and is neither written out where it is called nor able to abort
  or exit (`Lower_calls.pours`), takes one more parameter: the address of
  the pool to build its result in. It returns the offset of the result's
  top node there.
  - `return Tree.node(Pair(make(…), make(…)))` lowers through `Lower.into`.
    Each subtree goes into the same pool: a call to such a function is
    passed the pool, and a case is built the same way recursively. Then
    `zane_pool_push` appends the node and writes its links from the
    subtrees' offsets.
  - A payload made by a field constructor whose body returns its parameters
    as fields, such as `Pair` or `Branch`, is seen through, so its
    arguments are built into the pool directly.
  - Anything else of a pooled type is made as a value in a pool of its own
    and copied on (`zane_pool_append`). The links are relative, so that is
    one `memcpy`.
  - Where a pooled value is wanted as a value, as in `check(make(d))`, the
    caller makes a fresh pool (`zane_pool_new`, in its own region) and
    passes that.
  - The push inlines into the caller, with its slow path
    (`zane_pool_reserve`, which doubles the block) out of line.
  - Nodes stay in post-order, children before the parent. A pre-order
    layout, with the parent's node as the call's result slot, fits L7's
    wording more closely, but it would need a reserve and then a write per
    node, where post-order needs one push.
- **Reading.** A borrowed parameter of a pooled type is a pointer to its node
  (`zane_pool_root`), and `match` follows links with `zane_link`. A field
  constructor that returns a parameter as a field takes it whole instead
  (`Verbs.stored`), so a temporary moves into the new node rather than
  being copied out of a view at every level.
- **Copying a whole tree** is the list's copy: one `memcpy` of the pool.
  Copying a subtree out of a node (`zane_pool_copy`) walks it.
- **Oversized held blocks** come from a warm span reservation
  (`zane_alloc_held` → `zane_alloc_growable`), which also applies outside
  the experiment. Before this change, a 12 MB copy made every round mapped
  fresh pages and faulted them in. `tests/runtime/growth.c` now expects a
  copy's oversized block to grow in place.

Limits, refused with a diagnostic where they apply:

- at most four links per node, in the first four cases;
- nodes of at most 64 bytes (256 before packed nodes, below);
- no owned block (string, list) in a node;
- no other pooled type in a node;
- no borrowed parameter whose type is the cycle's struct;
- no reading a pooled subtree out as a value;
- no function value that returns a pooled variant (a direct call takes the
  extra parameter, a call through a value would not).

In addition:

- `zane_pool_copy` recurses.
- A pool past 2 GiB aborts, when it grows past that (`zane_pool_reserve`).
- A spawned call to a function that pours its result is not handled.

### Results

These were measured at the full sizes (depth 16 and 18) by `variants.py`,
which builds every row it reports and checks each against `tests.py`. Unlike
the earlier sections, the Zane rows here and in the partial inlining section
come from this branch's own zanec, against `core` at the version the branch
builds with, so their `zane` row is that compiler with both switches off,
not v0.20. Wall time is the median of 9 runs; instruction counts are from
callgrind. Bytes per node is measured as in the enum section. Every build prints the expected output at
the check, mid and full sizes. "First cut" is the version that built each
subtree as a pool of its own and merged the children's pools into the
parent's (`zane_pool_node`, now removed).

| treecopy | wall | user | faults | instructions | bytes/node |
| --- | --- | --- | --- | --- | --- |
| zane | 0.142 s | 0.122 s | 7.4k | 749 M | 27.9 |
| zane, pooled, first cut | 0.112 s | 0.071 s | 15.3k | 243 M | 40.3 |
| **zane, pooled** | **0.091 s** | **0.071 s** | 6.6k | **174 M** | 23.9 |
| goose (struct) | 0.127 s | 0.114 s | 4.4k | 845 M | 16.0 |
| goose-enum-pool | 0.122 s | 0.105 s | 4.6k | 515 M | 17.0 |

| binarytrees | wall | user | faults | instructions | bytes/node |
| --- | --- | --- | --- | --- | --- |
| zane | 0.112 s | 0.104 s | 3.4k | 866 M | 74.5 |
| zane, pooled, first cut | 0.212 s | 0.178 s | 12.1k | 2177 M | 238 |
| zane, pooled | 0.110 s | 0.099 s | 2.8k | 655 M | 35.4 |
| goose (struct) | 0.052 s | 0.045 s | 1.0k | 659 M | 0 |
| goose-enum-pool | 0.046 s | 0.041 s | 1.1k | 528 M | 0 |

What this shows:

- **treecopy: pooling wins outright.** Each round's copy is one `memcpy`,
  and the build writes each node once, so the program runs a third of
  Zane's instructions and a third of Goose's. It is the fastest form, on
  the least user time. Its nodes are 24 bytes, against Goose's 17, because
  the 4-byte tag is padded to the `Int`'s alignment.
- **binarytrees: the build is now as tight as Goose's, the time is not.**
  `make` compiles to a bump, a tag store and two 4-byte link stores per
  node, with no runtime call. Pooled Zane runs fewer instructions than
  Goose's struct port, but takes 2.4 times its time at every depth from
  12 to 20. Branch mispredictions are lower than Goose's. The container
  exposes no hardware counters, so `pooled_emulation.c` here replays both
  shapes in plain C (clang -O2, user time at depth 16):

  | form | user |
  | --- | --- |
  | Zane's shape: 16-byte nodes, every node a call | 0.108 s |
  | leaves built inline in their parent's `make` | 0.063 s |
  | and 9-byte packed nodes, as Goose's | 0.059 s |
  | Goose itself | 0.041 s |

  Zane's shape in plain C runs as slowly as Zane does, so the code Zane
  emits is not the problem. Goose's own compiler peels one level of the
  recursion: a child of depth 0 is built in its parent's `make` with no
  call, which skips the call for half the nodes. That is most of the gap.
  The rest comes from:
  - Goose's packed 9-byte nodes, a 1-byte tag and unaligned links;
  - Goose having no room check, since its pools sit on reserved data
    stacks.
- **Fixes along the way**, from the first cut's 5.7 G instructions on
  binarytrees:
  - stopping the per-level relocation of the pool on return (Regions);
  - passing a field constructor's parameters whole;
  - warm reservations for big copies;
  - building into the destination pool, which removed every merge and
    chunk-boundary copy;
  - keeping the push's slow path out of line, so the push inlines.

## Partial inlining (prototype, behind `ZANE_PARTIAL_INLINE=1`)

The C replay above put most of binarytrees' remaining gap on one call per
leaf, which Goose's compiler avoids by building a depth-0 child in its
parent's `make`. LLVM never inlines a function into itself, and its own
partial inliner (`partial-inliner`, not part of `-O2`) leaves a
self-recursive call alone: tried in front of the pipeline, it changed no
instruction. So `lib/optimize/peel.ml` does it in stage 5, over the CGT,
before folding.

### Design

- **The copy.** For each function, the pass makes a copy of its body with
  every costly part replaced by a jump to the call:
  - an arm of a branch or a switch that calls anything, loops, or opens a
    scope;
  - a statement that does, from there to the end of its list, unless the
    statement's value is an expansion, whose body is cut the same way.
- **What a copy may keep.** It keeps nothing the call would do again: an
  effect, such as a pool push, is allowed only inside a value the copy
  returns, which ends it. It may not allocate a box, copy, take or escape
  a value, or open a scope. It must have at most 48 nodes, and some arm
  must get out without jumping to the call.
- **The rewrite.** Every call to a function with a copy, from any function,
  that function itself included, becomes:
  1. bind the arguments, once;
  2. run the copy, in which each `return v` stores `v` and leaves;
  3. if the copy jumped out, make the original call with the same
     arguments.
- **One level only.** A copy keeps no calls, so the rewrite happens once,
  however the functions call each other.
- **Two examples.**
  - `make(depth - 1)` becomes "if `depth - 1` is 0, push a leaf here, else
    call".
  - `check(p.left)` becomes "if `p.left` is a leaf, the count is 1, else
    call".

It is the general mechanism the discussion arrived at, partial inlining,
not a binarytrees special case. It changes the optimized code of 20 of the
64 codegen fixtures (`tests/codegen/fixtures`), and all 20 print their
expected output with it on. `just test-compiler` passes with it off; dune
does not pass the variable to its actions, so the suite cannot be run with
it on.

### Results

Measured as above with `variants.py`, depth 16 and 18. "pooled" is
`ZANE_POOLED_VARIANTS=1`, "peel" is `ZANE_PARTIAL_INLINE=1`. Wall time in
this container moved by up to 2× between sessions (plain Zane's treecopy
went from 0.142 s to 0.260 s with nothing changed), so compare rows within
this table only.

| binarytrees | wall | user | instructions | bytes/node |
| --- | --- | --- | --- | --- |
| zane | 0.119 s | 0.106 s | 866 M | 72.9 |
| zane, peel | 0.116 s | 0.109 s | 886 M | 72.8 |
| zane, pooled | 0.097 s | 0.091 s | 655 M | 35.9 |
| **zane, pooled, peel** | **0.081 s** | **0.068 s** | **523 M** | 35.7 |
| goose (struct) | 0.049 s | 0.044 s | 659 M | 0 |
| goose-enum-pool | 0.050 s | 0.044 s | 528 M | 0 |

| treecopy | wall | user | instructions | bytes/node |
| --- | --- | --- | --- | --- |
| zane | 0.260 s | 0.237 s | 749 M | 28.0 |
| zane, peel | 0.252 s | 0.231 s | 760 M | 28.3 |
| zane, pooled | 0.100 s | 0.086 s | 174 M | 24.2 |
| zane, pooled, peel | 0.096 s | 0.078 s | 179 M | 24.0 |
| goose (struct) | 0.129 s | 0.113 s | 845 M | 16.1 |
| goose-enum-pool | 0.113 s | 0.103 s | 515 M | 17.0 |

What this shows:

- **Pooled binarytrees gains a quarter of its user time** (0.091 s →
  0.068 s), and now runs Goose's instruction count. That is what the C
  replay predicted for building leaves in their parent (0.108 s → 0.063 s
  there). It is still 1.5× Goose. The replay puts the rest on:
  - Goose's 9-byte packed nodes, against 16 bytes;
  - Goose's pushes, which skip the room check;
  - the pool's count, which Zane loads and stores through memory at every
    push.
- **`make` is where the time goes; `check` costs instructions.** `make`
  drops from 484 M to 333 M instructions. `check` rises from 118 M to
  144 M: where its child is not a leaf, the tag test runs twice, once in
  the copy and once in the call. Calls it saves still make it a net gain
  in time.
- **Without pools, nothing changes.** Plain Zane's leaf is a boxed value
  made in the callee's scope and escaped to the caller. The copy may not
  allocate or escape, so `make` is not peeled, and `check`'s gain is lost
  in noise. Building into the caller's destination is what makes the base
  case cheap enough to copy. The same would hold for any value that owns a
  block.
- **treecopy barely moves,** since its time is in the copy and the walk,
  not in calls.

## Packed nodes and the room check

The partial inlining results left three things between pooled binarytrees
and Goose: 16-byte nodes against Goose's 9, a room check on every push, and
the pool's count kept in memory. This step takes on the first two.

### The room check, in the C replay

Before changing Zane, `pooled_emulation.c` got two more switches:
`NO_CHECK=1` drops the check (the pool is made big enough once, as on a
data stack), and `ON_RETURN=1` replaces it with one check per call, where
`make` returns, leaving room for the three nodes the next frame may push.
All rows build leaves in their parent (`INLINE_LEAF=1`). Instructions are
from callgrind at depth 16, user time is the least of 15 runs at depth 18,
over three rounds:

| form | instructions | user, depth 18 |
| --- | --- | --- |
| 16-byte nodes, check per push | 472 M | 0.230–0.248 s |
| 16-byte nodes, check per return | 412 M | 0.214–0.232 s |
| 16-byte nodes, no check | 393 M | 0.210–0.237 s |
| **9-byte nodes, check per push** | 472 M | **0.175–0.180 s** |
| 9-byte nodes, check per return | 420 M | 0.215–0.234 s |
| 9-byte nodes, no check | 401 M | 0.224–0.232 s |

- **Packing is the gain.** With the check where it is, 9-byte nodes take
  a quarter less time at the same instruction count.
- **The check costs instructions, not time.** Dropping it saves 15% of the
  instructions and, with 16-byte nodes, no measurable time. Its branch
  always goes the same way, and the count and room it reads are in cache.
- **With packed nodes, dropping it is slower,** in every round, though the
  compiled `make` is as tight as before: it keeps the count in a register
  between pushes and stores it once. The container has no hardware
  counters, so why is unknown.

So the room check stays. What Zane's own `make` had besides it was a
range check on every link (two compares and branches per node) and a store
of a zeroed payload, which the links then overwrote.

### Design

- **`ZANE_PACKED_NODES=1`**, with pooled variants, makes a node's sum and
  the payload struct inside it packed: no padding, alignment 1, the tag one
  byte, the payload right after it. A binarytrees node is 9 bytes, a
  treecopy node 17.
- **A CGT type, `Packed`,** wraps the sum or struct (`lib/cgt/nodes.ml`).
  Its members keep their own layouts. Codegen gives it an LLVM packed
  struct, `{i8, [n x i8]}` for a sum, and a 1-byte tag for `Case` and
  `Switch`.
- **Unaligned access.** An address inside a packed type is named `packed`
  where codegen builds it (`Offset`, `Case`, `Payload`), and so is any
  address inside one. Once a function is emitted, every load and store
  through such an address gets alignment 1 (`Emit.unaligned`). In the
  runtime, a link is read and written with `memcpy`. The marking follows
  addresses within one expression, not through a local: a payload that is
  neither a link nor the cycle's struct, such as an `Int` case, is bound
  in a `match` as an address kept in a local, and a read through it keeps
  its type's alignment. x86-64 and AArch64 load such a scalar from any
  byte, but LLVM may assume the alignment. Neither benchmark has such a
  payload.
- **The runtime's masks** for copying a subtree now mark the byte each link
  starts at, not a 4-byte word, so a node is at most 64 bytes. The runtime
  reads a tag as its node's first byte, which is the whole tag of a packed
  node and the low byte of a 4-byte one.
- **The 2 GiB check moved** from every link to the slow path: a pool may not
  grow past `INT32_MAX` bytes (`zane_pool_reserve`), so no link in it can
  be out of range. The zeroed payload's store then goes too, since nothing
  between it and the links' stores can branch away.

### Found on the way

Building every codegen fixture with pooled variants on, with and without
packing, and comparing each against the plain build's output under
`ZANE_CHECK=1` (`fixtures.sh` here), showed two bugs in the pooled prototype that the earlier
steps had not caught: four fixtures (`folding`, `keeping`, `replayed`,
`spawns`) failed with pooled variants alone.

- **A `mut` method's subject was taken as a node.** `Verbs.viewed` passed
  `this` of a `mut` method on a pooled variant as the address of its node.
  The caller passes the address of its handle instead, which the method
  writes a new root into. Reading the handle as a node misread its tag.
  With 4-byte tags, the low half of a pointer was almost never a case
  number, so it read as a leaf and went unnoticed. A 1-byte tag made it
  crash, depending on where ASLR put the block. `viewed` now leaves a `mut`
  subject alone.
- **A pool moved into another stayed out.** Where a pooled value is not
  built in place, `into` makes it and copies its pool onto the destination
  (`zane_pool_append`). The source's block was then never given back, which
  `ZANE_CHECK=1` reports as "a dynamic block outlived its owner". The
  append now consumes its source. It does not free the block, which may be
  in a frame. It stops counting it as out, and the block's region reclaims
  it when it drains.

With both fixed, the 5 fixtures the switches change and still compile
match the plain build, under all three switches together too, 20 runs
each for the four that failed. `arrays`, `boxes` and `walks` stay refused,
as before. `just test-compiler` passes with the switches off.

### Results

Measured with `variants.py` as before (depth 16 and 18, 9 runs, every build
checked against `tests.py`). The pooled rows include the moved range check
and the fixes above, so they are not the earlier tables' rows. Their
instruction counts dropped by 44 M on binarytrees: the range check.

| binarytrees | wall | user | faults | instructions |
| --- | --- | --- | --- | --- |
| zane | 0.105 s | 0.094 s | 3.3k | 866 M |
| zane, pooled | 0.104 s | 0.095 s | 2.8k | 611 M |
| zane, pooled, packed | 0.104 s | 0.097 s | 1.9k | 611 M |
| zane, pooled, peel | 0.077 s | 0.068 s | 2.8k | 480 M |
| **zane, pooled, peel, packed** | **0.074 s** | **0.067 s** | 1.9k | 480 M |
| goose (struct) | 0.054 s | 0.047 s | 1.0k | 659 M |
| goose-enum-pool | 0.046 s | 0.042 s | 1.1k | 528 M |

| treecopy | wall | user | faults | instructions | bytes/node |
| --- | --- | --- | --- | --- | --- |
| zane | 0.159 s | 0.133 s | 7.4k | 749 M | 28.0 |
| zane, pooled | 0.090 s | 0.072 s | 6.6k | 173 M | 23.9 |
| **zane, pooled, packed** | **0.067 s** | **0.052 s** | 4.8k | 179 M | **17.2** |
| zane, pooled, peel, packed | 0.067 s | 0.058 s | 4.8k | 186 M | 16.9 |
| goose (struct) | 0.117 s | 0.102 s | 4.4k | 845 M | 16.0 |
| goose-enum-pool | 0.114 s | 0.099 s | 4.6k | 515 M | 17.0 |

What this shows:

- **treecopy: packing takes a quarter off.** Nodes are 17 bytes, Goose's
  size, and a copy moves 30% fewer bytes. Pooled and packed, Zane runs
  treecopy in 0.59 of Goose's time.
- **binarytrees: packing changes almost nothing.** Pooled and peeled, it
  saves a third of the page faults and a few percent of the time. `make`
  now compiles to what the replay's fastest form compiles to: a 1-byte tag
  store, two unaligned link stores, one room check per node. `check`
  compiles to a 1-byte tag compare and unaligned link loads, two levels
  peeled. Zane runs fewer instructions than Goose's pool port (480 M
  against 528 M), and callgrind's cache simulation gives it about the same
  misses (2.2 M first-level against Goose's 1.9 M). Yet it takes 1.6
  times Goose's time.
- **How pools are made looked like the rest.** The replay reuses one pool
  for every tree, and Goose's data stack does the same. Zane makes a fresh
  pool for each `check(make(d))`, starting at 64 bytes and doubling as the
  tree grows. The replay's `FRESH=64` switch does that with `malloc` and
  `realloc`, and its time goes from 0.032–0.037 s to 0.040–0.049 s at
  depth 16, against Zane's 0.045–0.053 s in the same runs. The next step
  tried it in Zane and found otherwise: see "Pool reuse".

## Pool reuse (prototype, behind `ZANE_POOL_REUSE=1` at run time)

The packed nodes step put binarytrees' remaining gap on Zane making a fresh
pool for each tree and growing it by doubling, where the replay and Goose
reuse one. This step tries reuse in Zane.

### Design

- **A size hint.** Each thread remembers the largest room a pool has grown
  to, up to a chunk (`zane_pool_hint`, `runtime/list.c`). With
  `ZANE_POOL_REUSE=1` in the environment, `zane_pool_new` makes a new pool
  that large at once, so a loop building trees of one depth grows its pool
  once, on the first tree.
- **The memory was already reused.** A new pool's block is at its region's
  frontier. Each iteration's region drains before the next opens, so the
  next pool's block is the same memory. A gdb breakpoint on
  `zane_pool_new` at depth 10 showed 3 distinct addresses over 400 pools:
  every pool after the first two starts at the same byte.
- It is a run-time switch, so one binary is measured both ways
  (`reuse_ab.py`).

### Results

binarytrees, pooled, peeled and packed, one binary:

| | growth calls | instructions | user, depth 16 (least / median) | user, depth 18 (least / median) |
| --- | --- | --- | --- | --- |
| reuse off | 232,957 | 483 M | 0.058 / 0.066 s | 0.247 / 0.299 s |
| reuse on | 49 | 480 M | 0.050 / 0.064 s | 0.237 / 0.297 s |

The growth calls go, and so do the 19 M instructions they ran, but
`zane_pool_new` gains 9 M making the larger blocks. The time does not
move beyond noise, at either depth. treecopy, which builds two trees and
copies them, does not move either (median 0.051 s off, 0.052 s on, at
depth 18).

So growing a pool was not the cost: it grew in place at the frontier, in
memory that stayed warm. The replay's `FRESH=64` was slower for a reason
Zane does not share: glibc's `realloc` serves a block past 128 KiB with
`mmap`, so its large trees touch fresh pages every time.

### Where the time is, then

The gap to the replay grows with the tree: at depths 12 to 20, Zane takes
1.25–1.45 times the replay's user time and 1.5–1.6 times Goose's. It is a
cost per node. Ruled out, each with the same binaries:

- **Instructions and simulated caches.** Zane runs the replay's instruction
  count (480 M against 472 M at depth 16). Per function, callgrind's cache
  simulation gives `make` and `check` the same first-level misses as the
  replay's.
- **`check` as a loop.** Goose's compiled `check` loops over each right
  child and calls only for the left. The replay with `CHECK_LOOP=1` does
  the same and takes the same time.
- **Address layout.** Runs with randomization off (`setarch -R`) take the
  same time.
- **The handle next to the pool.** Zane's pool handle is in a frame, and
  the pool's block can be cut from the same frame. The replay with its
  handle right before the pool's bytes takes the same time.
- **Huge pages and signals.** None of the three gets transparent huge
  pages (`madvise` mode). Zane commits frames from a SIGSEGV handler, but
  takes 2 signals and 46 `mprotect` calls in a whole run.

Sampling with gdb at depth 22 (`sample.sh`) puts the gap in `make`:

| | samples in `make` | in `check` |
| --- | --- | --- |
| zane | 70 (78%) | 17 (19%) |
| replay | 42 (68%) | 20 (32%) |

With Zane's total 1.4 times the replay's, its `make` takes about 1.6 times
as long, and its `check` the same. The two `make`s are the same
instructions in the same order. The samples in Zane's cluster just after
its stores into the pool, and around the loads of the pool handle's count
and items that follow. What makes those slower in Zane is something the
simulator does not model, such as store forwarding, memory disambiguation
or the TLB. Telling which needs hardware counters, which this container
does not have. `perf stat -e cycles,instructions,dTLB-load-misses,ld_blocks.store_forward`
on both binaries, on a machine that has them, is the next measurement.

## What Goose's documentation says

Goose's release ships its specification (`docs/goose_spec.md`) and its
compiler's implementation notes (`docs/implementation.md`). Read against
the remaining binarytrees gap, they describe a push unlike Zane's in three
ways, and two techniques Zane already has or does not need.

### The push

- **No capacity check, by construction.** Each data stack holds at most one
  growable value, always the topmost one, and "growth is a pointer bump; no
  capacity checks are emitted (address space is pre-reserved; guard pages
  catch pathological overflow and abort safely)" (spec §1.3). A stack is a
  2 GB reservation, writable with overcommit on POSIX, with an unmapped gap
  after it (implementation §7, "Data stacks"; spec C.4). A push is
  `*(T*)S.top = e; S.top += size; h.len++` (spec C.1).
- **The top in a register.** "A stack the function can name keeps its top
  in a local where the function grows it, synchronized with memory only
  where something else can observe it: flushed before and reloaded after
  calls that can reach the stack, and flushed at every exit"
  (implementation §6.10, "Tops"), and the count with it ("Counts"). The
  notes give the reason Zane's push reloads: "the C backend reloads both at
  every access since any byte store may alias the header". Zane's `make`
  stores the count after each push and reloads the handle's items and room
  before the next, since its node stores are byte stores that may alias
  the handle.
- **The top is a global.** A stack's control block is a global (spec C.1),
  so `make` takes no destination argument. Zane passes the pool's handle
  by address.

In Goose's compiled `make`, a frame that builds two leaves and their parent
loads the top once, writes all 27 bytes, and stores the top and the count
once. In Zane's, it does three pushes, each with a room check, a reload of
the items pointer and a store of the count.

- **Links from a base** (`in pool`, spec C.2, implementation §6.7) load as
  `base + off` with the base in a register, where Zane's self-relative
  links add to the link's own address. The notes measure no difference on
  a structure built once and walked (§9.5), and neither does the replay
  below.
- **Base-case inlining** (§9.6) is what partial inlining does here.
- **`1 + f(l) + f(r)` loses its right spine** (§9.6): Goose's `check` loops
  over right children. The replay's `CHECK_LOOP=1` showed no gain from it.

### Measured

`goose_shape.c` replays binarytrees in Goose's shape: a global top kept in
a register through each frame, no capacity check, 9-byte nodes, leaves in
their parent, in a writable reservation; `SELF=1` makes its links
self-relative. User time at depth 18, least and median of 9, alternating:

| form | least | median |
| --- | --- | --- |
| replay, Zane's push (`INLINE_LEAF=1`, 9-byte nodes, malloc) | 0.187 s | 0.209 s |
| replay, Goose's shape, links from the base | 0.168 s | 0.177 s |
| replay, Goose's shape, self-relative links | 0.168 s | 0.192 s |
| goose-enum-pool | 0.192 s | 0.203 s |
| zane, pooled, peel, packed | 0.266 s | 0.290 s |

The replay in Goose's shape runs as fast as Goose, with either kind of
link. Zane's push costs the replay 10–20% against it. That is what the
documentation's push accounts for.

It does not account for Zane being slower than the replay of its own push.
Two more things were tried for that, and neither settles it:

- **The memory.** `pooled_emulation.c` with `MAP=1` puts its pools in an
  `mmap` reservation that is writable from the start, at `OFFSET` bytes
  into the page, and with `MAP=2` in one reserved inaccessible and made
  writable with `mprotect`, as Zane's runtime commits memory. In one
  session, the second was 15–20% slower than the first, and an offset of 0
  slower than 16. In the next, with the same code, the first was as slow as
  the second (0.241 s least, against 0.187 s from `malloc`). In this VM,
  where a replay's memory lies moves its time by up to 25% between builds,
  and no setting reproducibly explains it.
- **Zane with writable reservations.** A trial run-time switch that made
  every Zane reservation writable at once, as Goose's are, keeping only the
  context guard inaccessible, changed every large mapping to `rw-p` and
  left the time where it was (median 0.308 s off, 0.311 s on, depth 18).
  It was not kept.

So the part of the gap Goose's design explains is the push: its top in a
register through a frame, with no capacity check. Bringing Zane's push to
that shape is the next prototype. The rest is below what this container
can measure.

## Goose's push shape (prototype, behind `ZANE_POOL_REGISTERS=1` and `ZANE_POOL_UNCHECKED=1`)

The replay above runs as fast as Goose once its push has Goose's shape:
the pool's top and count in registers through a frame, and no capacity
check. This step builds that shape in Zane. Both switches are read by the
compiler, so they take effect at build time.

### Design

- **`ZANE_POOL_REGISTERS=1`** (`lib/codegen/pool_cache.ml`, hooked into
  `emit.ml`). A function that builds into a pool it is given (a pointer
  parameter some push builds into, and the locals bound to it, used only
  as arguments) keeps the pool's items, count and room in slots of its own,
  which LLVM promotes to registers. Each push is inline: compare the new
  count against the room, with a slow path that writes the count back,
  calls `zane_pool_reserve` and reads all three again; then a `memcpy` of
  the node, its links as 4-byte self-relative stores, and the new count in
  its slot. The count goes back to the pool before a call or runtime
  function is handed the pool and at every return, and all three are read
  again after such a call. This is Goose's "Tops"/"Counts" caching
  (implementation notes §6.10), with the same reason for flushing: a node
  store may alias the pool's handle.
- **`ZANE_POOL_UNCHECKED=1`** (implies the first) drops the room check.
  `Pool_new` becomes `zane_pool_new_unbounded` (`runtime/list.c`), whose
  block comes from `zane_alloc_unbounded` (`runtime/arena.c`): a 2 GiB
  reservation that the runtime's fault handler commits as it is touched,
  kept as a span after the pool dies so the next pool reuses it. The
  pool's room is `INT32_MAX` less a line, the cap pools already have, so no
  push can pass it and its links stay in range. This is Goose's data stack
  (specification §1.3, C.4): a reservation whose growth is never checked.
- Both runtime functions are declared to `Cgt.Runtime`, and classified as
  inputs as the other pooled-variant functions are.

The compiled unchecked `make` has Goose's shape: one load of the count,
the node stores, and one store of the count per frame.

### Correctness

`fixtures.sh` runs the codegen fixtures with pooled variants under
`ZANE_CHECK=1`, plain and with each switch: every affected fixture gives
the same output. `stress/main.zn` builds and folds an `Expr` variant with
nested pools, appends and copies; it gives the same result (`571557 31802
136097 853`) under six combinations of the switches. With registers on, the
IR of binarytrees has no `zane_pool_push` call left.

### Results

`variants.py` (RUNS=9; medians at binarytrees depth 16 and treecopy depth
18, instructions from callgrind), checked against langbench's expected output first:

| variant | binarytrees user | instructions | faults | treecopy user | instructions |
| --- | --- | --- | --- | --- | --- |
| zane, pooled, peel, packed | 0.064 s | 483 M | 1885 | 0.048 s | 186 M |
| + registers | 0.057 s | 476 M | 1885 | 0.054 s | 186 M |
| + unchecked | 0.051 s | 389 M | 1441 | 0.052 s | 185 M |
| goose | 0.043 s | 659 M | 1038 | 0.104 s | 845 M |
| goose-enum-pool | 0.041 s | 528 M | 1136 | 0.100 s | 515 M |

`many.py`, the same builds interleaved, user time at depth 18 (least /
median of 9):

| build | binarytrees |
| --- | --- |
| zane, pooled, peel, packed | 0.241 / 0.306 s |
| + registers | 0.229 / 0.274 s |
| + unchecked | 0.224 / 0.257 s |
| replay in Goose's shape (`goose_shape.c`) | 0.143 / 0.176 s |
| goose-enum-pool | 0.154 / 0.197 s |

- **binarytrees moves about a fifth closer.** Registers take the push off
  the runtime call and save the reload of items and room after each node
  store; dropping the check removes 18% of the instructions. Zane now runs
  fewer instructions than either Goose port, by a quarter.
- **It is still 1.2–1.3× Goose** where the replay of the same push shape
  matched Goose. What the replay does not do is the per-tree work below.
- **treecopy does not move**, within noise: its pools are made once and
  copied whole, so it pushes little.

### What is left of the gap

With the push in Goose's shape, the remaining difference is around it.
Callgrind at depth 16 puts about 21 M instructions in the runtime per tree
that Goose does not run: `zane_unmap` 6.7 M, `zane_pool_new_unbounded`
5.8 M, `zane_scope_drain` 4.6 M, `zane_page` 4.0 M. Each tree makes its own
pool and returns its block when it dies; Goose resets one global stack.

A trial that took the unbounded pool's reservation directly from `mmap`,
writable from the start, was inconclusive (median 0.256 s against 0.230 s,
least 0.204 s against 0.211 s) and was not kept.

## Why Goose's `make` is faster: the handle's address

After Goose's push shape, binarytrees was still 1.2–1.3× Goose. This step
finds the rest by hand, from both compilers' output: Goose writes C
(`goose bt.goose -O2 -o bt.c`, and `goose --emit-runtime rt.c` for its
runtime), and Zane's IR (`zanec --ll`) builds with clang beside the
runtime's `zane.c`, timing the same as `zanec --build` (0.198 / 0.257 s
against 0.205 / 0.258 s at depth 18). Both can then be edited and rebuilt.

### Where the time goes

Cycle counters (`__builtin_readcyclecounter`) around the `make` call of
each short-lived tree, over a depth-18 run:

| | `make` | everything else |
| --- | --- | --- |
| Zane | ~340 M cycles | ~230 M cycles |
| Goose | ~200 M cycles | ~210 M cycles |

The gap is in `make`, and at every depth alike, about 1.6×: at depth 4,
where a tree is 279 bytes and never leaves L1, as at depth 18. So it is not
memory. Callgrind's simulated caches agree (the same D1 misses), neither
program makes a system call per tree, neither has huge pages, and both
reuse the same memory for each tree.

### Same code, different chain

The two compiled `make`s are the same instructions, Zane's a few fewer.
The difference is where the pool's top lives:

- Goose's is a global, read as `mov G(%rip)`: a constant address.
- Zane's is behind the handle pointer `make` is given. Kept across the
  recursive calls, the pointer sits in a callee-saved register (`rbx`),
  which each callee pushes and pops.

After a call, the caller reads the count through `rbx`. The callee has
just stored that count, and has just restored `rbx` with a `pop`, which is
itself a load forwarded from a store. So each frame's count load waits on
two store-to-load forwards in a row where Goose's waits on one, and that
chain runs through every frame of the build.

### The harness

`push-latency/` times `make` alone, in cycles per node, from the same
mapping. `rh.c` drives Goose's `make` (`gmake.c`, written from its C), the
variants in `gvar.c` and `rvar.c`, and Zane's own compiled `make`, taken
from the IR by `rewrite.py`:

```sh
python3 rewrite.py zane.ll
clang -O2 rh.c rvar.c gvar.c gmake.c make.ll -o rh
./rh 0 8 200000   # 0 goose, 1 goose by pointer, 5 pointer handed back, 6 count in registers, 7 zane
```

| variant | depth 4 | depth 8 | depth 16 |
| --- | --- | --- | --- |
| Goose (global top) | 2.87 | 2.85–2.95 | 2.89 |
| Goose, its stack passed by pointer | 4.59 | 4.19–4.23 | 3.28 |
| by pointer, handed back in a register with the result | 2.82 | 2.42–3.32 | 2.33 |
| Zane's shape, items and count in registers, the count returned | 2.64 | 2.70–3.10 | 2.46 |
| Zane's compiled `make` | 4.88 | 4.78–5.13 | 5.20 |

Passing Goose's own `make` its stack by pointer is all it takes to make it
as slow as Zane's. Every other difference was tried in `gvar.c` (the
`d == 0` case, the stores before the calls, links from a base or
self-relative, a top pointer or items plus count) and none of them
matters.

### In the program

`rewrite.py` also writes `global.ll`, binarytrees with `make` reaching its
pool through a global, the handle copied in before each call and back out
after. User time at depth 18, least / median of 11, interleaved:

| build | binarytrees |
| --- | --- |
| Zane, from its IR | 0.198 / 0.257 s |
| Zane, `make`'s pool in a global | 0.155 / 0.192 s |
| Goose | 0.156 / 0.186 s |

That closes the gap. What Goose does differently in binarytrees is that its
pool's address is a constant. The per-tree runtime work named in the step
before costs little next to it.

A global is Goose's answer, and it only works for a pool that a
whole program shares. A pooled value in Zane has a pool of its own, so the
fix that fits is the harness's other two: hand the pool back in a register
with the result, or pass items and count as arguments and return the new
count, so that the count never goes through memory. The second is faster
than Goose in the harness.

## The whole suite again, with every step

`run.py` once more over every test (RUNS=7, median wall time; peak RSS where
it differs), with this branch's `zanec` and the `core` at its language
version. The suite's sources are written for its pinned v0.20 release, so
six of them no longer build; `langbench-current-language.patch` brings a
copy up to the current language (a growable list of a reference type is a
`ListRef`, a `List` is a value and takes no `^`, a declaration ending in
`=>` takes a `;`), changing no algorithm. "switches" is
`ZANE_POOLED_VARIANTS=1 ZANE_PARTIAL_INLINE=1 ZANE_PACKED_NODES=1
ZANE_POOL_UNCHECKED=1`; Goose is the mean of the two runs' medians.
gameloop stays out (Setup).

| test | Zane v0.20 | Zane now | Zane now, switches | Goose | best Zane ÷ Goose |
| --- | --- | --- | --- | --- | --- |
| binarytrees | 0.121 s / 14.3 MB | 0.114 s / 14.3 MB | 0.060 s / 10.0 MB | 0.046 s / 10.8 MB | 1.3× |
| treecopy | 0.208 s / 30.3 MB | 0.144 s / 30.3 MB | 0.060 s / 19.3 MB | 0.121 s / 18.2 MB | 0.5× |
| ntree | 0.301 s / 44.9 MB | 0.186 s / 34.3 MB | 0.172 s | 0.106 s / 24.9 MB | 1.6× |
| allocfree | 0.672 s | 0.322 s / 33.3 MB | 0.319 s | 0.309 s / 44.3 MB | 1.0× |
| listgrowth | 0.652 s | 0.148 s | 0.134 s | 0.121 s | 1.1× |
| entities | 0.539 s / 158 MB | 0.500 s / 94 MB | 0.504 s | 0.474 s / 94 MB | 1.05× |
| particles | 0.145 s | 0.124 s | 0.105 s | 0.135 s | 0.8–0.9× |
| concscan | 0.251 s / 158 MB | 0.233 s / 94 MB | 0.226 s | 2.15 s / 163 MB | 0.1× |

The compute-bound tests (trialdiv, mandelbrot, fannkuch, nbody,
spectralnorm), startup and primes are level with Goose and C, as at the
baseline. Particles and listgrowth have no variant types, so the switches
do not touch them; their columns differ by the container's noise.

## Why Zane is slower on ntree: the list handle

ntree is the one test the switches leave behind (Zane ~1.6–1.75× Goose on
the suite's ten rounds). Each round grows a four-way tree 10 levels deep
(1.4 M nodes), counts it and drops it.

### The two programs' trees

- **Zane**'s `Node` is its `ListRef` of children and nothing else, so a
  node *is* a 24-byte list handle `{items, count, room}`. A child's handle
  is stored in its parent's elements block (four children, 96 bytes),
  which is taken from the region at the first push, after the first
  child's whole subtree is built. A leaf is a handle with no block.
- **Goose**'s node holds its children inline, as a list of up to four
  4-byte self-relative links and a count byte: 17 bytes. Nodes are pushed in
  pre-order into one pool per round, and a leaf is built in its parent
  (base-case inlining).

So Zane's tree is 24 bytes a node against Goose's 17: 34 MB against 25 MB
of peak RSS.

### Where the time goes

| measure | Zane | Goose |
| --- | --- | --- |
| instructions, `grow` with its runtime calls | 1031 M | 334 M |
| instructions, `count` | 381 M | 437 M |
| cycles, `grow` / `count` (counters around the calls, 10 rounds) | ~225 M / ~135 M | ~118 M / ~80 M |
| cache lines missed per round (cachegrind, 2 MB last level) | 524 k | 371 k |
| page faults, whole run | 8372 | 5972 |
| user time, 50 rounds (least / median of 9) | 0.560 / 0.646 s | 0.392 / 0.425 s |

Every round streams the whole tree through memory twice, each line once,
and Zane's tree has 1.41× the lines. Faulting in the larger footprint is a
one-time cost, so the gap narrows from about 1.65× over ten rounds to
1.43–1.52× over fifty, which is the ratio of lines.

`grow` runs three times Goose's instructions: per push a room check whose
count goes through the stack (the handle's address is handed to
`zane_list_push`), an arrive check (a page-table lookup), a runtime call
(`zane_list_push`, then `zane_list_first`) at each node's first push, and a
full call for every leaf, three in four nodes. Taking out the arrive check,
building leaves inline, or both, in the IR, moves `grow` by at most 10–20%
(least of 9, three rounds of runs), within this container's noise. The
code is not where the gap is.

### The layout, replayed

`ntree-layout/replay.c` builds and counts the tree from one bump region in
several layouts; `reprun.py` prints each one's least cycles over
alternating passes (depth 10, ten rounds):

| layout | grow | count | MB / round |
| --- | --- | --- | --- |
| Goose: 17-byte nodes, links inside | 67–70 M | 54–56 M | 22.7 |
| Goose's shape, nodes padded to 24 bytes | 85–96 M | 62–67 M | 32.0 |
| Zane: 24-byte handles in the parent's block | 109–117 M | 72–75 M | 32.0 |
| Zane, the block taken before the children | 112–121 M | 61–62 M | 32.0 |
| Zane's shape, a 16-byte handle `{items, count}` | 43–46 M | 60 M | 21.3 |
| Zane's shape, an 8-byte handle `{link, count}` | 35–39 M | 42–45 M | 10.7 |

- **The bytes cost both phases.** Padding Goose's nodes to Zane's 24 bytes
  costs it a third more in `grow` and a tenth more in `count`.
- **The order does not matter.** Taking the block before the children,
  so that the tree lies in pre-order, does not change `grow`.
- **The handle is the lever.** With a 16-byte handle, Zane's own shape
  builds faster than Goose and counts as fast; with an 8-byte one it is
  ahead in both. The 24-byte row's `grow` is pessimistic: C returns a
  24-byte struct through memory, where Zane's `grow` returns it in three
  registers.

So what Zane loses on ntree is the list handle's size, paid once per node:
a child list of four costs 96 bytes of handles where Goose's costs 16 of
links. A smaller `ListRef` handle closes it: the room kept in the block's
header (or implied by the count, since blocks are count-sized) brings it to
16 bytes, and a 4-byte self-relative link with a 4-byte count, as pooled
variants already use for their links, to 8.

## 32-bit references (prototype, behind `ZANE_REF32=1`)

The plan is in "What remains" below. This section grows as each part lands.

### The cage

`ZANE_REF32=1` makes the driver compile the runtime with `-DZANE_REF32`
(`Build.level`, so the cached runtime is keyed by it). Every reservation
the runtime makes goes through `zane_reserve_aligned` and
`zane_release_addresses` (`runtime/region.c`), and with the flag both use
the cage: one `PROT_NONE` reservation of the fixed range 4 GiB–32 GiB
(`ZANE_CAGE_LOW`, `ZANE_CAGE_HIGH`), made once with
`MAP_FIXED_NOREPLACE`. A reservation is the first released range that
fits, else the next part of the cage; a release drops the pages and lists
the range. Since every address in the cage is below 2^35 and blocks are
word-aligned, a pointer into it is stored as its address shifted right by
3: decoding is one shift, with no base to load, as the JVM's zero-based
compressed pointers are. A large list reserves 8× its span instead of 64×
(`ZANE_HEADROOM`), so lists leave room in the cage. Pooled variants are
off under the switch.

### List handles in 12 bytes

A list's handle is `{items, count, room}`; with the switch each field is
32 bits and `items` is stored shifted (CGT type `Handle32`, 12 bytes,
alignment 4). Text keeps its 24-byte handle: its bytes may start anywhere,
in the binary's literals too, so they are neither aligned nor in the cage.

- `lib/codegen/list_handle.ml` reads and writes a handle's fields either
  way; `emit.ml`'s inline element, push, first block and removal, and
  `walks.ml`'s copy, end, move and vacate go through it.
- `runtime/zane.h` defines `zane_list` with 32-bit fields and the
  `ZL_ITEMS`, `ZL_SET_ITEMS`, `ZL_MAKE` macros `list.c` and `block.c` use.
- `size` reads the 32-bit count and widens it.

Every codegen fixture gives the same output with the switch as without
(`ALL=1 fixtures.sh ZANE_REF32=1`), and the test suite passes with it off.

ntree at depth 10, user time over 11 interleaved runs, and peak RSS:

| build | least / median | peak RSS |
| --- | --- | --- |
| Zane, 12-byte list handles | 0.086 / 0.110 s | 18.1 MB |
| Zane, plain | 0.135 / 0.153 s | 34.3 MB |
| Goose | 0.079 / 0.093 s | 24.8 MB |

ntree's node is now 12 bytes against Goose's 17, and Zane's tree takes
less memory than Goose's.

### Boxes in 4 bytes, and compact sums

A boxed member (a recursive variant's or struct's member, adt.md §4) holds
its block's address. With the switch it is a 4-byte `Ref`: `Type_layout`
lays boxed members out as `Ref`, lowering wraps the `Box` that fills one in
a `Convert` to `Ref` (`Build.boxed_value`) and reads one back with a
`Convert` to `Ptr` (`Build.box_block`), and `emit.ml` makes the two
conversions the shift right and left by 3. The walks load and store a
box's slot through `Walks.load_box` and `store_box`.

That alone shrinks no node: a sum's tag took a word and its payload
started at offset 8. So a sum whose cases' payloads all align to 4 bytes or
less is **compact** (`Nodes.Ty.compact`): a 4-byte tag, then its payload in
4-byte words at offset 4 (`payload_at`), which `Case` and `Payload` reach
as the second member of `{i32, [n x i32]}`. binarytrees' `Tree` is then 8
bytes instead of 16, and a `Pair` 16 instead of 32. treecopy's `Tree`
holds an `Int` in its leaf, so it stays 16.

One thing broke on the way. The region pass (`regions.ml`) follows an owner
through a `Case` and a `Box` to where it is returned; it read the new
`Convert` as an ordinary read, so it could no longer see that `make`'s
subtrees end up in its result. It then held them in a scope of `make`'s
own and promoted them at each return, which moved every tree once per
level: binarytrees at depth 18 took 14.2 s. A `Convert` whose result is a
`Ref` now carries the owner as the `Box` under it does, and `make` is
again a bump and three stores.

The cage's first cut also reserved large lists with 8× headroom instead of
64×, so that the cage would hold more of them. listgrowth then moved its
items at each of the extra growths, with 3.5× the page faults, and
allocfree went from 0.33 s to 0.53 s. With 64× restored, both match the
plain build's faults and peak RSS. 64× of a 64 MB list is 4 GiB, so the
28 GiB cage holds seven lists that large at once.

listgrowth still looked slower by eye. At 500000 items, Callgrind counts
26 instructions per push in `zane_main` against the plain build's 24. The
decode itself is free: the shift by 3 folds into the address computation
(`lea (%rax,%rsi,8)`). The two extra instructions are loads. The plain
build compares against `room` and adds `items` straight from memory
(`cmp 0xf0(%rdi)`, `add 0xe0(%rdi)`); a 32-bit field has to be
zero-extended first, which x86 does only in a separate `mov`. A memory
operand is a load micro-op anyway, so the work is nearly the same.

Every fixture still gives the same output with the switch, and the test
suite passes without it.

### Pooled variants under the switch

Pooled variants were off under the switch. A pool's root is a list of
bytes, so under the switch its handle is the 12-byte list handle too:
`Type_layout` lays a pooled member out as `list_handle ()`,
`Pool_cache` reads and writes the handle through `List_handle`, and the
pool runtime in `list.c` goes through the `ZL_*` macros like the rest of
it. Pool blocks are aligned to 8 bytes and carved from the cage, so their
address encodes as any list's does.

`ZANE_POOL_UNCHECKED=1` is ignored under the switch, so pushes check their
room (with the count kept in registers, as `ZANE_POOL_REGISTERS=1`). An
unchecked pool lives in a block that never grows, which reserves 2 GiB, and
the cage's 28 GiB held too few of them: the `spawns` fixture stopped with
"out of addresses for a pool". With that, every fixture gives the same
output under the switch and all four pooling switches, except `arrays`,
`boxes` and `walks`, which pooling refuses either way.

All switches on, with and without `ZANE_REF32=1` (21 interleaved runs,
least and median wall time, peak RSS; the checked column is the pooling
switches with `ZANE_POOL_REGISTERS=1` in place of `ZANE_POOL_UNCHECKED=1`):

| test | switches | switches, checked | switches and Ref32 |
| --- | --- | --- | --- |
| treecopy 18 | 0.048 / 0.078 s, 19.1 MB | 0.048 / 0.076 s | 0.055 / 0.075 s, 19.6 MB |
| binarytrees 16 | 0.055 / 0.062 s, 11.0 MB | 0.054 / 0.064 s | 0.055 / 0.067 s, 11.0 MB |
| ntree 10 (11 runs) | 0.172 / 0.191 s, 34.2 MB | | 0.143 / 0.156 s, 18.1 MB |

Callgrind on treecopy at depth 14: 24.1 million instructions unchecked,
22.4 million checked, 22.4 million checked under the switch. Together they
add nothing for the trees: a pool's nodes already link to each other by
32-bit offsets, so the switch changes only the root's handle. ntree takes
what the switch alone gave it, since pooling does not touch its lists.

### `&T` members in 4 bytes

A reference held in a local or passed as a parameter stays a pointer. One
stored in a member, an element or a payload is a `Ref`, as a boxed member
is (`Type_layout.ref_slot`): `shape` lays such a member out as `Ref`, an
array of references has `Ref` elements, and a list's stride for them is 4.
Lowering decodes where it reads one (`Build.loaded_ref`: a field read, a
subscript, a case read, a `match` binder, which then holds the decoded
reference as a local) and encodes where it writes one (`Build.stored_ref`:
a member or payload being built, an array literal's element, `fill`,
`push`, and an assignment to a field or an element). A reference local is
assigned without encoding. Nothing else can hold the slot's address and
write a pointer there: only a method's subject is ever written through a
parameter (memory.md §2.9), and a subject is never a reference.

A reference can name a global: `@program$console` is one, and every
program here passes it. A program is position-independent by default and
loads at `0x55…`, out of reach of 35 bits, so under the switch it links
with `-no-pie` (`Build.pinned`), which puts its globals below 4 GiB, and
each global is aligned to 8 bytes (`codegen.ml`). Every other place a
reference can name is in a frame or a block, both inside the cage.

Every fixture gives the same output under the switch. Four of them store
references in members (`references`, `replayed`, `longChain`, `settled`)
and `probed` in elements. No suite test does, so `edges/main.zn` is one that
does: a `ListRef` of 2N edges, each `{from &Person; to &Person; weight
Int}` naming one of four owners, scanned 50 times through both
references. An edge is 24 bytes without the switch and 16 with it. At
N = 2000000 (11 interleaved runs, least and median wall time, peak RSS;
Callgrind at N = 200000):

| | wall | peak RSS | instructions |
| --- | --- | --- | --- |
| plain | 0.676 / 0.726 s | 94.3 MB | 167.4 million |
| `ZANE_REF32=1` | 0.510 / 0.541 s | 63.6 MB | 167.5 million |

The same instructions over two thirds of the bytes: the scan is bound by
memory, and is 25% faster.

### The suite with the switch

`run.py` over every test with `ZANE_REF32=1` alone (RUNS=7, median wall
time, peak RSS; the patched sources as above), against the "Zane now"
column of the whole-suite table. Pooled variants are off under the switch,
so the other switches are not set.

| test | Zane now | Zane, `ZANE_REF32=1` | Goose (this run) | Ref32 ÷ Goose |
| --- | --- | --- | --- | --- |
| binarytrees | 0.114 s / 14.3 MB | 0.105 s / 10.0 MB | 0.049 s / 10.0 MB | 2.2× |
| treecopy | 0.144 s / 30.3 MB | 0.146 s / 26.3 MB | 0.117 s / 18.3 MB | 1.25× |
| ntree | 0.186 s / 34.3 MB | 0.133 s / 18.3 MB | 0.115 s / 24.9 MB | 1.16× |
| allocfree | 0.322 s / 33.3 MB | 0.352 s / 33.3 MB | 0.377 s / 44.2 MB | 0.9× |
| listgrowth | 0.148 s / 63.8 MB | 0.177 s / 63.8 MB | 0.130 s / 63.3 MB | 1.35× |
| entities | 0.500 s / 94 MB | 0.493 s / 94 MB | 0.473 s / 94 MB | 1.04× |
| particles | 0.124 s | 0.128 s | 0.134 s | 1.0× |
| concscan | 0.233 s / 94 MB | 0.256 s / 94 MB | 2.34 s / 185 MB | 0.1× |

The compute-bound tests, startup and primes stay level with Goose. ntree
gains the most: its peak RSS falls below Goose's, and its time is within
the container's noise of Goose's. binarytrees' and treecopy's trees shrink,
but at the suite's small depths that does not show in their times, which
depend on pooling, and pooling is off under the switch.

The rows that look slower (allocfree, listgrowth, concscan) compare this
run with the plain column of a run made days earlier, under different
container load. Built from the same compiler and timed interleaved (11
runs each, least and median wall time), only listgrowth is slower:

| test | plain | `ZANE_REF32=1` | instructions, Ref32 ÷ plain |
| --- | --- | --- | --- |
| listgrowth | 0.170 / 0.184 s | 0.184 / 0.197 s | 1.08 (2 a push) |
| allocfree | 0.521 / 0.581 s | 0.537 / 0.585 s | 1.016 (2 a push) |
| concscan | 0.907 / 0.990 s | 0.882 / 0.969 s | 1.009 |
| trialdiv | 0.569 / 0.607 s | 0.581 / 0.616 s | 0.997 |
| entities | | | 1.007 |

The instruction counts are at smaller N than the timings (trialdiv
1000000, entities and concscan 300000, allocfree and listgrowth as timed).
listgrowth does nothing but push, so its two loads a push show as about
7%. allocfree pushes too, but spends most of its time elsewhere.

## Frame references (prototype, behind `ZANE_FRAME_REFS=1`)

The cage caps the program's memory at 28 GiB and, for references to
globals, gives up a position-independent program. This switch shrinks only
what needs no cap.

A reference names a settled owner (memory.md §2.8): a local, a package
constant, or a path from one through struct fields and `ArrayRef`
elements. A store never puts it in anything that outlives what it names
(lifetimes.md §1.1). So a reference points into a frame or at a global, and
never at a list's block or a box. The idea came as "a scope level and an
offset": every scope's size is known at compile time. Levels are not
static across calls, since a function may recurse or be handed a
reference from its caller, so decoding a level would need a table of frame
starts per thread, one load per dereference. But a context's frames are
already back to back in one range, so a slot's distance from where that
range starts is the level and the offset in one number.

### Design

- Every context's frames come from one area within 2 GiB of the program's
  image (`region.c`, `zane_frames_take`): the whole MiBs in the 2 GiB right
  below it, or, where a program is loaded too low for that, the first free
  512 MiB above it within reach. Valgrind loads a program at 1 MiB and
  keeps its own code near `0x58000000`, which is why the second form looks
  for a window rather than taking a fixed one. Contexts keep their ranges,
  so the area is taken in order and never given back.
- A stored reference (`Type_layout.ref_slot`, the same sites as under the
  cage) is its signed 32-bit distance from `__ehdr_start`, the image's
  first byte, which the linker defines (`List_handle.encode`, `decode`).
  Declared hidden, the symbol's address is computed relative to the code,
  so decoding is a `lea` and an add, with no load and no shift. Frames sit
  at negative distances and globals at positive ones, so the program stays
  position-independent and its image and frames move together under ASLR.
- A list's handle is 16 bytes: its items a pointer, its count and its room
  32 bits each (`Ty.Handle16`, `zane.h`). A list's block can be anywhere,
  and a list holds at most 4 GiB; `zane_list_grow` stops the program past
  that. `room` is still in bytes; counting it in elements would lift the
  4 GiB to 4 billion elements, and is not done.
- Boxes, text handles and pools are as without the switch, so
  `ZANE_POOL_UNCHECKED=1` works with it.

`ZANE_FRAME_REFS_CHECK=1` at compile time makes every encode check that the
distance fits, and trap if not. With it, every fixture gives the same
output under the switch, and under the switch with all four pooling
switches except the three pooling refuses. It caught the first cut's
area: 2 GiB below the image's start rounded down to a MiB, whose lowest
MiB was out of reach.

### Measured

Plain, the cage (`ZANE_REF32=1`) and this switch, each built from the same
compiler. Peak RSS at the suite's size, and Callgrind at a smaller one
(ntree 8, listgrowth 500000, allocfree and edges 200000, binarytrees and
treecopy 14, entities 300000):

| test | plain | cage | frame references |
| --- | --- | --- | --- |
| ntree | 34.1 MB, 89.9 M | 18.1 MB, 98.0 M | 23.4 MB, 95.8 M |
| edges | 94.3 MB, 167.4 M | 63.6 MB, 167.5 M | 63.6 MB, 167.1 M |
| binarytrees | 14.1 MB, 186.7 M | 11.0 MB, 195.6 M | 14.1 MB, 186.7 M |
| treecopy | 30.1 MB, 47.2 M | 26.1 MB, 51.1 M | 30.1 MB, 47.2 M |
| listgrowth | 63.6 MB, 251.0 M | 63.6 MB, 271.0 M | 63.6 MB, 261.0 M |
| allocfree | 33.1 MB, 255.7 M | 33.1 MB, 259.7 M | 33.1 MB, 255.7 M |
| entities | 94.1 MB, 83.1 M | 94.1 MB, 83.7 M | 94.1 MB, 83.4 M |

Wall time, 15 interleaved runs, least and median (the container was
loaded, so the absolute times are high; the columns compare within a row):

| test | plain | cage | frame references |
| --- | --- | --- | --- |
| ntree 10 | 0.188 / 0.224 s | 0.142 / 0.164 s | 0.160 / 0.192 s |
| edges 2000000 | 0.708 / 0.759 s | 0.500 / 0.557 s | 0.526 / 0.571 s |
| listgrowth 2000000 | 0.214 / 0.230 s | 0.205 / 0.237 s | 0.202 / 0.227 s |
| allocfree 1000000 | 0.651 / 0.765 s | 0.716 / 0.806 s | 0.688 / 0.833 s |

- edges takes all of the cage's gain: its references are the same 4 bytes.
- ntree takes most of it. Its node holds a 16-byte handle instead of the
  cage's 12, so it peaks at 23.4 MB against 18.1 MB, still below Goose's
  24.9 MB.
- listgrowth's push costs one instruction more than plain, against the
  cage's two: `items` is read straight from memory again, and only the
  32-bit room needs a load of its own.
- binarytrees and treecopy are plain's: their nodes hold boxes, which point
  into the heap, so this switch leaves them at 8 bytes. Pooling is what
  shrinks them, and it works with this switch as without it.

`run.py` with the switch passes every test's output check, and the
compiler's tests pass without it. gameloop took 30.7 s there, but a build
without the switch from the same compiler takes as long (56.6 s against
56.5 s at 100000): the slowness is the current compiler's or `core`'s on a
program this log already leaves out (Setup), not the switch's.

## gameloop's 30 seconds: `rep movsb` over a short distance

The frame-references suite run had gameloop at 30.7 s, against 1.79 s for
the plain build on Oct 29. It is not the compiler: the Oct 29 binary,
unchanged, now takes 30.4 s too, and C's gameloop went from 0.33 s to
7.6 s. The container now runs on an "Intel Xeon Processor @ 2.80GHz"; the
Oct 29 run's processor was not recorded.

### Where the time goes

Callgrind puts 97% of gameloop's instructions in glibc's
`__memcpy_avx_unaligned_erms`, which it counts a byte at a time when it
copies with `rep movsb` (Valgrind notes). Every frame removes the 20 oldest
entities and those whose points run out, each by an ordered removal that
moves every later entity down one place: about 25 moves of the whole
60 KB list, 1.5 MB, a frame. 75 GB over 50000 frames in 30 s is 2.5 GB/s,
about a byte a cycle.

`memmove/shift.c` moves 60 KB down by a given distance, 25000 times:

| distance | glibc `memmove` | `rep movsb` | AVX2 loop |
| --- | --- | --- | --- |
| 32 bytes | 2.77 GB/s | 3.19 GB/s | 49.29 GB/s |
| 64 bytes | 59.82 GB/s | 59.10 GB/s | 52.88 GB/s |
| 4096 bytes | 59.04 GB/s | 58.62 GB/s | 59.42 GB/s |

On this processor `rep movsb` runs at a byte a cycle when its source is
less than 64 bytes past its destination, and glibc takes `rep movsb` for a
move from 4 KiB on (AVX2). A removal's distance is one element: gameloop's
entities are 32 bytes, and C's list holds 8-byte pointers. Goose's list
holds 4-byte references, so its moves stay under 4 KiB and take glibc's
vector loop.

### The fix

A removal whose element is under 64 bytes and whose move is over 4 KiB
moves in 2 KiB pieces, lowest first (`emit.ml`, `remove`; `list.c`,
`zane_shift_down` for the runtime's own removal). Each piece is a memmove
under the threshold, so glibc copies it with its vector loop, and each
writes below what the next reads. The pieces keep the scalar tag the one
memmove had, so LLVM still sees a removal of scalars leave the list's
header alone. `memmove/loops.c`, 60 KB moved 25000 times:

| distance | memmove whole | memmove, 2 KiB pieces | 4×16-byte loop |
| --- | --- | --- | --- |
| 8 bytes | 3.10 GB/s | 56.89 GB/s | 34.79 GB/s |
| 32 bytes | 3.09 GB/s | 59.75 GB/s | 48.87 GB/s |
| 64 bytes | 59.84 GB/s | 57.47 GB/s | 50.48 GB/s |

Two shapes came first. A call to the C helper was as fast, but LLVM cannot
see into a call, so a loop of removals reloaded its list's count (the
`culls` fact test). A loop emitted inline needed `no-builtin-memmove` on
its function to keep LLVM from making it a memmove again, and LLVM will not
inline across that attribute, so `culls$main` stayed out of `zane_main`.
Pieces of memmove need neither.

gameloop at 50000, 7 interleaved runs, least and median:

| build | wall |
| --- | --- |
| Zane before | 29.12 / 31.58 s |
| Zane, pieces | 1.61 / 1.66 s |
| Goose | 0.35 / 0.40 s |
| C | 7.46 / 8.01 s |

Zane is now faster than C here. What is left against Goose is the bytes
moved: Zane's list holds each 32-byte entity inline and Goose's a 4-byte
reference, and the program is still the one zane-lang/spec#245 tracks.

The `culls` fact test asserted four memmoves in its program; with the
pieces LLVM unrolls the string list's two-pass removal loop once fewer, so
it now checks that the scalar moves are tagged and the string moves are
not, however many copies LLVM keeps. The property it is for, the count
kept in a register through the removals, holds.

The perf gate (`just test-perf`) compares Callgrind's estimated cycles
with main's, and Callgrind models no `rep movsb` slow path. `removal`
there is 3.8% above the commit before (optimized; plain 0.2%), and
`stress` level. Its memmove counts are identical, since none of its moves
reaches 4 KiB; the difference is LLVM shaping the hot update loop's control
differently in the slightly larger function (`memmove/hot.py`): the same
body, with an up-count, a compare and a jump instead of a down-count, 12
instructions an iteration instead of 9. Timed (11 interleaved runs at
400000) the two builds are level: 0.382 / 0.430 s and 0.400 / 0.437 s.

## gameloop with the list holding references

Goose's gameloop keeps its entities in a pool and its list holds an
`Entity&<u32 in pool>` for each: a 4-byte index into the pool, whose slots
are reused as entities die. Zane's list cannot hold an `&` (generics.md
§8.3), and a reference names a settled owner (memory.md §2.8), so the
nearest Zane program is Goose's own representation written out: a pool
`ListRef<Entity>`, a list of the spare slots, and the entity list holding
indices in spawn order. Expiry and culling move indices, not entities.

- `gamepool/main.zn` holds each index as an `Int`, 8 bytes.
- `gamepool32/main.zn` holds it as a `Slot`, a struct wrapping
  `@primitives$I32`, since `core` has no 32-bit integer. Its constructor
  passes the `Int` straight to `I32.wrap`, because a call argument is a
  coercion site and a declaration or a `return` is not.

Both print `500 1871 34449268` at 500 frames, as gameloop and Goose do.
Interleaved, 7 runs at 50000 frames (least / median):

| program | time |
| --- | --- |
| gameloop (inline 32-byte entities) | 1.554 / 1.710 s |
| gamepool (8-byte indices) | 0.501 / 0.575 s |
| gamepool32 (4-byte indices) | 0.353 / 0.381 s |
| Goose | 0.343 / 0.392 s |
| C | 7.166 / 7.665 s |

With 4-byte indices Zane is level with Goose. Callgrind at 5000 frames says
why the index width was the gap: the bytes the removals shift.

| program | program code | `memmove` |
| --- | --- | --- |
| gamepool | 322M | 232M |
| gamepool32 | 306M | 117M |
| Goose | 288M | 73M |

Goose's `memmove` count is lower still, which this run does not explain;
the wall time does not show it. The program code is within 6%.

## The whole suite, after the gameloop fix

`run.py` over every test in three builds (RUNS=7; the patched sources as
above): plain, the switches ("switches" as in the earlier whole-suite
table), and `ZANE_REF32=1`. The container ran slower than for the earlier
tables (trialdiv 0.70 s against 0.56 s), so only ratios within one run
compare. The compute-bound tests, startup, primes, particles and concscan
are level with Goose or ahead, as before (concscan 0.11× Goose).

The remaining rows, timed again interleaved (11 runs, least / median wall
time):

| test | plain | switches | `ZANE_REF32=1` | Goose | best Zane ÷ Goose |
| --- | --- | --- | --- | --- | --- |
| gameloop (suite run, median) | 1.67 s | 1.94 s | 1.86 s | 0.38–0.53 s | ~4.4×; gamepool32 ~1.0× |
| ntree | 0.191 / 0.268 s | 0.192 / 0.215 s | 0.148 / 0.177 s | 0.102 / 0.118 s | 1.45–1.5× |
| listgrowth | 0.202 / 0.234 s | 0.216 / 0.230 s | 0.207 / 0.234 s | 0.173 / 0.190 s | 1.2× |
| binarytrees | 0.097 / 0.124 s | 0.056 / 0.062 s | 0.083 / 0.088 s | 0.045 / 0.054 s | 1.15–1.25× |
| treecopy | 0.239 / 0.257 s | 0.064 / 0.099 s | 0.210 / 0.233 s | 0.209 / 0.233 s | 0.3–0.4× |
| entities | 1.059 / 1.135 s | 1.053 / 1.105 s | 1.076 / 1.123 s | 1.062 / 1.095 s | 1.0× |
| allocfree | 0.706 / 0.856 s | 0.731 / 0.861 s | 0.690 / 0.867 s | 0.713 / 0.832 s | 1.0× |

ntree under the switch is further from Goose here than in "The suite with
the switch" (1.16×), with its peak RSS still below Goose's (18.3 MB
against 24.9 MB). That is not noise: at depth 9 Callgrind counts 383 M
instructions for it (355 M plain) against Goose's 193 M. Goose's 193 M are
`grow` and `count` alone; Zane's `grow` takes 214 M, `count` 99 M, and
`zane_list_first` and `zane_list_push` 36 M and 31 M more. Goose's node
holds its children in an inline list with room for four links
(`(Node&<u32>)[..4]`) in a pool per round, while Zane's node owns a
growable list on the heap, grown push by push and freed node by node. Zane is behind on four tests: gameloop with entities held
inline, ntree, listgrowth, and binarytrees without pooling.

## One box per cycle (behind `ZANE_ONE_BOX=1`)

Plain binarytrees allocated three blocks a node, 48 bytes, where Goose
allocates one of 8. `make` boxed the `Pair` under `Tree.node`, and then
each `Tree` member of the `Pair` again, because adt.md §4 boxes every member
whose type leads back to its holder, and both do.

One box per cycle is enough. With the switch, a variant's payload that
leads back to it is boxed as before, and a struct's member is boxed only
when it leads back without passing through such a payload
(`Type_layout.boxed`). binarytrees' `Pair` then holds its two `Tree`s
inline, 16 bytes each, and a node is one 32-byte block; a leaf allocates
nothing. Pooled variants keep their own layout, so the switch is off when
`ZANE_POOLED_VARIANTS=1` is set.

| build | binarytrees 16 | treecopy 18 | instructions, binarytrees 14 |
| --- | --- | --- | --- |
| plain | 0.090 / 0.104 s | 0.216 / 0.245 s | 186.9 M |
| `ZANE_ONE_BOX=1` | 0.050 / 0.056 s | 0.061 / 0.073 s | 123.3 M |
| Goose | 0.052 / 0.053 s | 0.168 / 0.196 s | 141.9 M |

(Least / median wall time of 11 interleaved runs.) Plain binarytrees is
level with Goose with no pooling, and treecopy, whose whole-tree copy now
copies a third of the blocks, is 2.7× ahead. Three codegen fixtures change
under the switch (`boxes`, `keeping`, `walks`); each gives the same output
as without it under `ZANE_CHECK=1` (`fixtures.sh ZANE_ONE_BOX=1`), and
`just test-compiler` passes with it on and off.

## Bump-only regions (behind `ZANE_BUMP_REGIONS=1`): no gain

A box's block came from the innermost region by popping its size class's
stack of returned blocks, or else bumping the frontier, and every block
taken added one to the region's `live` count, which only a checked drain
reads (`snapshot.c`). Strict scopes mean a block returned before its scope
drains is the exception, so with the switch emitted code takes a box's
block at the frontier alone (`Walks.take ~bump_only`): load the frontier and
its end, compare, store. No `live` count is kept, and the runtime skips the
checked drain's count (`-DZANE_BUMP_REGIONS`). A returned block waits for
its scope to drain.

| build | binarytrees 14 instructions | binarytrees 18 (least / median, 11 interleaved) |
| --- | --- | --- |
| `ZANE_ONE_BOX=1` | 123.3 M | 0.245 / 0.332 s |
| with `ZANE_BUMP_REGIONS=1` | 112.2 M | 0.280 / 0.317 s |
| Goose | 141.9 M | 0.233 / 0.271 s |

9% fewer instructions and no change in time (at depth 16 too, 21 runs:
0.049 / 0.060 s against 0.053 / 0.065 s). The size class's pop and the
count were not on the chain that bounds `make`; the frontier's load and
store are, and they stay. Peak RSS is unchanged (binarytrees 16 10 MB,
treecopy 18 22 MB), and `just test-compiler` passes with the switch,
including its memory-bounded tests. The switch stays in for the record but
is not part of the best build.

## Nodes in the scope region instead of pools

Pooled variants exist to put a recursive variant's nodes in one block with
4-byte links. One box per cycle under `ZANE_REF32=1` does that with no
pool: each node is one block bumped from the innermost scope's region,
reached through the thread-local `zane_open` (a constant address, as
Goose's global top is), and its links are 4-byte `Ref`s. binarytrees'
`Tree` is a compact sum of 8 bytes, so a node is a 16-byte `Pair`.

| build (binarytrees 18) | least / median |
| --- | --- |
| `ZANE_ONE_BOX=1` | 0.239 / 0.268 s |
| `ZANE_ONE_BOX=1 ZANE_REF32=1` | 0.225 / 0.246 s |
| with `ZANE_BUMP_REGIONS=1` too | 0.262 / 0.274 s |
| pooled, peeled, packed, unchecked (the switches) | 0.256 / 0.275 s |
| Goose | 0.221 / 0.250 s |

The region beats the pools: level with Goose, where the pooled build is
1.1–1.15× behind, with no pool to make and unmap per tree and no count
reached through a pointer. Goose's node is still half the size, 8 bytes.

### A node as small as Goose's (behind `ZANE_NICHE_SUMS=1`)

Under the cage a stored reference is never 0, so a sum whose first case
carries nothing and whose second is a 4-byte `Ref` needs no tag: it is the
reference, 0 for the first case (`Nodes.Ty.niche`, which needs
`ZANE_REF32=1`). Zeroed memory is case 0, as for every other sum.
binarytrees' `Tree` (`leaf Unit`, then the boxed `node`) is 4 bytes, a
`Pair` 8, and a node one 8-byte block, Goose's size.

Where it shows: `emit.ml` lays the sum out as `{i32}`, builds a `Case` as
the word or 0, reads a `Payload` as the word, and switches on whether it is
nonzero; `Offset` reaches the payload at index 0. A walk's position under
such a case carries a negative tag (`Layout.niche_tag`), which `Walks.present`
tests as a nonzero word, and the optimizer's `Value.locate` reads back as the
case (`Layout.tag_case`).

| build | binarytrees 14 instructions | peak RSS at 20 | binarytrees 20 (least / median, 7 interleaved) |
| --- | --- | --- | --- |
| `ZANE_ONE_BOX=1` | 123.3 M | | 1.168 / 1.348 s |
| `ZANE_ONE_BOX=1 ZANE_REF32=1` | 121.1 M | 66 MB | 1.094 / 1.246 s |
| with `ZANE_NICHE_SUMS=1` too | 116.7 M | 34 MB | 1.085 / 1.279 s |
| Goose | 141.9 M | 50 MB | 1.198 / 1.358 s |

At depth 20 both region builds are 8–10% ahead of Goose; at 16 and 18 all
three are level (0.236 / 0.255 s for the niche against Goose's 0.228 /
0.247 s at 18). The niche halves the memory, to two thirds of Goose's, and
does not move the time. Every fixture gives the same output with
`ZANE_REF32=1 ZANE_ONE_BOX=1 ZANE_NICHE_SUMS=1` as without
(`ALL=1 fixtures.sh`), and `just test-compiler` passes without them.

### The suite with the best build

`run.py` over every test with `ZANE_ONE_BOX=1 ZANE_REF32=1
ZANE_NICHE_SUMS=1` (RUNS=7, median wall time, the patched sources as
above). No pooling switch is set.

| test | Zane | Goose | Zane ÷ Goose |
| --- | --- | --- | --- |
| binarytrees | 0.060 s / 10.0 MB | 0.054 s / 10.0 MB | 1.1× (level interleaved, ahead at depth 20) |
| treecopy | 0.100 s / 22.3 MB | 0.221 s / 18.3 MB | 0.45× |
| ntree | 0.173 s / 18.3 MB | 0.117 s / 24.9 MB | 1.5× |
| listgrowth | 0.238 s | 0.201 s | 1.2× |
| allocfree | 0.703 s / 33.3 MB | 0.710 s / 44.2 MB | 1.0× |
| entities | 1.173 s | 1.124 s | 1.04× |
| particles | 0.149 s | 0.168 s | 0.9× |
| concscan | 0.479 s | 4.92 s | 0.1× |
| gameloop | 1.767 s | 0.392 s | 4.5× (inline entities; gamepool32 is level) |

The compute-bound tests, startup and primes are level, as before (nbody's
0.41 s against 0.34 s here was 0.34 s against 0.34 s in the plain run).

## ntree with an `ArrayRef` of children

Goose's ntree holds a node's children in a list inside the node with room
for four (`(Node&<u32>)[..4]`); Zane's holds them in a `ListRef` on the
heap, grown push by push. `ntreearray/main.zn` holds them as Goose does, in
an `ArrayRef<Node, 4>`. An `ArrayRef`'s elements are all present from
construction (generics.md §8.4), so a leaf cannot be a node with an empty
array; it is a case of its own:

```zane
type Node = #variant {
	leaf Unit;
	inner @primitives$ArrayRef<Node, 4>;
}
```

`grow` builds an inner node from a literal of four recursive calls. `core`'s
`ArrayRef` takes its elements borrowed, which a reference-type owner cannot
be, so the port calls the primitive's `roaming` constructor, which moves
them in. `inner` leads back to `Node`, so its payload is boxed: one block of
four children per inner node, and a leaf allocates nothing. Under the niche
a `Node` is a 4-byte reference, so that block is 16 bytes. It prints what
the suite's ntree prints, and passes under `ZANE_CHECK=1`.

| build | instructions (9) | peak RSS (10) | ntree 10 (least / median, 11 interleaved) |
| --- | --- | --- | --- |
| suite's ntree, best build | 383.1 M | 18 MB | 0.131 / 0.140 s |
| `ArrayRef`, plain | 160.5 M | 23 MB | 0.100 / 0.108 s |
| `ArrayRef`, `ZANE_ONE_BOX=1` | 160.5 M | 23 MB | 0.088 / 0.104 s |
| `ArrayRef`, best build | 140.7 M | 10 MB | 0.060 / 0.069 s |
| Goose | 193.1 M | 24 MB | 0.090 / 0.102 s |

(The best build is `ZANE_ONE_BOX=1 ZANE_REF32=1 ZANE_NICHE_SUMS=1`.) Plain,
the `ArrayRef` port is level with Goose; with the best build it is 1.5×
faster and takes 40% of Goose's memory. One box per cycle changes nothing
here, since `inner`'s payload is the only member on the cycle. So the ntree
gap was the port's container, not the language: what Goose's `[..4]` does,
Zane's `ArrayRef` under a variant case does, given a constructor in `core`
that moves owners in.

## listgrowth: where the push's instructions go

At 500000 items (Callgrind, 10 M pushes) Zane's plain build runs 24
instructions a push in `zane_main` and 1 more in `memcpy`, where Goose runs
12.5 and never copies. Interleaved at 2000000 (11 runs): Zane plain 0.182 /
0.210 s, best build 0.182 / 0.195 s, Goose 0.149 / 0.163 s.

Both build the entity the same way (a convert, a multiply, a shift, four
stores). The difference is the push around it:

- Goose's loop has no capacity check at all: it is the stores, the pointer
  advanced by 32 bytes and the loop bound, unrolled twice.
- Zane's loads the list's count, room and items from the handle in the
  frame (`0xe8(%rdi)`, `0xf0(%rdi)`, `0xe0(%rdi)`), compares, and stores the
  count back, every push. The count goes through memory each iteration, so
  each push's load waits on the store before it.

So the gap is not the cage or the allocator but the loop: the handle is not
kept in registers through it, and a loop of a known count of pushes checks
the room at each one where it could reserve once.

### Two fixes (behind `ZANE_LOOP_PUSHES=1`)

**Room made before the loop.** `core`'s `push` is a verb with a block body,
so the optimized CGT keeps it as a call, and the emitter, which sees one
function at a time, cannot tell the loop pushes. A pass after folding
(`lib/optimize/loop_pushes.ml`) finds every function whose whole body is
one push of its second parameter onto the list its first names, and writes
each call to one among a loop's statements out as that push: the value
bound first, as a statement of its own, then the push. (Bound inside the
push's expansion, the constructor it inlines carries a `leave` of its own,
and the run planner's `push_of` takes any `leave` before a push as a way
out.) The emitter (`looped_pushes`, at `Stat.Repeat`) then takes a loop
whose body pushes once, unconditionally, onto a list no other statement of
the body names: it calls `zane_list_room(list, stride, n)` with the loop's
count before the loop, which grows the block once to hold every push, and
emits the push as a plain store (the run planner's `Room`).

**The count in a register.** With the check and its runtime call gone, the
handle's items and count were still loaded from the frame and the count
stored back each time round: the element's store, an aggregate with no
type tag, may alias anything to LLVM, the handle's fields included. `place`
now stores a struct of scalars member by member, each tagged `zane scalar`,
which LLVM knows never overlaps a `zane handle` access, so it keeps the
count and the element address in registers through the loop.

At 500000 (Callgrind), instructions a push and the loop:

| build | instructions | loop |
| --- | --- | --- |
| plain | 25 (24 + `memcpy`) | count, room and items loaded, compared, count stored, every push |
| room made before the loop | 20 | no check or `memcpy`; items and count loaded and count stored |
| with the scalar tags | 16 | the entity's four stores and the pointer advanced: Goose's loop |
| Goose | 12.5 | the same, unrolled twice |

Interleaved at 2000000 (11 runs, least / median), peak RSS 63 MB for all:

| build | listgrowth |
| --- | --- |
| plain | 0.191 / 0.216 s |
| room before the loop | 0.195 / 0.208 s |
| with the scalar tags | 0.163 / 0.174 s |
| with the tags and the best build's switches | 0.159 / 0.180 s |
| Goose | 0.160 / 0.169 s |

Making room ahead alone gains little; what it buys is a loop with no call,
in which the tags can then keep the count out of memory. Together listgrowth
is level with Goose. Every fixture gives the same output with the switch
(`ALL=1 fixtures.sh ZANE_LOOP_PUSHES=1`), and `just test-compiler` passes
with it on and off.

Caveat: the loop's push is made unchecked on the strength of no other
statement of the body naming the list. A reference to the list taken
before the loop, pushed through inside it, would use the room made for the
loop's own pushes; the prototype does not look for one.

## A loop of one load and one add (`sumloop/`)

Whether Zane's loop shape costs anything shows best in a loop that does
almost nothing else: `sumloop/` sums a list of N `Int`s 200000 times, writing
the total into the first element after each round so that no round repeats
the one before (the same program in Zane, Goose and C).

**With N a constant (2000) the gap is 2×** (0.061 / 0.066 s against 0.030 /
0.034 s, 11 interleaved runs): clang, for C and for Goose's C, proves the
list holds 2000 elements and vectorizes 20 a pass, comparing with a
constant, where Zane's loop reads the size from the list and takes 4 a pass.
C compiled with the size read from its arguments makes exactly Zane's loop
and takes Zane's time (0.064 / 0.067 s). `ZANE_LOOP_PUSHES=1` does not give
LLVM the count either: it reaches the sum through memory, past calls.

**With N the program's argument, as langbench's sizes are,** all three run
the same seven instructions, four elements a pass (705 M instructions
against Goose's 704 M and C's 704 M at 2000), and Zane was still about 12%
slower (0.062 / 0.066 s against 0.054 / 0.059 s). That is where the loop
lies: C's runs from 0x1220 to 0x123b, inside one 32-byte line, and Zane's
from 0x3a30 to 0x3a4d, across the line at 0x3a40, so the decoded-instruction
cache delivers it in two lookups a pass. C's own loop shifted by padding
before it shows the same:

| C loop | crosses a 32-byte line | sumloop 2000 (least / median) |
| --- | --- | --- |
| 0x1220–0x123b | no | 0.053 / 0.058 s |
| 0x1230–0x124b | yes | 0.057–0.064 / 0.066–0.068 s |
| Zane, 0x3a30–0x3a4d | yes | 0.061 / 0.063 s |

So Zane's loop control costs nothing here; what remains is placement.
LLVM aligns loop heads to 16 bytes on x86. Raising that to 32 through
zanec's own LLVM options (`-align-loops=32`, or
`-x86-experimental-pref-loop-alignment=5`) left the loop where it was, most
likely because the options are parsed after the target is made; the
attempt was not kept.

## What a lead hides: per-mechanism checks

With Zane level or ahead on every test, a whole program's time no longer
shows what Goose or C still does better: a lead in one part of a program
hides a loss in another. Two checks look below the totals: each test that
is more than ~10% behind C, profiled against C (Callgrind, plain build),
and Goose's own optimization report, printed on every build, read for the
tests where each of its optimizations fires.

**concscan** (1.1–1.3× C, 0.1× Goose, whose threads hid it). Its scan runs
the same instructions as C's (60.02 M against 60.01 M at 300000), and a join
does not spin: it runs a spawned call not yet started itself, and otherwise
waits on a condition variable. The rest was `main`'s fill, 8.7 M against
C's 5.4 M, which `ZANE_LOOP_PUSHES=1` takes to 6.3 M (67.3 M in all
against 66.6 M). Nothing else is hidden there.

**entities** (1.3× C's instructions, 1.04–1.07× the time). The scan loop,
unrolled four times as C's is, spends 10 instructions on four elements to
C's 8: its exit test is `lea; add; cmp $1` where C's is one `cmp`. C makes
the same loop when written from 1 to n inclusive, which is the only loop
Zane's `to` makes: LLVM's loop-strength reduction (LSR) turns the unroller's
trip counter into that form when the index starts at 1, and keeps one
`cmp` only when the 1-based index is computed from a 0-based counter. Its
`-lsr-term-fold` does not change it. In C, at 1000 entities and 300000
passes, the 1-based loop runs 754 M instructions to 604 M in the same time
(0.090 / 0.095 s and 0.090 / 0.096 s): the loop is bound by its chain of
adds, and the counter's two extra instructions run beside it. Noted, not
pursued.

**fannkuch** (Goose 106 M instructions, C 104 M, Zane 169 M, at the same
time). Zane's port keeps three heap `List<Int>`s where Goose's and C's keep
fixed arrays of 32 on the stack. Two things cost:

- The copy `state.perm[i] = state.perm1[i]` takes 12 instructions an
  element: two index checks, and both lists' item pointers and one's count
  reloaded from memory every element. Their type tags already say an
  element's store cannot touch a handle; the loads stay because they come
  after the checks, whose failure leaves the loop, and IRCE, which would
  take the checks out of the loop, does not fire here.
- The flip's swap checks both indices, 12 instructions a swap to C's 8;
  Goose proves `i < j <= 31` and checks only `j`. Zane has no while loop,
  so its swap runs a counted loop with `j` computed from `i`, from which
  LLVM does not derive `i`'s bound.

`fannkucharray/` is the port at Goose's layout, `ArrayRef<Int, 32>`: 138 M
instructions, the copy gone from the hot code, and in time ahead of Goose
and level with C (0.226 / 0.239 s, Goose 0.241 / 0.263 s, C 0.223 / 0.242 s,
the list port 0.247 / 0.252 s, at 10). The swap's second check remains.

**Goose's optimizations.** Its report on every port: index checks elided
(all of them on most tests; 13/21 on fannkuch, 7/13 on gameloop),
reassociation nowhere, tail loops on binarytrees and treecopy (`check`'s
second call made a loop), and base cases on binarytrees, ntree and treecopy.
Zane's `check` needs no tail loop to beat Goose's (25 M instructions to
55 M at 14), but that lead hid `make`: 92 M to Goose's 83 M under one box
per cycle. Goose's `make` builds both leaves of a depth-1 node itself,
half as many calls; Zane's calls itself for every leaf, and half its calls
only return the empty case, 15 instructions of saved registers each.

That is the base-case inlining `ZANE_PARTIAL_INLINE=1` makes, which did
nothing to `make` under one box: the leaf is returned as `escape(case 0)`,
and the copy refused any `Escape`. A constant, a value that names no local,
owns no blocks, so its escape moves nothing: the copy now keeps one and
drops it where it is written out (`Peel.constant`).

| build (binarytrees) | `make` (14) | total (14) | binarytrees 18 (least / median, 11) |
| --- | --- | --- | --- |
| `ZANE_ONE_BOX=1` | 92.2 M | 123.3 M | 0.253 / 0.297 s |
| with `ZANE_PARTIAL_INLINE=1` | 60.7 M | 90.6 M | 0.196 / 0.268 s |
| Goose | 82.7 M | 141.9 M | 0.229 / 0.261 s |

treecopy at 18: 0.077 / 0.085 s and 0.069 / 0.095 s, Goose 0.191 / 0.211 s.
The 20 fixtures whose CGT the two switches change give the same output with
them (`fixtures.sh ZANE_ONE_BOX=1 ZANE_PARTIAL_INLINE=1`), and
`just test-compiler` passes without them.

## Per-function instructions (`mechanisms.py`)

So that a lead cannot hide a loss again, `mechanisms.py` lines up each
function's own instructions across the three languages, under Callgrind,
whose counts repeat run to run:

```sh
python3 mechanisms.py WORK/bin [TEST ...]
```

It writes `mechanisms.md` and `mechanisms.json` beside `bin` and flags a
function when Zane runs more than 1.10× the better of Goose and C in it,
the function takes at least 5% of Zane's program, the program runs at least
10 M instructions (below that it is the C library starting, whose counts
move with the environment), and the other language's whole program runs
fewer instructions than Zane's (C's `main` is small in allocfree because
its allocating is `malloc`'s rows). `THRESHOLD` and `SHARE` in the
environment change the first two.

`mechanisms-kept.md` is its run over the build kept so far
(`ZANE_ONE_BOX=1 ZANE_PARTIAL_INLINE=1 ZANE_LOOP_PUSHES=1`). Its flags:

| test: function | Zane ÷ best | cause |
| --- | --- | --- |
| trialdiv: `main` | 1.24 (C) | 21 instructions a division to C's 17: the check for a zero or −1 divisor (3), and the port's `k == k / p * p` where C tests the remainder (1). Goose runs the same as Zane. |
| fannkuch: `main` | 1.87 (C) | index checks and handle reloads in the copy, above; `fannkucharray/` is level |
| entities: `main` | 1.25 (C) | the 1-based loop's exit test, above; costs no time |
| listgrowth: `main` | 1.28 (Goose) | Goose unrolls the push loop twice; Zane keeps a second counter |
| ntree: `grow` | 2.52 (Goose) | the suite port's `ListRef` children; `ntreearray/` is ahead |
| allocfree: `main` | 1.64 (Goose) | a region per pass of a loop, and the push's room check; fixed below |
| gameloop: `memcpy` | 12.7 (Goose) | the port's inline entities; `gamepool/` is level |

**allocfree.** Each pass of the release loop opens a scope region and
leaves it: a 256-byte region record taken from the region stack, zeroed
with 15 stores, linked to its parent, and made the thread's innermost
region, all for a body that boxes nothing (`item` is an `Item` held by
value). Goose's loop has no scope work. The push loop also keeps its room
check (`cmp; jg` on the list's room each push) under `ZANE_LOOP_PUSHES=1`,
for a reason not yet traced.

### allocfree, fixed

The room check stayed because `Loop_pushes` matched only `List`'s `push`.
`ListRef`'s copies its value into a local first, and reaches the list
through its record of one handle, at offset 0. The matcher now takes both
shapes, and the call's list address stands for the offset. The push loop
then runs 15 instructions an item with no room check, one `zane_list_room`
before it.

The scope is the larger part. A new switch, `ZANE_LIGHT_SCOPES=1` (Emit,
`light`), opens no region for a scope that nothing can put a block in:
every slot it places holds scalars, its body boxes, copies, makes a list or
a string, spawns and joins nothing, calls the runtime only for list and
array access, pushes and removals of scalars, and parsing, and calls
functions only for scalar results. Such a scope's frame becomes a stack
slot of the function. A frame over 4 KiB still opens a region: the
`frames` and `spawnedFrames` fixtures place megabyte frames, which the
machine stack cannot take.

| allocfree | instructions (200000) | 1000000 (least / median, 15) |
| --- | --- | --- |
| kept build | 255.7 M | 0.669 / 0.729 s |
| with both fixes | 108.4 M | 0.255 / 0.308 s |
| Goose | 152.4 M | 0.603 / 0.654 s |

Across the suite the switch changes three tests' instructions by more than
1%: allocfree, particles (144.6 M to 136.0 M, Goose 142.9 M; level in time)
and gameloop (1215 M to 1196 M). Every test's output is the same with it.
`mechanisms-light.md` is the table over that build: allocfree is no longer
flagged, and the other six flags stand. All fixtures give the same output
with `ZANE_LIGHT_SCOPES=1` and with `ZANE_LOOP_PUSHES=1` (`ALL=1`), and
`just test-compiler` passes with both on and with both off.

Room checks stay in pushes that are not counted up front. Zane's guard
pages do not cover them: the guard follows a context's range of frames, and
a list's items sit in a block among the region's other blocks, so a push
past its room would write over a neighbour, not fault.

## fannkuch: list handles read once a loop (`ZANE_HOIST_HANDLES=1`)

The copy `state.perm[i] = state.perm1[i]` checked both indices and reloaded
both lists' items and one's count every element. IRCE can take a check out
of a loop only when the count it compares with does not change in the loop,
and LLVM could not show that: the count is loaded after the first check,
which may leave the loop, from a frame slot it cannot read ahead of time.

With the switch (Emit, `invariant_lists`), a counted loop whose body cannot
change a list's handle reads each indexed list's items and count once,
before the loop. Such a body calls no function, calls the runtime only to
index, spawns nothing, and writes through memory only values with no
handle in them. The list's address is made of addresses and offsets of
slots made before the loop. The copy then runs no checks at all and is
vectorised, and `advance`'s shift becomes a `memmove`.

| fannkuch (9) | instructions | `main` | 10 (least / median, 21) |
| --- | --- | --- | --- |
| build with light scopes | 169.3 M | 168.9 M | 0.235 / 0.271 s |
| with `ZANE_HOIST_HANDLES=1` | 151.5 M | 151.1 M | 0.240 / 0.270 s |
| Goose | 105.6 M | 105.2 M | 0.241 / 0.267 s |
| C | 103.7 M | 90.3 M | 0.230 / 0.258 s |

All four are level in time: the program is bound by its short flips, and
the extra instructions run beside them. No other test changes by more than
0.5% (`mechanisms-hoist.md`), and every test prints the same.

Each swap of the flip still checks both indices: 12 instructions a swap to
C's 9. Goose checks only `j`, because its fixed arrays of 32 let it prove
`i < j <= 31`. The flips run 1 to 4 times round, far below IRCE's 64.
Lowering IRCE's floor to 1 or 4 made `main` 160 M instructions.

A second switch, `ZANE_LOOP_RANGES=1` (Emit, `ranged`), tried the check
outside the loop for any length. An index that moves by -1, 0 or 1 each
time round is in range on every pass when it is at the first and the last,
so the loop checks both ends before it starts and runs an unchecked copy
when they pass. The swap then runs unchecked and unrolled twice, but the
test before each flip costs about 15 instructions where the checks it
removes cost about 10: 159 M in `main` and 0.267 / 0.296 s. It stays off.

Every fixture gives the same output with `ZANE_HOIST_HANDLES=1`, and with
both switches (`ALL=1`), and `just test-compiler` passes with both on.
`fannkucharray/`, the port at Goose's layout, remains the way to Goose's
instruction count.

## All switches together

The suite built twice from the same compiler, run in one pass
(`results-all-switches.txt`, 7 runs, medians): with no switch, and with
`ZANE_ONE_BOX=1 ZANE_PARTIAL_INLINE=1 ZANE_LOOP_PUSHES=1
ZANE_LIGHT_SCOPES=1 ZANE_HOIST_HANDLES=1 ZANE_REF32=1 ZANE_NICHE_SUMS=1`.
Instructions are Callgrind's at `mechanisms.py`'s sizes; "five" is the
first five switches alone (`mechanisms-hoist.md`).

| test | wall: none | wall: all | Goose | instructions: none | five | all | Goose |
| --- | --- | --- | --- | --- | --- | --- | --- |
| trialdiv | 0.611 s | 0.697 s | 0.635 s | 300.6 M | 300.6 M | 299.7 M | 301.5 M |
| binarytrees | 0.113 s | 0.054 s | 0.055 s | 186.9 M | 90.6 M | 90.5 M | 141.9 M |
| mandelbrot | 0.873 s | 0.902 s | 0.883 s | 66.1 M | 66.2 M | 66.1 M | 66.1 M |
| fannkuch | 0.268 s | 0.255 s | 0.248 s | 169.3 M | 151.5 M | 143.2 M | 105.6 M |
| entities | 1.096 s | 1.087 s | 1.056 s | 83.1 M | 80.2 M | 80.2 M | 64.2 M |
| listgrowth | 0.230 s | 0.200 s | 0.196 s | 250.9 M | 160.4 M | 160.4 M | 125.4 M |
| ntree | 0.195 s | 0.207 s | 0.110 s | 89.9 M | 89.9 M | 93.4 M | 48.6 M |
| treecopy | 0.237 s | 0.095 s | 0.216 s | 47.2 M | 23.3 M | 25.8 M | 53.2 M |
| nbody | 0.346 s | 0.358 s | 0.341 s | 120.8 M | 120.6 M | 125.4 M | 116.6 M |
| spectralnorm | 0.305 s | 0.261 s | 0.289 s | 65.5 M | 65.4 M | 65.4 M | 70.7 M |
| allocfree | 0.690 s | 0.297 s | 0.673 s | 255.7 M | 108.4 M | 110.4 M | 152.4 M |
| gameloop | 1.636 s | 1.738 s | 0.466 s | 1215.1 M | 1196.4 M | 1201.8 M | 361.5 M |
| particles | 0.200 s | 0.197 s | 0.184 s | 144.6 M | 136.0 M | 154.5 M | 142.9 M |
| concscan | 0.486 s | 0.462 s | 4.748 s | — | — | — | 264.9 M |

startup and primes are level throughout. Callgrind does not finish
concscan's Zane binary either way. trialdiv's slower wall time is noise:
it runs the same instructions both ways. Peak memory falls on the trees
(binarytrees 14 to 10 MB, ntree 34 to 18 MB, treecopy 30 to 22 MB) and
moves nowhere else.

**The first five never cost instructions** on any test, and every test's
output is the same. All fixtures give the same output with all seven
switches (`ALL=1`). `just test-compiler` passes with the five, and with the
seven fails only three IR-shape tests (`tests/objects/facts_test.py`) that
state the 64-bit layout: a two-handle struct `dereferenceable(48)` is 24
bytes aligned to 4 under `ZANE_REF32`, and a first block's room is stored
as `i32 32`. What those tests check still happens.

**`ZANE_REF32` with `ZANE_NICHE_SUMS`** trades instructions for memory:
ntree, nbody and particles run 4–14% more instructions than with the five (each reference
read is a shift), and the trees take a quarter to a half less memory. It
also caps the program at the cage's 28 GiB and gives up position
independence for references to globals, so it is a choice for a program,
not a default.

Running them together found one hole, in `ZANE_LOOP_PUSHES`: room made
before a loop was guarded only against the loop naming the list's own
local again, not against a push through a reference to the same list, or a
call that may make one. Either would take the room the unchecked pushes
count on. The loop now makes room only when nothing else in it calls a
function, spawns, or pushes to, makes room in, or removes from any list
(Emit, `may_grow`). The suite's binaries are byte-identical with the guard.

### With frame references instead of the cage

`ZANE_FRAME_REFS=1` (Frame references, above) has neither of the cage's
costs: no cap on the program's memory, and position independence kept. It
shrinks what a reference can name, frames and globals, and list handles to
16 bytes, but not boxes, which point into the heap. `ZANE_NICHE_SUMS` packs
a sum into a box's 32-bit form, so it needs the cage. Its own limit is a
list of at most 4 GiB, since a handle's room is a 32-bit count of bytes.

| test | instructions: five | five + frame refs | five + cage + niche |
| --- | --- | --- | --- |
| ntree | 89.9 M | 91.2 M | 93.4 M |
| entities | 80.2 M | 80.8 M | 80.2 M |
| nbody | 120.6 M | 125.6 M | 125.4 M |
| allocfree | 108.4 M | 110.4 M | 110.4 M |
| gameloop | 1196.4 M | 1205.6 M | 1201.8 M |
| particles | 136.0 M | 150.9 M | 154.5 M |

The other tests are within 0.5%. Time and peak memory, 11 runs, least /
median:

| test | none | five | five + frame refs | five + cage + niche | Goose |
| --- | --- | --- | --- | --- | --- |
| ntree 10 | 0.187 / 0.200 s, 34 MB | 0.192 / 0.221 s, 34 MB | 0.161 / 0.169 s, 23 MB | 0.146 / 0.190 s, 18 MB | 0.115 / 0.120 s, 25 MB |
| binarytrees 16 | 0.097 / 0.134 s, 14 MB | 0.047 / 0.050 s, 10 MB | 0.047 / 0.054 s, 10 MB | 0.040 / 0.057 s, 8 MB | 0.051 / 0.083 s, 8 MB |
| treecopy 18 | 0.223 / 0.253 s, 30 MB | 0.072 / 0.087 s, 22 MB | 0.068 / 0.087 s, 22 MB | 0.071 / 0.086 s, 22 MB | 0.176 / 0.205 s, 18 MB |
| particles 50000 | 0.135 / 0.161 s | 0.139 / 0.141 s | 0.141 / 0.150 s | 0.139 / 0.144 s | 0.150 / 0.162 s |
| nbody 5000000 | 0.316 / 0.333 s | 0.319 / 0.338 s | 0.314 / 0.331 s | 0.310 / 0.324 s | 0.316 / 0.330 s |

Frame references take ntree most of the way (23 MB against the cage's 18
and Goose's 25), and the instructions they add on particles and nbody cost
no time. Only the niche brings binarytrees from 10 MB to Goose's 8. Every
test prints the same with the five and frame references, every fixture
gives the same output with them and `ZANE_FRAME_REFS_CHECK=1` (`ALL=1`),
and `just test-compiler` fails only the same three layout tests: two
16-byte handles make the struct `dereferenceable(32)`.

### Room counted in elements

Under `ZANE_FRAME_REFS=1` a list's room now counts its elements, so a list
holds up to 2^32 - 1 elements of any size instead of 4 GiB
(`runtime/zane.h`, `ZL_ELEMENTS`). A block of `room` elements `stride`
bytes wide is `room × stride` rounded up to a word, computed the same way
wherever the block is taken or returned (`zl_block_bytes`,
`List_handle.block_bytes`, `room_bytes`), since a returned block goes back
to the size class of its bytes. A list's first block is the bytes of the
whole elements that fit the size it had, so the runtime and the emitted
first block agree. A pool is a list of bytes, stride 1, so it counts the
same either way; the cage keeps counting bytes.

`biglist/` pushes N `Int`s and sums them back. At 600000000, 4.6 GB, the
switch's build before this change stops with "a list past 4 GiB"; after
it, plain, frame references, and the five with frame references all print
the right sum (8.7, 8.7 and 4.3 s).

The push's check is now `count + 1 <= room`, with no multiply:

| test | five | five + frame refs, bytes | five + frame refs, elements |
| --- | --- | --- | --- |
| fannkuch | 151.5 M | 151.5 M | 142.6 M |
| ntree | 89.9 M | 91.2 M | 87.7 M |
| entities | 80.2 M | 80.8 M | 80.2 M |
| nbody | 120.6 M | 125.6 M | 125.4 M |
| particles | 136.0 M | 150.9 M | 150.0 M |

The other tests do not move. nbody's and particles' extra instructions
under frame references are not the room's; they are not examined yet.
Every test prints the same, every fixture gives the same output with
`ZANE_FRAME_REFS=1 ZANE_FRAME_REFS_CHECK=1` (`ALL=1`), `just test-compiler`
passes without the switch, and with it fails only the three layout tests,
the first-block one now seeing a room of `i32 4`, four elements.

### nbody's and particles' instructions under frame references

**nbody** (125.4 M against 120.6 M): the inner loop of `advance` kept an
index check that the plain build drops. `size` lowers a 32-bit count to
`Convert (Member 1)`, which widens with its sign, while every other read
of the count (`List_handle.count`) widens with zeros. LLVM saw two values,
`sext c` as the loop's bound and `zext c` as the check's, and could not
prove one from the other. A count or room is never negative, so a
`Convert` of a 32-bit handle's member 1 or 2 now widens with zeros (Emit,
`Expr.Convert`): 121.6 M, and allocfree's 2 M with it.

**particles** (150.0 M against 136.0 M) was two things:

- 1.2 M was not frame references at all: the five-switch build it was
  compared with predates the loop-push guard (All switches together), which
  refused any loop holding a call, and the burst loop calls `rng!below`
  sixty times a frame. The guard now refuses only a call of a function that
  may change a list's count: Loop_pushes computes, over the whole program,
  the functions that push to, make room in and remove from no list, spawn
  nothing, call nothing through a value, and call only such functions
  (`Cgt.List_pure`), and codegen's `may_grow` lets those pass. With it the
  five are back at 136.0 M; a build that does not optimize computes none,
  and keeps every call out.
- The rest, 6.5 M, two instructions a pass of the update loop, is real.
  That loop changes the list's length (`swapRemove`), which stores the count
  back in 32 bits, so LLVM carries the count round the loop as an `i32` and
  widens it each pass; the extra live value makes the register allocator
  spill the items pointer, reloaded each pass. The IR is otherwise the
  plain build's. Left as is: it costs no time.

The suite, rebuilt from this compiler (`mechanisms-six.md` is the six):

| test | none | five | five + frame refs | Goose |
| --- | --- | --- | --- | --- |
| binarytrees | 186.9 M | 90.6 M | 90.6 M | 141.9 M |
| fannkuch | 169.3 M | 151.5 M | 151.5 M | 105.6 M |
| entities | 83.1 M | 80.2 M | 80.8 M | 64.2 M |
| listgrowth | 250.9 M | 160.4 M | 160.4 M | 125.4 M |
| ntree | 89.9 M | 89.9 M | 87.7 M | 48.6 M |
| treecopy | 47.2 M | 23.3 M | 23.3 M | 53.2 M |
| nbody | 120.8 M | 120.6 M | 121.6 M | 116.6 M |
| allocfree | 255.7 M | 108.4 M | 108.4 M | 152.4 M |
| gameloop | 1215.1 M | 1196.4 M | 1201.9 M | 361.5 M |
| particles | 144.6 M | 136.0 M | 142.5 M | 142.9 M |

The rest are within 0.2%. Every test prints the same in both; every fixture
gives the same output with `ZANE_LOOP_PUSHES=1`, and with the six and
`ZANE_FRAME_REFS_CHECK=1` (`ALL=1`); `just test-compiler` passes without
switches, and with the six fails only the three layout tests.

## Goose's memory model, from its own docs

Asked while weighing a stack per dynamic value for Zane. From Goose's
source (`docs/goose_spec.md` §1.2-1.3, §5.4;
`docs/design/scope_exit_cleanup.md` §1; `docs/design/nested_growth.md`
§4.5):

- Goose has no heap. Dynamic data lives on **N data stacks**, N computed by
  the compiler: large reservations made once, committed on use, each a bump
  pointer. Growth never moves anything.
- A scope's exit resets the watermarks of the stacks it used, known at
  compile time: "No destructor runs. No list is walked. The cost of
  'freeing' that buffer is one store." Nothing is walked.
- That rests on an invariant the compiler proves: lifetimes on one stack
  nest; at most one resizable value is live per stack, always on top; two
  live resizables never share a stack, and locals with disjoint lifetimes
  reuse stacks.
- So stacks are per **growable slot in the program**, not per value at run
  time. Goose rejected a stack per container: "A JSON document has
  thousands of containers; a reservation each is absurd."
- The price is in the language: an array element may not be resizable, a
  type may not contain itself by value, and nested growth is limited to
  the containers on the path being built. Trees are pools the program
  declares (`reusable var pool: T[>..]`), linked by 32-bit relative
  references (`T&<u32 in pool>`), with a free list of slots that stay valid
  values forever.

## Image-relative boxes (`ZANE_IMAGE_BOXES=1`)

The cage's one memory win frame references did not keep was the boxed
member: a box stayed an 8-byte pointer. `ZANE_IMAGE_BOXES=1`, on top of
`ZANE_FRAME_REFS=1`, stores it in 32 bits without a fixed address range:

- A box (`Nodes.Ty.Box32`) is its block's signed distance from the image
  (`__ehdr_start`) in 8-byte units, so it reaches ±16 GiB. Decoding is
  `image + sext(v) << 3`; encoding traps under `ZANE_FRAME_REFS_CHECK=1`
  when the distance does not fit. 0 is null: no block starts at the image.
  The walks decode 0 to null; the emitter's decode skips that test, since
  a box is set while its case is live.
- The runtime carves every dynamic chunk from a window reserved once near
  the image (`zane_window_take` in `runtime/region.c`): the whole MiBs from
  16 GiB to 2 GiB below it, under the frames, or where the program loads
  too low (Valgrind), 12, 8, 4 or 2 GiB from 4 GiB above it. Frames are
  within 2 GiB already, so a box in a scope's frame encodes too. Lists'
  growable spans and pools stay outside: their handles hold 8-byte items.
- `ZANE_NICHE_SUMS=1` now packs `[Void; box]` into the bare word too.
- Build note: clang folded `image - 16 GiB` into one `R_X86_64_PC32`
  relocation against `__ehdr_start`, which cannot hold the offset and fails
  to link; the image's address passes through an empty `asm` first.

Validated with the five switches, frame references, image boxes and the
niche: all 16 suite outputs match, the 63 fixtures (`ALL=1`, with
`ZANE_FRAME_REFS_CHECK=1`) give the same output, and `test-compiler` fails
only the three `facts_test` layout assertions every frame-reference build
fails.

Interleaved, 7 runs each, min / median and peak RSS, at langbench's sizes;
`six` is the five plus frame references, `cage` the five plus `ZANE_REF32`
and the niche, `ib` the six plus image boxes and the niche:

| test | six | cage | ib |
| --- | --- | --- | --- |
| binarytrees 16 | 0.046 / 0.046 s, 10 MB | 0.040 / 0.043 s, 8 MB | 0.040 / 0.042 s, 8 MB |
| ntree 10 | 0.160 / 0.166 s, 23 MB | 0.147 / 0.149 s, 18 MB | 0.155 / 0.165 s, 23 MB |
| treecopy 18 | 0.065 / 0.081 s, 22 MB | 0.066 / 0.092 s, 22 MB | 0.069 / 0.092 s, 22 MB |
| allocfree | 0.289 / 0.308 s | 0.266 / 0.305 s | 0.285 / 0.299 s |
| particles | 0.137 / 0.143 s | 0.142 / 0.147 s | 0.138 / 0.147 s |
| gameloop | 1.593 / 1.642 s | 1.517 / 1.607 s | 1.564 / 1.605 s |

The other seven tests are level within noise across the three.

Callgrind totals (`mechanisms.py`) are identical to the six's in every test
but two: binarytrees 90.6 → 97.8 M (+8%) and treecopy 23.3 → 27.6 M
(+19%). The cost is the decode: `check` keeps the image's address in a
callee-saved register and forms each child with a `lea (image, v, 8)`,
where the six loads a pointer; the cage pays the same kind of cost (`check`
25.4 M six, 29.4 M cage, 33.6 M ib). Neither shows in time.

So image boxes give binarytrees the cage's 8 MB and speed, position
independent and with no fixed range. What the cage still has is ntree's
18 MB against 23: that saving is the list handle's items in 32 bits (a
12-byte handle), not boxes, and items live in growable spans outside the
window. Reaching it means carving spans from the window as well, which
caps the lists all of a program's chunks share at the window's 14 GiB.

## What remains

| test | Zane ÷ Goose (wall) | what accounts for it |
| --- | --- | --- |
| binarytrees | level with `ZANE_ONE_BOX=1` alone; ahead at depth 20 with `ZANE_REF32=1`, at two thirds of Goose's memory with `ZANE_NICHE_SUMS=1` | Closed: one box per cycle, nodes bumped from the scope region, and an 8-byte node. |
| ntree | ~1.6×; with `ZANE_REF32=1`, ~1.1–1.2× in the suite and level at depth 10 | The list handle was the gap: 24 bytes against Goose's 17-byte node. Under the switch it is 12 bytes, and Zane's tree takes less memory than Goose's. |
| treecopy | ~1.2× (pooled and packed: 0.6×) | Pooled, Zane is ahead: a whole-tree copy is one `memcpy`, and packed, its nodes are Goose's 17 bytes. |
| allocfree | ~0.4× with `ZANE_LIGHT_SCOPES=1` | Closed: no region opened for a pass of a loop that boxes nothing, and the `ListRef` push loop's room made once. |
| fannkuch | level; 1.4× Goose's instructions with `ZANE_HOIST_HANDLES=1` | The copy runs unchecked; each swap of the short flips still checks both indices. `fannkucharray/` matches Goose's layout. |
| listgrowth | level with `ZANE_LOOP_PUSHES=1` | Closed: room made before a loop of pushes, and the count kept in a register through it. |
| gameloop | ~4.4× inline; with the list holding 4-byte pool indices as Goose's does (`gamepool/`, `gamepool32/`), ~1.0× | Inline, each removal shifts 32-byte entities where Goose shifts 4-byte references. |

The best build so far is
`ZANE_ONE_BOX=1 ZANE_PARTIAL_INLINE=1 ZANE_LOOP_PUSHES=1 ZANE_LIGHT_SCOPES=1 ZANE_HOIST_HANDLES=1`,
plus `ZANE_REF32=1 ZANE_NICHE_SUMS=1` for the trees. `mechanisms-hoist.md`
is the per-function table over it without the last two: six flags, each
with its cause in "Per-function instructions" above. Two helpers were used
for the latest timings and listings: `time_runs.py` and `hotdis.sh`
(Callgrind with `--dump-instr=yes`, then the hottest instructions
disassembled).

Without pooling, what is left is mostly representation: link width, handle
size, and whether a tree's nodes sit in one pool or in separate blocks.
The allocator's own paths account for little of it. Pooled variants address
the representation, partial inlining a recursion's base case, and packing
the node's size, and Goose's push shape the push itself.

**Every reference a 32-bit offset** is built, behind `ZANE_REF32=1` (32-bit
references, above): list handles and boxed members are 32-bit, and sums
whose payloads align to 4 bytes or less are compact, and a reference
stored in a member, element or payload is 32-bit. Not under the switch:
text handles stay 24 bytes, since text bytes are unaligned and may sit in
the binary, and `ZANE_POOL_UNCHECKED=1` is ignored, since an unchecked
pool's 2 GiB block does not fit the cage more than a few times over.

**Frame references** (behind `ZANE_FRAME_REFS=1`, above) shrink references
to 4 bytes and list handles to 16 without the cage: no cap on the program's
memory, and the program stays position-independent. They take the cage's
gain on edges and most of it on ntree, and none on the trees of boxes.

After that, for binarytrees: a calling convention for functions that build
into a pool, items and count passed in registers and the new count
returned, so the count never goes through memory between frames.
