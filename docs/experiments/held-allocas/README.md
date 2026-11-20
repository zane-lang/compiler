# Held allocas

Can LLVM keep every held local in registers by itself? A local the lowering
holds in its scope's arena (`Stat.Hold`, `Stat.Reserve`: an owner, or a value
that owns blocks, such as a `List`, a `String` or a struct holding one) lives
in its scope's frame today, because the runtime finds the arena a list grows
in from the address of the list's handle (`zane_region_at`). LLVM cannot keep
frame memory in registers, so `lib/codegen/frame_shadow.ml` copies frame
slots into allocas after the O2 passes, one recognised shape at a time.

The experiment passes the arena explicitly to the runtime calls that need it
on a held local, emits the held local as an alloca, and moves it back into
its frame slot after the O2 passes only where its address still escapes.

Switch: `ZANE_HELD_ALLOCAS=1` when compiling. The plan, with its decisions
D1–D7: <https://claude.ai/artifact/7vhahy9yzN6wecmLFoDi41>.

How to measure: `tests/perf/run [PROGRAM...]` under `pixi run`, once with the
switch unset and once with it set. Numbers are Callgrind's estimated cycles
(`tests/perf/README.md`), run with Valgrind 3.27.1 from the pixi
environment.

## Step 0: baseline

`main` at `15d7ede`, switch unset: every perf program, every build, in
[`baseline.txt`](baseline.txt). The programs the plan expects to move:

| program | optimized | tiered | plain |
| --- | ---: | ---: | ---: |
| subjects | 1,330,028,054 | 1,861,538,048 | 2,416,258,864 |
| tape | 13,119,424 | 13,464,720 | 34,032,835 |
| bits | 66,104,905 | 78,107,722 | 238,464,022 |
| paths | 26,195,352 | 28,031,603 | 88,436,123 |
| workers | 39,316,628 | 38,737,245 | 79,852,307 |
| refills | 34,136,961 | 36,838,870 | 101,588,778 |
| pushes | 18,549,957 | 18,829,034 | 44,966,761 |

## Step 1: held locals as allocas, no other change

**Design.** `lib/codegen/emit_frames.ml` (`held_slot`): under the switch, a
held local of at most 256 bytes is an alloca instead of its frame slot.
Nothing else changes, so a call given its address finds the wrong arena
whenever the local's scope is not the innermost one open. This step only
bounds what the alloca alone buys.

**Results.** Against the baseline, optimized: `subjects` +9.1%, `bits`
+19.3%, `refills` +11.9%, `workers` +6.4%, `paths` +4.2%; `tables` −26.2%,
`phrases` −21.0%, `texts` −36.4%. `texts` printed `5439 200` instead of
`20000 200`, and `stress` stopped with "index out of range", so the gains
are not to be trusted. The losses are what `frame_shadow` gains today: the
alloca is given to the rare call that grows a list, so LLVM keeps it in
memory, and `frame_shadow` only copies frame slots.

## Step 2: the frame slot around each call

**Design.** `lib/codegen/held_spills.ml`, run on each function right
after it is emitted, before LLVM's passes. A call given an address in a
held alloca is given the same address in its frame slot instead, with the
alloca's value stored to the slot before the call and loaded back after.
The runtime and every callee then see a frame address, as without the
experiment, so the runtime is unchanged. Any other use of the address
(stored as a value, kept by `zane_hold`, merged or compared) gives up on the
alloca, which takes its frame slot again. The inline push's first block
(`lib/codegen/emit_lists.ml`, `innermost`) counts a held alloca as the
innermost scope's only when its own scope is the innermost one open.

This replaces decisions D1 and D3 of the plan (an arena argument on the
runtime's calls, and a late pass that moves an escaping alloca into its
frame): copying around the call needs neither, and no IR pass after
LLVM's has to find an alloca SROA may have split.

**Results.** Every program printed its golden output. Optimized geomean
−0.01%, plain +1.64% (nothing promotes the allocas there, so the copies
only cost), tiered +0.31%. With `ZANE_FRAME_SHADOW=0` (a switch added for
this, in `lib/codegen/build.ml`): optimized +1.63% without the experiment
and +2.07% with it, so the experiment was reaching none of the locals
`frame_shadow` keeps in registers. `ZANE_HELD_ALLOCAS_DEBUG=1` showed why:
with checked drains possible, every held slot that owns blocks is listed
with `zane_hold` where it is held, on a cold branch, and that call keeps the
address. The experiment is now off in builds without `--optimize`.

## Step 3: checked drains list at the drain

**Design.** A held alloca is no longer listed where it is held. On the
path where its scope's drain is checked (`drain_scope`), its value is
stored to its frame slot and that slot is listed. The alloca is zeroed,
and its slot's address computed, where its scope's code starts, so a drain
on a way out before the hold lists an empty value. A local whose layout may
hold a foreign handle keeps its frame slot, since its drain ends it whether
or not drains are checked.

**Results.** In `subjects`, `refills`, `workers` and `handover`, every held
local is now an alloca, and each prints its golden output with and
without `ZANE_CHECK=1`.
