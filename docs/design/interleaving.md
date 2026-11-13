# Interleaving independent walks

**Status: proposed, not built.** This is the design for the maintainer's
review. Interleaving itself is not in the compiler. Its prerequisite, writing
out a search a loop calls (I8, "Walks in functions"), is: lowering.md L11.

A loop whose every iteration walks a chain (a tree lookup, a short linked
list, a binary search, a hash probe that runs on) waits on one miss per
step, and the next step's address is the miss's own value, so neither the
processor nor a prefetch can start it early. Iterations of such a loop are
often independent, and then W of them can be in progress at once: each
takes one step, fetches what its next step will read, and gives way to the
next. The model measured this as the largest gain of any form it tried:
×3 to ×10 on data beyond the cache, never slower from 32 MiB up in any
placement of the nodes, and about 25% slower on short chains that fit in
cache ([`prefetch-reorder`](../experiments/prefetch-reorder/README.md),
rounds 1 to 4). This document says which loops get the form, why each
condition is what Zane's rules let the compiler prove, what the loop
becomes, and where the gate on the data's size goes.

The form is the model's `amac` (rounds 1, 2 and 4): W walks in progress, a
finished one's place taken at once by the next iteration. It is what is
proposed; the batched form (`group`), which waits for all W to finish,
lost to it everywhere and was slower than plain code on lists built in
order.

## I1. The loops that qualify

A counted `repeat` (`Stat.Repeat`) qualifies when all of the following
hold. The shape conditions are what the transformation needs; the effect
conditions are what make the iterations independent, so that running them
interleaved computes what running them in turn does.

**Shape.**

- Its counter is found as `Loop_shapes.counter` finds it, stepping by 1,
  and nothing in the body leaves the loop itself: no `return` from the
  function and no `leave` of a block outside the loop. The body may leave
  expansions inside it, which is how a walk ends (I3).
- Its body holds a *walk*: an inner `repeat`, bounded by its own count,
  that reads an element of a list at an index made from the element the
  same walk read on its previous trip (`c = links[c].next`,
  `c = nodes[c].left`), the chain condition `Lookahead` already tells
  apart (`reads_element`). A probe that steps by arithmetic gets nothing
  from interleaving that the lookahead prefetch does not already give it,
  and is left to that.
- The walk runs in the loop's own body, or in a verb written out there
  (L11). Zane has no `break`: a search `return`s from inside its loop, and
  work after it sits after a call to the verb that performs it
  ([`control-flow.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/control-flow.md)
  §3.5), so a walk is ordinarily its own verb. A loop's body writes out a
  small function it calls that reads what it is given and calls itself
  nowhere (a walk, lowering.md L11), so such a walk is in the body by the
  time this pass sees it (I8).
- The lists the walk reads have handles the top of the loop can read, as
  for the lookahead prefetch: their addresses are made of slots bound
  before the loop.

**Independence.** Iteration *k* may not read anything iteration *j < k*
writes, nor write anything *j* reads or writes, except through the forms
below that are combined afterwards. The standard is the one the spec sets
for the compiler's own parallelism: work the effect system proves
non-conflicting may be rescheduled, and doing so "must not change output,
only timing"
([`concurrency.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/concurrency.md)
§2.1). A call that writes nothing and touches no capability-backed state is
one "the compiler may reorder"
([`effects.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/effects.md)
§8.1); interleaving reorders the parts of iterations, which the conditions
below make such work.

- *What a call writes.* A call in the body is to a function or a method
  without `mut`, which writes nothing its caller can see
  ([`effects.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/effects.md)
  §3, §8.1), and whose body, and every body it calls, touches no
  capability-backed state (§5.2): the conditions memoization already
  checks for a table (`docs/design/memoization.md` M1), whose analysis is
  reused rather than written again. A call with no body here, through a
  function value, into C or to a `mut` method rules the loop out.
- *What the body writes.* Besides locals it binds itself, which are each
  iteration's own, the body may write only:
  - an *accumulator*: a local bound before the loop that every assignment
    in the body sets to itself combined with a value by one operation that
    is associative and commutative on integers (`+`, `*`, `bitAnd`,
    `bitOr`, `bitXor`, `min`, `max`), and that nothing else in the body
    reads. Integer arithmetic wraps, so any order gives the same bits;
  - an element of a list at an index that is the counter plus a constant
    (`out[i] = r`), a different element each iteration, of a list the walk
    does not read.
  Everything else rules the loop out: a push, a removal, an assignment of
  an outer local by any other rule, a write through a `mut` subject other
  than these, a spawn or a join, and any output.
- *Floats.* A float accumulator is not associative, so it is combined in
  iteration order (I4) rather than ruled out.
- *Aliasing of the written list and the walked ones.* Two element places
  of one list overlap whatever their indices, and a place reached through an
  `&` field, an `&` element or a returned reference may be any object of its
  type
  ([`memory.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/memory.md)
  §2.9.1). The written list therefore has to be provably not one the walk
  reads. §2.9.1 gives the cases that need no analysis: a place the function
  owns lies inside no object a reference reaches, and the subject and the
  bare parameters of a call are kept apart from what the call writes by the
  call's own check. So a list the function owns, or its `mut` subject, is
  apart from a list a bare parameter or another owned slot names; an `&T`
  parameter is apart from the subject when the signature records the pair.
  Two lists reached through `&` fields of one object may be one list
  (`this.left!push(this.right[Int(1)])` is refused for that reason) and
  rule the loop out unless their element types differ. Value types hold no
  references (§2.10), so a value-typed list in a slot of its own is the
  plain case.
- *Other threads.* While a spawned call holds a mutable borrow of a place,
  the spawning scope may not touch it
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/concurrency.md)
  §4.3), and a spawned call writes only through a value-typed subject
  (§4.2). So nothing the loop reads changes under it while it runs, and
  reading a node earlier than the plain loop would read it sees the same
  value. This is what C cannot prove about a pointer it was given: in Zane
  the walked structure is read-only for the loop's whole run by
  construction, not by analysis of what else might hold a pointer to it.

## I2. The loop body as a state machine

The body is split at its walk into three parts, each a straight run of
CGT statements:

- **start**, the statements before the walk, for one iteration's index;
- **step**, one trip of the walk's body;
- **finish**, the statements after the walk.

Each iteration's *state* is every local that is live from one part to the
next: the walk's cursor, the locals the walk carries from trip to trip
(its own partial sum in `chains`), and the locals start binds that finish
reads (the key in `tree`). The pass computes this set from the CGT, which
names every local, and refuses a loop whose state is larger than 64 bytes,
since W of them sit in a frame.

The transformed loop, in CGT terms (`Expr.Array` of W states in a light
scope's frame, `Array_at` to reach one, a `Switch` on a slot's stage):

```text
next = first index; live = 0
for s in 0 .. W-1:                     -- fill
  if next <= last: run start for next into slot s; prefetch its first node
                   stage[s] = walking; live += 1; next += 1
  else stage[s] = empty
s = 0
while live > 0:                        -- one step of one walk per turn
  if stage[s] == walking:
    run one trip of step on slot s's state
    if the walk left (I3):  run finish on slot s's state
                            if next <= last: start next in slot s, prefetch
                            else stage[s] = empty; live -= 1
    else: prefetch the element the next trip reads
  s = s + 1 == W ? 0 : s + 1
```

Round 3 showed that every miss of an iteration should be a step, the
loads before the walk included: `combo`'s record, loaded when its walk
started, cost the interleaved loop a third of its gain. So start only
prefetches what it would read first, and its loads become the first step:
a body with several misses before or between walks gets one stage per
miss, and `stage[s]` says which runs next. The model's `staged` form
measured within 10% of the best way to do this and needs no distance to
tune.

A step that does not miss costs the same as before, plus the load and
store of the slot's state, which LLVM keeps in the frame. The cost model
in I5 is what keeps that from showing on data that fits in cache.

## I3. How a walk ends, and how the loop stops

**Leaving a walk.** A walk ends when its count runs out or when it leaves
its expansion (a written-out verb's `return`). Either moves the slot to
finish. A leave out of the loop itself rules the loop out (I1), so no
walk can end the whole loop early.

**A failed index check.** The spec leaves what an index outside its list
does to the implementation
([`control-flow.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/control-flow.md)
§5.2); this compiler stops the program (`zane_out_of_range`, "index out of
range", exit 1), and the interleaved loop does the same.
Interleaved, iteration *k+3* may take a step before iteration *k* takes
the step that fails, and so may be the one that stops the program instead.
That is not observable: the body writes nothing outside the loop's own
state (I1), the program writes nothing more after a stop, the message and
exit status are the same whichever iteration stops it, and buffered output
from before the loop is flushed, or not, the same way. A later iteration
whose plain run would never have started (because an earlier one stopped
the program) may read memory first, but every read it makes is checked,
so it can stop the program and cannot fault. Every walk is bounded by its
count, so no iteration that the plain loop never reached can keep the loop
from ending.

**An abort.** A call with an abort that leaves the loop, as a `?`
handler's `abort` or `return` does, ends the function at iteration *k*
with the writes of every iteration before *k* made and none after
([`error-handling.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/error-handling.md)
§4). Interleaved, later iterations may already have added to an
accumulator. The first version rules out a body with any abort that can
leave the loop; an abort a handler `resolve`s inside the body is a value
like any other and is allowed. Iteration-ordered retirement (I4) is the
way to allow the rest later: an abort is retired in its iteration's turn,
and no later iteration's writes have been made by then.

## I4. Results in iteration order

An integer accumulator is combined as each walk finishes, in whatever order
that is. A float accumulator, and (later) an abort or an ordered write
such as a push, has to be applied in iteration order. For those, finish
writes its contribution into a ring of R entries indexed by iteration
number modulo R, and the loop retires entries from the oldest unretired
iteration onward as they fill. Start does not begin an iteration more than
R past the oldest unretired one; with R = 4W a slow walk holds up at most
that much. Retiring costs a load, a compare and a store per iteration. The
first version builds the ring only for float accumulators; whether the
rest is worth it is open (I8).

## I5. The size gate

Interleaving costs about 25% on short chains in cache (`chains` at
256 KiB: ×0.74 to ×0.79) and pays from 32 MiB up; long, branchy walks
(`tree`, `bsearch`) gain even in cache (×1.3 to ×2.0), because the
interleaving overlaps their mispredicted branches as well as their misses.
The gate is at run time, at the loop's entry, and the plain loop is
emitted beside the interleaved one as a versioned loop's copies are:

- the loop runs plain when its count is below 2W, since filling and
  draining W slots costs more than so few walks gain;
- it runs plain when the bytes of the lists its walks read, count times
  stride summed over them, are below a threshold, and interleaved above.

The threshold is not known yet: the model measured 256 KiB and 32 MiB and
nothing between. Before the pass lands, the sweep the model ran for
`heavyx` (64 KiB to 256 MiB in powers of two) is run for `chains` and
`tree`, and the threshold is set where the plain and interleaved times
cross, with the L2 size (2 MiB per core here) as the expected answer. Long
walks may need no gate at all; a walk is long when its count is above 16
and it branches on what it reads, as `tree`'s does, and whether that
earns it its own rule is for the sweep to say.

W is 32 by default: the model's best is 32 to 128 with little between
them, and 32 states of 64 bytes are 2 KiB of frame.

## I6. Where it goes

A CGT-to-CGT pass in `lib/codegen/`, `interleave.ml`, run before
emission on each function of an optimized build, beside
`Loop_shapes` and `Lookahead`, which supply the counter, the walk test and
the list addresses. Writing the result as CGT, rather than in `Emit`, keeps
`Emit` as it is and lets the result be read with `zanec --cgt` and held to
a golden file. It needs one node CGT does not have, a prefetch, which is a
new `Stat.Prefetch of Expr.t` that `Emit` lowers to `llvm.prefetch` (the
lookahead prefetch would move onto it too). The effect conditions (I1) read
the same facts memoization reads, which the pass gets from the program
rather than computing again. `ZANE_INTERLEAVE=0` turns it off, as the
experimental passes beside it are turned off.

## I7. How it is tested and measured

- `tests/objects/facts_test.py` and a fixture: a `tree`-shaped loop is
  interleaved in an optimized build and not in a plain one; each rule of
  I1 has a loop that breaks it and is left alone; a walk that reads out of
  range stops the program with the plain loop's message and status; a
  float sum gives the plain loop's bits.
- The CGT of one interleaved loop held to a golden file.
- `docs/experiments/prefetch-reorder/programs/`: `tree`, `chains` and a
  `combo` program, plain against interleaved, paired run by run, at
  256 KiB, 32 MiB and 2 GiB, and the gate sweep of I5.
- `tests/perf` measures estimated cycles, which cannot show the gain
  (Callgrind runs misses one after another) and will show the extra
  instructions; a program it slows is checked against the wall clock
  before the pass lands.

## I8. Open questions for review

- **Walks in functions. Decided and done.** The maintainer made writing
  functions out a prerequisite of this pass, and it is built (lowering.md
  L11, "walk"): a call in a loop's body writes out a function that is given
  a list or reference to read, writes none of it, takes no owner, calls
  itself nowhere, declares no abort and is at most 120 nodes. A `return`
  inside its loop leaves only the copy, and nothing inside a walk is
  written out as one again. `tree`'s `find`, `hash`'s `probe` and
  `chains`' `walk` are now plain functions in the benchmarks and are
  written out where their loops call them.
- **Ordered effects.** Should the first version build retirement (I4) for
  pushes and aborts too, which would let loops that build a result list
  in order qualify, or wait until a program needs it?
- **Huge pages.** The model found them worth ×2 to ×2.7 on light loops by
  themselves, which no transformation here gives. They are a runtime
  change (`madvise` on large blocks) and independent of this pass, but
  they multiply its gains; they could be the next step instead.
