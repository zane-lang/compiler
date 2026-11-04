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

## What remains

- The full suite under the switch.
- Instruction counts: boxes in the spawner (the null check gone) and the
  cost of moving a subject in and out.
