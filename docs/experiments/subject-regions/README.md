# Subject regions

Can a context's regions go without a lock? Today a spawned `mut` call on a
local value works on it in place, so its allocations come from the
spawning scope's region while the spawner keeps allocating there too, and
every allocation in a context with a call out takes that context's lock
(`runtime/arena.c`, `zane_guarded`). Emitted code checks `zane_open` before
each inline box and scope entry, and falls back to the runtime and its
mutex when it is null.

The experiment gives each spawned subject that owns blocks a **subject
region** of its own while its call is out, which only that call writes.
Then no thread allocates or returns a block in a region it does not own,
and the lock, the `zane_open` null check and the box's runtime fallback
can go.

Switch: `ZANE_SUBJECT_REGIONS=1` when compiling (lowering, codegen, and the
runtime as `-DZANE_SUBJECT_REGIONS`). `ZANE_SUBJECT_REGIONS_NO_ISLANDS=1`
as well is the control: the runtime without locks, but no subject regions.
Not in the spec: concurrency.md §4.4 already allows it ("Allocator
synchronization is required only when concurrent work actually shares an
underlying arena").

## Step 1: a region per spawned subject

**Design.**

- Lowering (`lib/cgt/lower_spawn.ml`) marks a spawn whose subject owns
  blocks with an `Expr.island` (`lib/cgt/nodes.ml`): the frame member that
  holds the subject's address, which the call reads it through, and, when
  the subject is a copy (reached through an owner), the member the copy is
  in, plus a pointer member after it.
- Codegen (`lib/codegen/emit.ml`) calls `zane_island_make` after filling
  the frame and before `zane_spawn`: it makes a region, moves the subject
  into it (`zane_move`: what arrives in a subject region moves in), and
  repoints the frame's member.
- The runtime (`runtime/spawn.c`) records the region on the spawning
  context. At the join, on the joining thread, the subject goes home: a
  local's bytes are copied back and the region's chunks become the region's
  that holds the local, which drains with it; a copy is written back through
  `zane_writeback`, which the call's own thread now only records, and the
  region's chunks are given back.
- A subject region is a `zane_mark` that is no scope (depth
  `ZANE_ISLAND_DEPTH`): it has no frame to stretch, takes no spare chunk of
  its spawner's from another thread, and outlives no scope.
- Package constants, which any thread may make, move into a region of
  their own under the constants' mutex instead of `zane_program`.
- With the switch, `zane_guarded` is 0 and `zane_open` is always the
  innermost scope, and the inline box has no null check or runtime
  fallback (`lib/codegen/walks.ml`). Instead of the lock, the runtime stops
  the program when a thread takes a region of another context, or searches
  another context's scopes, except the context of a call it is joining,
  which is done (`zane_lock_region`, `zane_region_at`).

**Results.** `fixtures.sh OUT spawns spawned` (codegen fixtures, plain and
optimized, checked and unchecked, under the switch): all match their golden
files. `race/` (three spawned `deepen` calls and one in the spawner, 20
rounds) prints 20 `yes` with the switch, making 60 subject regions; the
control stops at its first spawn with "experiment: another thread's scopes
searched".

The whole `just test-compiler` suite, with the switch off: passes. With
it on (`ZANE_SUBJECT_REGIONS=1 DUNE_BUILD_DIR=_build_sr DUNE_CACHE=disabled`,
since Dune does not track the variable), every program's output matches,
checked and unchecked, plain, optimized and tiered, as do the runtime's C
tests, the FFI, object and tier tests and the memory probes; the one
difference is `tests/codegen/golden/spawns.cgt`, the lowering dump, which
shows the pointer member a copied subject is now read through. No test
stopped on the runtime's cross-thread check.

**The race, measured.** `race/` takes the depth from its first argument
(so the optimizer cannot fold it). Optimized builds, compiler at this
step's commit:

| build | `race 3000`, 20 runs | wall clock, best / median of 7 (4 cores) | `race 200` / `race 500` instructions (lackey) |
| --- | --- | --- | --- |
| today's runtime | 20 correct | 9.22 / 9.40 s | 570M / 3,475M |
| `ZANE_SUBJECT_REGIONS=1` | 20 correct | 2.36 / 2.45 s | 476M / 2,904M |
| control: no locks, no subject regions, no check | 30 of 30 segfault (sizes 100, 1000, 3000) | — | — |

The instruction counts fall by 16%, the time by 4×: most of what today's
runtime spends is waiting on the spawning context's lock, which every
spawned `deepen` takes for each block it moves into its subject. The
control shows the lock is load-bearing today: without it and without
subject regions, the program crashes every time. Lackey counts the whole
process, repeat runs within 0.1%; Callgrind cannot be used here, since it
stops on the runtime's commit-on-touch fault in a spawned thread
(`threads.c:247`, `vgCallgrind_post_signal`). Wall-clock numbers are from a
shared container and only good for a gap this size.

**Programs that never spawn.** `tests/perf/run --build optimized`,
estimated cycles, off / on; the inline box loses its null check and its
runtime fallback:

| program | off | on | change |
| --- | --- | --- | --- |
| trees | 26.44M | 24.43M | −7.6% |
| texts | 59.91M | 56.33M | −6.0% |
| scopes | 27.78M | 26.68M | −4.0% |
| stress | 1,978.5M | 1,966.1M | −0.6% |
| returns | 137.29M | 140.30M | +2.2% (instructions −0.25%; mispredicts 1.12M → 1.29M) |

The other eleven move by less than 0.15%.

## Step 2: scope entry without the check

**Design.** With the switch, `enter` (`lib/codegen/emit.ml`) places the
frame inline unconditionally; the runtime's path is left unreached, and the
object no longer references `zane_scope_enter`
(`tests/objects/golden/survey.symbols` loses that line, the suite's second
and last difference under the switch).

**Results.** `tests/perf/run --build optimized`, on, against step 1:

| program | step 1 | step 2 | change |
| --- | --- | --- | --- |
| scopes | 26.68M | 27.58M | +3.4% (0.9M more instructions) |
| texts | 56.33M | 56.01M | −0.6% |
| stress | 1,966.1M | 1,964.6M | −0.1% |
| trees | 24.43M | 24.42M | 0.0% |

So removing the entry check is no win: `scopes` gives back most of what
step 1 gained, likely LLVM unrolling or inlining differently once the call
is gone (lowering.md §9 keeps a call in some pushes for that reason), not
yet looked at.

## Step 3: a local subject is copied, not moved

**The defect.** `reader/` spawns `depth(a)` and then `a!deepen(n)` in one
block. The checker accepts it, and the reader's frame holds a shallow copy
of `a`'s handle, so it walks the blocks `a` owns. Step 1 moved `a` into its
subject region, which returned those blocks to `a`'s home region: each
returned block's first word became a link in a free stack, which the
reader then followed as a box. 10 of 10 runs segfaulted, checked and
unchecked; today's runtime printed the right answer 10 of 10 times.

**Design.** `zane_island_make` takes whether the subject is a copy made for
this call alone. Such a copy still moves; a local is now copied into its
region whole (`type->copy` into the region), so its old blocks stay as they
are while the call is out, and a reader sees the value from before the
spawn, a coherent snapshot (concurrency.md §4.4). At the join the old value
is retired in its home region when drains are checked, as a write-back's
replaced value is, so the checked drain ends it; unchecked, it goes with
the region.

**Results.** `reader 2000` and `race 2000`, plain and optimized, checked
and unchecked, 10 runs each under the switch: all correct. The whole suite
under the switch: the same two expected differences as step 2, nothing
else; with the switch off it passes.

## Open points

- **Each subject region takes a 1 MiB chunk**, from the spawner's warm
  spares; a call that touches little pays for a whole chunk's mapping.
  A smaller first block would do.
- **Copying a local subject in costs a deep copy** of what it owns at
  each spawn, and its old blocks stay until its scope drains; today's
  runtime works in place. `race` starts each subject empty, so it does not
  measure this.
- **Static frames are not needed**: a frame stretches only for its own
  context's blocks, so only one thread moves a frontier.
- Why `returns` mispredicts more, and why `scopes` regresses in step 2.
