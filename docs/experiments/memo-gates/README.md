# Memo gates that cost nothing once they stop

A remembered function's gate (docs/design/memoization.md M2) reads the
function's score on every call and calls the lookup or the plain copy. Two
ways to make that cheaper once the function has stopped looking, each
behind a switch read when compiling:

- `ZANE_MEMO_PRESERVE=1`: the lookup uses LLVM's `preserve_most` calling
  convention, so a caller keeps its registers across it, and the inlined
  gate's lookup call stops shaping the code around it.
- `ZANE_MEMO_ROUTE=1`: each remembered function has a route, a variable
  holding the address tier 0's gate calls: the lookup at first, and the
  plain copy once the lookup sees the score reach the limit. Tier 0's gate
  is then a load and a call, with no score read. Other builds keep their
  gate; their lookup still sets the route, which nothing reads.

The two exclude each other: a call through the route cannot know which
convention its target uses, so `ZANE_MEMO_ROUTE` turns the other off.

Measured with `measure.py` (estimated cycles, `tests/perf/run`'s formula)
on `dev/bench/memo/programs`.

## Step 1: both levers

**Design.**

- `lib/codegen/memos.ml`: the lookup's convention and its call site's
  (preserve); the route variable, thread-local when the score is, and a
  store of the plain copy into it wherever the lookup writes a score at or
  past the limit (route).
- `lib/codegen/tiers.ml` `route_gates`, run by `lib/codegen/build.ml` on
  tier 0 before its passes: each gate's body becomes a tail call through
  its route. Tier 0's slot pass then makes the route's addresses uses of
  entries that call through the functions' slots, so tier 1 still takes
  them over.
- With the route, a thread's stop now stops every thread when the score
  is thread-local only if the route is too; it is, so each thread stops on
  its own as before.

**Results.** Pending.
