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
  and nothing before the end of the walk half leaves the loop itself: a
  `return` from the function, a `leave` of a block outside the loop and a
  `?` handler that aborts or returns sit in the retire half, or are staged
  into it (I3). The body may leave expansions inside it, which is how a
  walk ends.
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

**Two halves of an iteration.** The body is split into the part that may
run out of order and the part that may not. The *walk half* is every
statement up to and including the walk and what follows it while it
writes only the iteration's own locals; the *retire half* begins at the
first statement after the walk that writes a place outside the iteration
(an outer local, a field, a list) or leaves the loop, and runs to the end
of the body. The walk halves of W iterations interleave (I2); the retire
halves run one at a time, strictly in iteration order (I4). So a loop
whose iterations depend on each other only through what their retire
halves do qualifies: a sum of any type, a push, a write to `out[i]`, a
running maximum that the next iteration's retire half reads, and an
abort. What the interleaving reorders is the walk halves only,
and the conditions below are what make that unobservable. The standard is
the one the spec sets for the compiler's own parallelism: work the effect
system proves non-conflicting may be rescheduled, and doing so "must not
change output, only timing"
([`concurrency.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/concurrency.md)
§2.1). A call that writes nothing and touches no capability-backed state is
one "the compiler may reorder"
([`effects.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/effects.md)
§8.1).

**Independence.** For every *j < k*, iteration *k*'s walk half may run
before *j*'s retire half, so:

- *The walk half writes only its own locals.* It binds them, and nothing
  else in it is a write: no assignment of an outer local or a place, no
  `!` call, no push. A write placed before the walk cannot simply be moved
  into the retire half, since the walk may read it, and rules the loop out.
- *The walk half reads nothing a retire half writes.* This is the one
  condition that ties iterations together, and it is what still rules a
  loop out: a walk over a list the loop pushes onto, a probe of a table the
  loop inserts into (`seen` while it is filled), a search bounded by a
  running total. Each place the retire half writes is held apart from each
  place the walk half reads under the overlap rules below; a local is
  apart from every other place by its name.
- *What a call in the walk half does.* A call there is to a function or a
  method without `mut`, which writes nothing its caller can see
  ([`effects.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/effects.md)
  §3, §8.1), and whose body, and every body it calls, touches no
  capability-backed state (§5.2): the conditions memoization already
  checks for a table (`docs/design/memoization.md` M1), whose analysis is
  reused rather than written again. A call with no body here, through a
  function value or into C rules the loop out.
- *What the retire half does.* It runs in order, so it may read and write
  anything the plain body could, with three limits. It writes only
  memory: an outer local, a field or element of a place the function owns
  or lends, a push or a removal on such a list, through assignments and
  `!` calls whose bodies the effect analysis sees. It touches no
  capability-backed state (output, input, the clock), because a later
  iteration's walk half may stop the program before this retire half runs
  (I3), and a line printed by the plain loop would then be missing. And it
  holds no walk of its own, which would be a loop in order, not one this
  pass gains on.
- *Spawns and joins* anywhere in the body rule the loop out.

**Which retire halves skip the ring.** A retire half that only combines
integers into accumulators needs no order, and the pass applies it as each
walk finishes rather than in turn (I4). It qualifies when every statement
in it is `a = a ⊕ e` where `a` is a local of the function, of an integer
type, that nothing else in the loop reads or writes, `⊕` is `+`, `*`,
`bitAnd`, `bitOr`, `bitXor`, `min` or `max`, and `e` reads only the
iteration's own locals; or a store to an element at the counter plus a
constant (`out[i] = r`) of a list nothing else in the loop touches; and
when nothing in the loop can leave it (an abort or a `return`). Integer
arithmetic wraps, so each `⊕` is associative and commutative on the
machine's integers and any order of the same terms gives the same bits; a
store to a different element each iteration lands where it would in any
order. Nothing reads `a` or the stored elements until the loop ends, and a
value local has no reference another place could read it through (a
reference is minted only from a settled owner,
[`memory.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/memory.md)
§2.8), so no intermediate value is observed. If the program stops part way
(I3), what the loop wrote to memory is never read: the process ends. A
float sum, a push and anything that reads what an earlier retire half
wrote keep their order.

**Overlap.** Two element places of one list overlap whatever their
indices, and a place reached through an `&` field, an `&` element or a
returned reference may be any object of its type
([`memory.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/memory.md)
§2.9.1). A list the retire half writes therefore has to be provably not
one the walk half reads. §2.9.1 gives the cases that need no analysis: a place the function
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

**Other threads.** While a spawned call holds a mutable borrow of a place,
the spawning scope may not touch it
([`concurrency.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/concurrency.md)
§4.3), and a spawned call writes only through a value-typed subject
(§4.2). So nothing the loop reads changes under it while it runs, and
reading a node earlier than the plain loop would read it sees the same
value. This is what C cannot prove about a pointer it was given: in Zane
the walked structure is read-only for the loop's whole run by
construction, not by analysis of what else might hold a pointer to it.

## I2. The loop body as a state machine

The body is split at its walk into four parts, each a straight run of
CGT statements:

- **start**, the statements before the walk, for one iteration's index;
- **step**, one trip of the walk's body;
- **finish**, the statements after the walk that belong to the walk half
  (I1): they bind the iteration's own locals and nothing else;
- **retire**, the retire half, run in iteration order (I4).

Each iteration's *state* is every local that is live from one part to the
next: the walk's cursor, the locals the walk carries from trip to trip
(its own partial sum in `chains`), the locals start binds that finish
reads (the key in `tree`), and the locals retire reads, which are the
iteration's *outcome*. The pass computes this set from the CGT, which
names every local, and refuses a loop whose state is larger than 64 bytes,
since W of them sit in a frame and R outcomes in a ring (I4).

The transformed loop, in CGT terms (`Expr.Array` of W states in a light
scope's frame, `Array_at` to reach one, a `Switch` on a slot's stage):

```text
next = first index; live = 0; oldest = first index
for s in 0 .. W-1: stage[s] = empty
refill                                 -- fill
s = 0
while live > 0:                        -- one step of one walk per turn
  if stage[s] == walking:
    run one trip of step on slot s's state
    if the walk left (I3):  run finish on slot s's state
                            write its outcome to ring[its index mod R]
                            stage[s] = empty; live -= 1
                            retire (I4)
                            refill
    else: prefetch the element the next trip reads
  s = s + 1 == W ? 0 : s + 1

refill:                                -- used by fill and after a finish
  for each slot s with stage[s] == empty:
    while stage[s] == empty and next <= last and next < oldest + R:
      run start for next into slot s; next += 1
      if the walk has no trips: run finish, write the outcome, retire
      else: prefetch its first node; stage[s] = walking; live += 1
```

A walk with no trips is finished at start and never takes a slot, so
refill keeps starting iterations until each empty slot holds a walk with
a trip or none can start; `live` is 0 only once every iteration is done.

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
finish. A leave out of the loop itself happens only in a retire half
(below), which runs in order, so no walk ends the whole loop early.

**A failed index check.** The spec leaves what an index outside its list
does to the implementation
([`control-flow.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/control-flow.md)
§5.2); this compiler stops the program (`zane_out_of_range`, "index out of
range", exit 1), and the interleaved loop does the same.
Interleaved, iteration *k+3* may take a step before iteration *k* takes
the step that fails, and so may be the one that stops the program instead.
In a loop that cannot leave by an abort or a `return`, that is not
observable: every write a walk half makes is to its own locals, every
write a retire half makes is to memory (I1), the program reads none of it
after a stop, the message and exit status are the same whichever
iteration stops it, and buffered output from before the loop is flushed,
or not, the same way. A later iteration whose plain run would never have
started may read memory first, but every read it makes is checked, so it
can stop the program and cannot fault. Every walk is bounded by its
count, so no iteration that the plain loop never reached can keep the
loop from ending.

In a loop that can leave, which iteration stops first is observable: the
plain loop may return an error at iteration *k* where the interleaved one
would stop the program at *k+3*. There a failed check in a walk half is
*staged*: instead of stopping, the check writes "stopped" as the
iteration's outcome and ends its walk, and retiring that outcome, in its
turn, stops the program. The check is the same branch as before; only its
far side changes. A call in the walk half of such a loop that is not
written out could stop the program inside its own body, where nothing can
stage it, and rules the loop out.

**An abort or a return.** A call with an abort that leaves the loop, as a
`?` handler's `abort` or `return` does, ends the function at iteration *k*
with the writes of every iteration before *k* made and none after
([`error-handling.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/error-handling.md)
§4). A walk half calls only functions that write nothing (I1), so such a
call there is staged too: its result, a value or an error, is part of the
outcome, and the `?` handler runs in the retire half. A `return` written in
the body is in the retire half by I1's split. Retired in order, the abort
or return of iteration *k* runs after the retire halves of every iteration
before *k* and before any after it, which is exactly the plain loop's
writes; the later walk halves that already ran wrote only their own
locals, which the leave throws away. An abort a handler `resolve`s inside
the body is a value like any other.

## I4. Results in iteration order

Retirement is one mechanism for everything the decision in I8 lists:
float and integer sums, pushes, writes to `out[i]`, running values that the
next retire half reads, and leaves. Finish writes the iteration's outcome,
the locals the retire half reads plus its stage ("done", "stopped", or a
staged error), into a ring of R entries at index *i* mod R. The loop keeps
`oldest`, the first iteration not yet retired, and after each finish
retires forward from it while its entry is full: run the retire half on
the entry's locals, clear the entry, add 1 to `oldest`. A "stopped" entry
stops the program; an error runs its handler, which may leave.

Start does not begin iteration *i* while *i ≥ oldest + R*, since its entry
would overwrite one not yet retired; a slow walk holds up at most R
iterations behind it while the others run, and with R = 4W that is
rarely felt. A slot left empty while the ring was full is refilled as
soon as retiring moves `oldest` on. The loop cannot stall: if every slot
were empty with iterations left, every started iteration would have
finished and been retired, so `oldest` would equal `next` and the ring
would have room. Retiring costs a load, a compare and a branch per
iteration, and a copy of the outcome, which is at most the 64 bytes of
state (I2).

A retire half that qualifies to skip the ring (I1) runs straight after
finish, in completion order, with no entry and no `oldest`. That is the
common integer case (`tree`'s count of keys found, `chains`' sum), and it
costs nothing over the model's form. The pass decides it from the CGT
alone, by the syntactic rule I1 gives: every statement of the retire half
is an integer `a = a ⊕ e` on a local nothing else in the loop touches or
a store to a fresh element of a list nothing else touches, and the loop
cannot leave. Anything else goes through the ring.

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
  I1 has a loop that breaks it and is left alone (a walk over a list the
  loop pushes onto, a probe of a table the loop inserts into, a write
  before the walk, a print in the retire half, a walk-half call through a
  function value); a walk that reads out of range stops the program with
  the plain loop's message and status; a float sum gives the plain loop's
  bits; a loop that pushes what its walks find builds the plain loop's
  list in the plain loop's order; a store to `out[i]` and an integer sum
  skip the ring and a float sum does not, read off the CGT; a loop whose
  `?` handler returns at iteration *k* returns *k*'s error with the
  writes of every iteration before *k*, also when a later iteration's walk
  reads out of range.
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
- **Ordered effects. Decided.** The first version handles anything that
  can be done in batch: the body splits into a walk half that runs out of
  order and a retire half that runs strictly in iteration order (I1), and
  retirement is one general mechanism, a ring of outcomes (I4), that
  carries integer and float sums, pushes, writes to `out[i]`, and aborts
  and returns, staged so the first failing iteration in source order is
  the one that leaves (I3). Integer accumulators and stores to fresh
  elements skip the ring by a syntactic rule, proved in I1. What still
  rules a loop out is listed under I1's independence conditions.
- **Huge pages.** The model found them worth ×2 to ×2.7 on light loops by
  themselves, which no transformation here gives. They are a runtime
  change (`madvise` on large blocks) and independent of this pass, but
  they multiply its gains; they could be the next step instead.
