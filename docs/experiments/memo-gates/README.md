# Memo gates that cost nothing once they stop

A remembered function's gate (docs/design/memoization.md M2) reads the
function's score on every call and calls the lookup or the plain copy. Two
ways to make that cheaper once the function has stopped looking, each
behind a switch read when compiling (both since removed: see Outcome):

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
- The route is thread-local exactly when the score is, so each thread
  still stops on its own.

**Correctness.** The whole `just test-compiler` suite passes with each
switch on (in a build directory of its own, with Dune's cache off); every
measured program prints the same in every build and variant.

**Results.** `measure.py` on the 21 programs (`corefib` needs `core`,
which this run did not pass). Full tables: `results/fib.txt`,
`results/euclid.txt`, `results/salted.txt`. `lever/memo` is the lever
against the memo build without it:

| program | build | memo vs no memo | preserve vs memo | route vs memo |
| --- | --- | --- | --- | --- |
| linear | optimized | −97.88% | +12.16% | |
| overlap | optimized | −78.93% | +11.64% | |
| loopleaf | optimized | −93.03% | +9.75% | |
| ttt | tiered | −94.12% | +5.44% | +0.63% |
| linear | tier0 | −97.72% | | −0.46% |
| overlap | tier0 | −82.32% | | −1.34% |
| phase | tier0 | −30.66% | | +3.68% |
| moves | tier0 | −99.56% | | +1.84% |
| shallow | optimized | +4.14% | +0.31% | |
| salted | optimized | +0.30% | +0.03% | |
| tttpath | optimized | +0.30% | +0.01% | |
| leaves | optimized | +0.23% | +0.02% | |
| salted, shallow, shallowin, tttpath, leaves, loopcold, random | tier0 | +0.04% to +0.20% | | −0.01% to +0.02% |

- **Preserve costs where memo pays.** A program that hits often runs its
  lookup on most calls, and a `preserve_most` lookup saves and restores
  every register it touches, and every caller-saved one around its call of
  the body: up to 12% more. On the programs memo loses on, it changes
  nothing (±0.03%).
- **Route moves tier 0 by −1.3% to +3.7%** where memo pays, from code
  placement and the extra hop through a slot's entry, and by nothing
  measurable where memo loses.

**Why neither lever moves the losses.** On `salted` optimized, the memo
build runs 10,401, 10,425 and 10,422 instructions more than the build
without tables at sizes 22, 24 and 27, while the program's own work grows
eightfold. The whole loss is a fixed cost: the lookups made before the
function stops looking. After it stops, its gate costs nothing that
Callgrind can see, so there was nothing left for the levers to remove.
`shallow` optimized's +4.14% is the same fixed cost, about 40,000 cycles,
against a program LLVM folds to under a million.

## What remains

- **The warm-up is the cost.** Carrying the verdict across builds (a
  function that stopped looking gets no table in the next build `zane run`
  caches) removes it, and lets LLVM fold `shallow` again; or a lookup on
  every Nth call until the first hit shrinks it.
- Neither switch is worth keeping: preserve loses up to 12% where memo
  pays, and route gains nothing.

## Outcome

Both switches are removed from the compiler. The code they switched is in
commit `808fb4f` (`lib/codegen/memos.ml`, `lib/codegen/tiers.ml`,
`lib/codegen/build.ml`, `lib/cgt/ref32.ml`), and `measure.py` reproduces
the tables against a compiler built from it. `docs/design/memoization.md`
M3 records the finding: a gate that has stopped looking costs nothing
measurable, and what a program whose arguments never repeat pays is the
warm-up.
