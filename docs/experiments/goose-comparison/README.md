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
26 instructions per push in `zane_main` against the plain build's 24: the
two are the load and shift that decode `items`, which the inline push does
on every call. Over 11 interleaved runs at 2000000 items the least wall
time is 0.104 s against 0.087 s, but the medians (0.129 s, 0.116 s) and
single runs overlap.

Every fixture still gives the same output with the switch, and the test
suite passes without it.

## What remains

| test | Zane ÷ Goose (wall) | what accounts for it |
| --- | --- | --- |
| binarytrees | ~2.2× (pooled, peeled, packed and with Goose's push shape: ~1.2–1.3×) | The rest is the pool's address: Zane reads its count through a pointer restored from the stack in every frame, which puts a second store-to-load forward on the count's chain. With `make`'s pool in a global, Zane matches Goose. |
| ntree | ~1.6× (steady state 1.43–1.5×) | The list handle: each node is a 24-byte `{items, count, room}` in its parent's block, against Goose's 17-byte node with 4-byte links inside, so 1.41× the memory, streamed through twice a round. A replay of Zane's shape with a 16-byte handle builds faster than Goose and counts as fast. |
| treecopy | ~1.2× (pooled and packed: 0.6×) | Pooled, Zane is ahead: a whole-tree copy is one `memcpy`, and packed, its nodes are Goose's 17 bytes. |
| allocfree | ~1.0× | Closed. |
| listgrowth | ~0.9× | Closed. |

Without pooling, what is left is mostly representation: link width, handle
size, and whether a tree's nodes sit in one pool or in separate blocks.
The allocator's own paths account for little of it. Pooled variants address
the representation, partial inlining a recursion's base case, and packing
the node's size, and Goose's push shape the push itself.

The next step, decided: **every reference a 32-bit offset** (behind
`ZANE_REF32=1`). The runtime reserves one range at startup, the cage, and
carves every frame range, chunk and list block from it; a stored reference
is `base + offset × 8`, so the cage reaches 32 GiB. What becomes 32-bit:
`&T` fields and boxed members, and the items pointer of list and text
handles, whose count and room become 32-bit too, so a handle is 12 bytes
instead of 24 (one list holds at most 4 GiB). That puts ntree's node at 12
bytes against Goose's 17. Because list blocks live in the cage, a large
list reserves less headroom than its present 64× and moves when it
outgrows it; listgrowth will show what that costs. Spawned contexts get
smaller frame ranges inside the cage, and a full cage aborts.

After that, for binarytrees: a calling convention for functions that build
into a pool, items and count passed in registers and the new count
returned, so the count never goes through memory between frames.
