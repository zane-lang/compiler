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

## Step 4: deterministic rewrites

**Design.** `Held_spills` kept its allocas in hash tables keyed by LLVM
values. An LLVM value hashes by its address, so the order of the rewrites,
and so the code, differed between runs of the compiler: a tiered build of
`interp`, `automaton` or `refills` sometimes stopped with "tier 1 did not
take every function", and `refills` tiered counted 33.9M or 42.4M cycles
from one build to the next. The tables are lists now, compared by `==` and
reset for each function. The numbers of steps 2 and 3 were taken before
this fix and are only indicative.

## Step 5: Zane calls take the frame slot

**Design.** Only the runtime's calls (`zane_*`) are given the frame slot
around the call. A held local given to a Zane function takes its frame slot
for good, as without the experiment: LLVM may inline the function, after
which the copies go round code that works on the frame slot, and a loop
that makes the call copies the local there and back on every pass.

**Results.** `lent`, whose loop passes a held `Doc`'s string to a function,
went from +65% to the baseline.

## Step 6: listing where held, and the slot computed there

**Design.** Two details of step 3 cost the locals that take their frame
slot again: zeroing the alloca where its scope's code starts (`flags` +5%),
and computing the slot's address there, which became a phi where LLVM
threads the scope's entry into its fast and slow paths, so `frame_shadow`
left that frame in memory (`lent` +52%). Now a held alloca is listed by its
frame slot where it is held, as without the experiment (the listing takes
the slot's address, not the alloca's), and the checked drain's path stores
the alloca's value into the slot, computed from the scope's record, before
the drain. When the local takes its slot again, those stores are removed.

**Results.** Every program printed its golden output; `just test-compiler`
passed with the switch on. Against the baseline
([`step6-on.txt`](step6-on.txt)):

| build | geomean |
| --- | ---: |
| optimized | −0.36% |
| tiered | −0.68% |
| plain | +0.01% (the experiment is off there) |

| program | build | change |
| --- | --- | ---: |
| pushes | optimized | −13.4% |
| pushes | tiered | −13.2% |
| bits | tiered | −16.7% |
| paths | optimized | −5.4% |
| refills | optimized | +3.8% |
| scopes | optimized | +3.2% |

`scopes` loses the copies around the growth that each call of `gather`
makes; `refills` passes its `Writer` to a Zane function, so it takes its
frame slot, and two more locals are copied around a growth.

**`frame_shadow`.** With `ZANE_FRAME_SHADOW=0` as well
([`step6-on-no-shadow.txt`](step6-on-no-shadow.txt)), optimized is +0.94%
against the baseline (`handover` +13.5%, `subjects` +9.0%, `cursor`
+7.7%); without the experiment, turning it off costs +1.63%
([`baseline-no-shadow.txt`](baseline-no-shadow.txt)). The locals it keeps in
registers are given to Zane functions, `mut` subjects mostly, so they take
their frame slots here. `frame_shadow` still gains, so it stays.

## Step 7: the late pass

**Design.** `ZANE_HELD_LATE=1`, with `ZANE_HELD_ALLOCAS=1`. A held alloca
given to a Zane function is no longer given its frame slot before LLVM's
passes (step 5). `Held_spills` anchors it where it is held with a call to
`zane_held_anchor`, given the alloca and its frame slot. The anchor is
declared to touch only memory nothing else reaches and to neither read nor
keep either address, so the passes keep the alloca whole but still read its
loads and stores as a local's. After the passes, `lib/codegen/held_late.ml`
settles each anchored alloca as `Held_spills` settles one before them, and
removes the anchors.
- A runtime call is given the frame slot around the call. A list operation
  copies only the list's handle there and back, so the other fields stay
  the same values across the call.
- If a Zane call is still there, the alloca's uses take the frame slot.
- Where LLVM copied the hold (an unrolled or peeled loop), each anchor stores
  its slot into a cell, and each call loads its slot from there.

The first form of the anchor was an `llvm.assume` operand bundle. SROA
drops such uses, which left poison in the tier 1 build. A plain build, and
tier 0, settle the anchors without running LLVM's passes. Tier 1's cache key
now includes the experiment's switches: earlier tiered numbers taken across
switches may have reused another configuration's tier 1.

**Results.** `just test-compiler` was rerun only in part:
`tests/objects/facts_test.py` passes with both switches. Against the
baseline ([`step7-late.txt`](step7-late.txt)):

| build | geomean | against step 6 |
| --- | ---: | ---: |
| optimized | +2.00% | +2.36% |
| tiered | −0.32% | +0.36% |
| plain | +0.01% | 0.00% |

| program | build | against step 6 |
| --- | --- | ---: |
| wrapped | optimized | +196.9% |
| rotations | optimized | +9.9% |
| paths | optimized | +6.3% |
| pairs | optimized | +4.7% |
| interp | optimized | +4.2% |
| tables | optimized | −10.5% |
| tokens | optimized | −12.5% |

Without `wrapped`, optimized is −0.03% against step 6. `wrapped` loses
because O2 now sees its `State`'s list size as a local's value. IndVars
turns the unrolled hash loop's eight index checks into compares against a
`umin` of exit counts. `Range_checks` joins only checks of the form
`icmp ult index, size`, so 18 checks stay in the loop (3 in the baseline),
and the SLP vectorizer leaves it scalar. The other losses keep the
baseline's number of checks, so their causes are elsewhere.

## Outcome

The experiment is not merged. Its code stays on the branch
`claude/exciting-sagan-cre7ap`, off unless `ZANE_HELD_ALLOCAS=1` is set.

- **Step 6 is a small net gain.** Optimized builds are 0.36% faster
  overall and tiered builds 0.68%. Most of that comes from `pushes`
  (−13.4%), `bits` tiered (−16.7%) and `paths` (−5.4%); `refills` (+3.8%)
  and `scopes` (+3.2%) get slower.
- **The late pass (step 7) loses.** It is +2.36% optimized against step 6,
  almost all of it from `wrapped`, and a wash without that program. It is
  dropped.
- **Nothing is generalized.** `frame_shadow` still gains on top of step 6
  (step 6), so it stays, and the experiment would add a second mechanism
  beside it, not replace it.
- **The cost is too high for the gain.** Merging would add a rewriting pass
  that every change to how held locals are emitted or drained must keep
  sound, changes to checked drains and to the inline push's fast path, and a
  spec divergence (held locals on the 8 MiB machine stack, under a 256-byte
  cap).

The design changed from the plan: the runtime is unchanged, and no CGT
pinning pass was added. A call is given the frame slot around it instead
(step 2), and the escapes are found in the LLVM IR.

Not done, since the experiment is not merged: the `Loop_pushes`
member-by-member store A/B, the size cap's tuning, a full `just
test-compiler` run with the late pass on, and the divergence entry in
`docs/spec-divergences.md`.

Worth following up without the experiment: the `pushes`, `bits` and
`paths` gains may be within reach of a targeted change to `frame_shadow` or
`Loop_pushes`, which keeps held locals in their frames.
