# Optimization: folding at compile time

> **Status: built.** Stage 5 runs one pass, compile-time evaluation, which
> follows this design, and leaves to LLVM what LLVM does (O11). Each
> decision is numbered (**O1**…). §4 says how it follows the spec's rule,
> and §6 what is left to measurement.

Stage 5 rewrites the CGT into a faster CGT ([`stages.md`](stages.md)). Its
pass evaluates, while the compiler runs, everything the program would compute
the same way every time it runs, and writes the results into the tree in
place of the code that computed them. Evaluation starts at the leaves of the
tree and works up: an expression whose inputs are all known is replaced by its
value, and its parent is tried next with that value as an input. It stops
where a value depends on something only the running program has, such as
the arguments it was started with.

---

## 1. Where it runs

**O1. Stage 5 is a library of its own, over the CGT.** `lib/optimize/` takes
the program lowering made and gives back a program of the same tree, so
codegen reads an optimized and an unoptimized program alike. It works on the
CGT rather than the TST because the CGT is what runs: every function in it is
one instance (L4), block-taking and expression verbs are already written out
where they are called (L11), and it holds the functions the TST never had, such as package
constants' makers and lifted lambdas.

| Module | Holds |
|---|---|
| `intrinsics.ml` | What each runtime function is to a fold (O3) |
| `value.ml` | The values the evaluator computes with, and its memory (O5) |
| `eval.ml` | The evaluator: CGT run at compile time (O5, O6, O8) |
| `materialize.ml` | A computed value written back as CGT, and an output as the call that makes it (O4, O7) |
| `constants.ml` | The package constants that fold (O9) |
| `fold.ml` | The walk over each function (O6) |
| `optimize.ml` | The entry: constants, then every function |

**O2. Only an optimized build runs it.** The driver runs stage 5 between
lowering and codegen when `--optimize` is given, before LLVM's own `-O2`
pipeline, and an unoptimized build skips it. `zane run` starts the program
as an unoptimized build and moves it to a lighter optimized one that skips
stage 5 too ([`tiers.md`](tiers.md) T2), so it never waits on the evaluator. `zanec --cgt --optimize` prints the tree
stage 5 made, which is how the tests see what folded (§5).

**O12. Each kind of build puts one speed first.** An optimized build makes
the fastest program it can in a reasonable compile time, and is then made to
build as fast as it can without the program running any slower: a change that
shortens it at the cost of the program's speed, such as a lighter LLVM
pipeline, is not made. Tier 1 of a tiered build ([`tiers.md`](tiers.md)
T2) is the third kind: an optimized build that puts its own arrival first,
since tier 1 gains a program nothing once the program has ended. An
unoptimized build is what `zane run` starts the program as, tier 0, so it
answers to the time from the command to the program's result: its build stays
close to the fastest it can be, and it does whatever work pays that time back
at once. A pass belongs in it when it costs a build tens of milliseconds at
most, takes time in proportion to the instructions it reads rather than to the
size of a value they handle, and makes the programs it builds several times
faster, so that a program running for more than a fraction of a second
finishes sooner with it than without. Inlining is the clearest case: `core`
writes even `Int +` as a one-line wrapper over an intrinsic, and a build that
left every wrapper a call would run several times slower than one that
inlined it for the cost of a few passes. Lowering writes each such wrapper out
where it is called, in both builds (L11), and an unoptimized build inlines
what is left that is small with a pass of its own. This holds for every stage, codegen
and the link included, not only for stage 5.

**O10. Package boundaries do not block optimization.** In every build,
lowering follows calls into stamped dependencies and retains their bodies with
`Available` linkage. In an optimized build stage 5 can evaluate these calls,
including transitive calls, private helpers and named lambdas. LLVM receives
their bodies with `available_externally` linkage: its `-O2` pipeline, and the
lighter one an unoptimized build runs (O12), can inline arithmetic and other
wrappers even when their arguments are runtime inputs. The bodies themselves
define no symbols in the caller's object; any call left after optimization
links against the dependency's original object. Generic instances and package
constants keep their existing shared linkage. No new artifact, linker option
or package flag is required.

**O11. Stage 5 does what LLVM cannot, and LLVM does the rest.** LLVM's
`-O2` pipeline already folds constants, removes dead code, merges common
subexpressions, hoists what a loop does not change, unrolls, vectorizes and
inlines, and does each better for every target than a second pass here
would. So the compiler implements an optimization itself only when it rests
on something about Zane that LLVM does not know, and otherwise tells LLVM
what it knows and leaves the transformation to it
([`lowering.md`](lowering.md) §9, "What LLVM is told"). Where each piece of
work stands:

| Work | Where it is done, and why |
|---|---|
| Folding constants, choosing a known branch, dropping a loop that never runs (`fold.ml`) | Here as well as in LLVM: the evaluator needs these folds' results as its inputs, so they stay while it does |
| Running calls, lists, strings, boxes, runs of statements, output and spawned calls (`eval.ml`) | Here: LLVM cannot run the runtime's functions, and does not know O4's replay of output. Measured on the fixtures, LLVM alone leaves the list constructors, spawns and snapshots in `folding`, `runs` and `removalFolded` that stage 5 removes |
| Package constants (O9) | Here: a constant is made once, under the runtime's lock, and an unoptimized dependency shares its object, so it is not an immutable global LLVM could fold |
| Inlining | Lowering, for a verb whose body is one expression, in every build (L11): it knows from the source which verbs those are, and needs no cost model to write one out. LLVM, for the rest, seeing a dependency's bodies through O10 |
| Writing out block-taking verbs, generic instances, lambdas and spawn thunks | Lowering: a verb that takes a block has no function of its own to inline (L11) |
| Copies, scopes and results in the caller's region (`lib/cgt/regions.ml`) | Lowering: each rests on ownership and regions, which LLVM does not see |
| Each type's walks, frames and allocation fast paths | Codegen, which emits them as plain IR for LLVM to simplify further |
| Bounds checks, a list's count and block, a push | Codegen emits them as plain arithmetic and branches, tagged so LLVM can keep the header across element writes, and says which places and frames may be read ahead; LLVM drops the checks it proves redundant ([`lowering.md`](lowering.md) §9, "What LLVM is told"), and in an optimized build and tier 1 its IRCE takes them out of the main part of a long loop, which codegen emits twice and weights there ([`lowering.md`](lowering.md) §9, "The passes") |
| An `elif` after its `if` | LLVM's jump threading, run before the passes that make a branch a select, which makes the two one chain ([`lowering.md`](lowering.md) §9, "The passes") |
| A truncation, exact math | LLVM intrinsics (`llvm.fptosi.sat`, `llvm.sqrt`, …), which mean exactly what the spec says |
| Division | Codegen's guards around `sdiv`, which by itself does not give `operators.md` §2.6's results |
| Large aggregates (`lib/codegen/big_moves.ml`) | Codegen, since LLVM's code generator cannot move one at all, at either optimization level |

---

## 2. What folds

**O3. A value is known unless it depends on an input.** Every intrinsic
reaches the CGT either as ordinary nodes (an operator as a `Binary`,
`@controlflow$branch` as an `If`, a math function as a `Math`) or as a call
into the runtime, so a class for each runtime function and each math
function covers them all. `intrinsics.ml` gives one to each in an exhaustive
match, so a runtime function added later does not compile until it is
classified:

| Intrinsic | In the CGT | Class |
|---|---|---|
| scalar `+ * / == < ~`, `Bool` `+ * ==` | `Binary`, `Flip` | computed |
| `@math$` exact functions | `Math` | computed |
| `@math$` approximate functions, and `fma` on an `F32` | `Math` | input |
| `String` `+ ==`, `String(…)` | `Text_join`, `Text_equal`, `Text` | computed |
| `parseI64`, `parseF64` | `Parse_i64`, `Parse_f64` | computed |
| `List(T)`, `ListRef(T)`, `push`, `size`, `[]` | `List_new`, `List_push`, `Member`, `List_at` | computed |
| `remove`, `swapRemove` | `List_at` and a `Take`, then `List_remove` or `List_swap_remove` | computed |
| `Array`, `ArrayRef`, `fill`, `[]` | `Record`, a counted loop, `Array_at` | computed |
| `@controlflow$branch`, `repeat` | `If`, `Repeat` | computed |
| storage: slots, boxes, copies, moves, overwrites, scopes | the nodes and the runtime calls codegen makes for them | computed (O5) |
| `spawn` | `Spawn`, `Join`, `Snapshot`, `Writeback` | computed (O8) |
| package constants | `Constant_begin`, `Constant_end` | computed (O9) |
| `@runtime$print` | `Print` | output (O4) |
| `@runtime$setThreads`, `setThreadsAuto` | `Set_threads`, `Set_threads_auto` | output (O4) |
| `@runtime$arguments` | `Arguments` | input |
| a foreign handle a call into C gives | `Handle_made`, `No_object` | input |

`arguments` is the one intrinsic that reads input (effects.md §6.6), so a
fold stops where it is reached, and everything computed before it still
folds. `setThreadsAuto` reads the processor count, but gives nothing back, so
no value of the program depends on it. An intrinsic added later that reads
input, a console read or the time, joins `arguments` in the input class.
A foreign handle's stamp is an input as well: it is the next of a count
the running program keeps ([`ffi.md`](ffi.md) F12).

The approximate math functions are inputs for another reason: their result
is the C math library's where the program runs
([`math.md`](https://github.com/zane-lang/spec/blob/1457830/spec/math.md)
§2.6), which the compiler's own library need not match, so folding one could
change what the program computes. An `F32` `fma` is an input too: the
evaluator holds a float as a double, and a double `fma` rounded to a single
rounds twice. Every other `F32` function gives its single exactly that way.

Besides an input, a value is unknown when it is a parameter of the function
being folded, or what a function with no body available gives. Optimized
builds retain reachable stamped dependencies' bodies from the checked source
(`separate-compilation.md` C12), so their calls fold under the same rules as
local calls. Everything computed only from known values is known. Whether a function terminates is never analyzed: the
budget (O6) decides how far evaluation goes.

**O4. An output is replayed where it was made.** A call that prints while it
computes still folds. The evaluator records each output in order, and the
replacement makes the same calls, with their arguments folded, before it
gives the value: `loud(Int(21))`, which prints `computing` and returns `42`,
becomes a print of `"computing\n"` and then `42`. The output happens at the
same point and in the same order, so a program cannot tell it was folded. A
call that only outputs becomes the outputs alone. `setThreads` is replayed
the same way, with the count it was given; whether it aborted is already part
of what was computed.

---

## 3. How it is built

**O5. The evaluator models what a program means, not where its bytes are.**
`eval.ml` gives each CGT node the meaning `lib/codegen/emit.ml` gives it, and
each runtime function the meaning `runtime/` gives it. Memory is a set of
cells, each holding a structured value: a scalar, a string, a struct or array,
a sum, a list (each element a cell of its own), or an address. An address is a
cell and a path down to a part of it, a member or a case's payload, which is
how every address in the tree is made (`Address`, `Offset`, `List_at`,
`Array_at`). An address made by `Box` owns the cell it names; any other is
lent.

Where a value's bytes live is not modelled. Arenas, drains, the movement of
blocks between regions, and arrival are nothing at compile time, since no
program can tell one placement from another (`lowering.md` §9). What a
program can tell is modelled exactly, from the program's layouts: `Copy`
copies every list and box a value owns, `Take` leaves the place it moved out
of holding no list, string or box, and `Overwrite` writes the incoming
payload into each box the old value and the new one both have, so an address
into it still names it (`zane_overwrite`). A cell owns what it holds: a value
is copied in when it is stored and copied out when it is read, so a store
writes an element in place without changing a value read before it.

Arithmetic is codegen's: `I64` wraps, `I32` wraps at 32 bits, the most
negative value divided by `-1` wraps and an integer divided by zero gives zero
(`operators.md` §2.6), `F64` and `F32` are
IEEE with ordered comparisons, so a NaN is neither equal to nor less than
anything, an `F32` result is rounded to single precision once, and `Bool`
takes `or` and `and` as the machine does. A conversion folds by the rules
codegen emits (`Cgt.Nodes.Scalar`): an integer converted to an `F32` is rounded
once, not through a double first, and a float truncated to an integer
saturates, with a NaN giving zero. Every NaN folds to the same positive
quiet NaN: what sign and payload a NaN gets is the machine's, and no program
can tell one NaN from another. Constants are compared bit for bit, so a zero
and its negative, which a division tells apart, are two values.

**O6. Each function is folded from the leaves up, within a budget.**
`fold.ml` walks each function's body in the order it runs and keeps what it
knows: each local whose value is a constant at that point. Every function is
folded, whether or not anything calls it, so the constant code inside a
function that never ends still folds. A function is folded after the
functions it calls, the thunks it spawns and the functions it names as
values, except where calls form a cycle, and its folded body is
the one evaluation runs from then on. A call to a function that folded to
its outputs runs those outputs, not the code they came from, so `main`'s
work is done once, not again for the entry point that calls it.

- An expression is tried once its children are folded and all its inputs are
  known: constants, known locals, or addresses of them. If evaluating it
  finishes, it is replaced by its value, with its outputs before it (O4) and
  each known local it wrote stored back. A local bound by a plain `Let`,
  which holds no list, string or box, is stored back by an assignment. A
  value held in its scope's arena, such as a string, is stored back by an
  overwrite, which returns the blocks its old value owned, as an
  assignment to it does when the program runs; that takes a value whose
  addresses are never kept (below), so nothing still names those blocks.
  Code that writes any other local does not fold.
- A control statement, a loop, a branch or a switch, is run whole when the
  locals it reads are known. A loop over known values leaves only what it
  wrote: `counting`'s nested loop becomes its prints.
- A branch on a known condition becomes its body or nothing, a switch on a
  known case its one arm, and a loop with a count below one goes.
- Whatever does not fold stays as it was, and what it may write is not known
  after it: each local whose address it takes or that a pointer it names
  points into, every local it assigns, and, when it can write through an
  address, every local an address of which may be kept. A local of a value
  type keeps no address unless one is stored, returned or given to a
  spawned call. No reference names a value
  ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
  §2.4), and a borrow of one ends with its call (§2.9), so code given no
  address of it cannot write it, and what is known of it stays known past
  that code. A pointer local bound once to an address of a local stands for
  that local. Every address of a local of any other type counts as kept: a
  call it is lent to may leave a reference to it where other code finds
  it. That holds inside an expression too: a call left
  in place is not known past, by the operands and arguments after it or by
  the body of a condition it is part of. A loop's body is folded knowing nothing it writes,
  since one pass changes what the next starts with, and a body that leaves
  an expansion early ends at more than one place, so nothing it writes is
  known after it.
- A replacement removes the locals the folded code bound, so code that binds
  a local also named outside the run of statements binding it does not fold.
- A replacement that stores into a local is no parent's known input. The walk
  counts such a store as done once it is made, and evaluating the replacement
  again inside its parent would find nothing to store, so the parent's
  replacement would leave the store out. An expansion, and a control
  statement whose condition or count folded, is tried against what was
  known before it ran, for the same reason.
- A run of statements in one block is also evaluated as a whole, from its
  first statement as far as it goes. It is replaced where it ends having
  dropped a list or a box it made, which no single statement leaves known:
  a list made, changed in place and read by the statements after it. The
  replacement is the run's outputs, each known local it wrote stored back,
  and each local it bound that a later statement names bound to the value it
  holds there, which must be a constant holding no handle or address. The
  longest run that can end is taken. A run stops before a statement that
  returns or leaves an expansion it is not inside, and is not started again
  at a statement an earlier run went through, which would stop in the same
  place.

Evaluation stops, leaving the code as it was, when it reads an unknown
value, reaches an index out of range (the program must
still stop there when it runs, after what it wrote before), reaches the join
of a call spawned before the code being folded, would write a
variable of the program, gives a value that holds a lent address, or runs out
of budget. Three limits bound it, each counted in steps, so that the same
source folds the same way on any machine. Work that grows with a value's
size, joining strings, copying a list or a struct, growing a list, costs a
step for each 64 bytes, charged before the work is done, so a few steps
cannot build a value of any size. Each output costs the same way, by its
weight: its text's length and one more, so that an output with no text, a
`print("")` or a `setThreads`, still weighs something:

- one fold takes at most 5,000,000 steps;
- all the folds of a program take at most 50,000,000;
- calls nest at most 2,000 deep;
- the outputs of one fold weigh at most 65,536 together, the most a folded
  result may materialize to, and a fold that outputs more stops with
  "output too large to fold".

A replacement whose code would be larger than 64 KiB, its value, its outputs
and the locals it stores counted together, does not fold either, which keeps a cheap call that builds a large value out of the
binary. A call's result and outputs are remembered by its function and its
arguments when the function's body makes more than one call, when it and
the chain of unremembered calls below it weigh more than 64 (a node each,
and a step for each 64 bytes of every aggregate they make, reserve or
move), or when a loop, a spawn, a call through a value, a recursive call,
or work that grows with a value's size, a runtime function, a copy or an
overwrite, is reachable from it, so such a call made again with the same arguments costs
a lookup. Any other call runs a short chain of small bodies, fewer steps
than keeping and finding its result would, and runs again: `core`'s
arithmetic, which a loop calls with new arguments on every pass, is never
remembered. A call with constant arguments that did not fold is not tried
again. A
remembered call keeps how many outputs it made and the bytes of their text,
and replaying them is charged steps and counted against the output limit as
making them was, so a call that makes its previous level twice cannot output
twice as much at each level for free. A call whose outputs pass the limit
stops before it is remembered, so what is remembered is bounded by the step
budget.

**O7. A folded value is written as the code that builds it.**

| Value | Becomes |
|---|---|
| scalar | `Int`, `Float`, `Bool`, `Unit` |
| string | `Text`: the program's own bytes, room 0 (`lowering.md` §9) |
| struct, array, sum | `Record`, `Case` of folded members |
| boxed member | `Box` of its folded payload |
| list | an expansion that makes the list with `List_new` and pushes each folded element, placed with the element's layout |
| function value | `Function` |

A list made this way gets its block in the region of the innermost scope,
where a call's result arrives too, and then arrives or escapes from there like
any other value. Its handle sits in the expansion's own slot, which is in no
scope's chunks, and the runtime places the block of such a list in the
innermost scope's region. An `Escape` stays
where it is, with its value folded inside it, so a value leaving arenas still
leaves them. A read, of a local, a member or what an address names, is not
replaced by a list or a box made again, since the read is the cheaper of the
two.

**O8. A spawned call runs where it is spawned.** Inside code that folds, a
`Spawn` runs its call at once and its result is home when the call returns.
Spawned calls never race (`concurrency.md` §4), and running them in turn is
one of the orders the spec allows (§3.7). Outputs made by spawned calls are
replayed in that order.

**O9. Package constants fold first.** A constant's maker (`lowering.md` L16)
is run as the program runs it the first time the constant is read. A
constant whose maker finishes with no output has a known value, and since
making one may read another, the search repeats until a pass finds no new
one. A read of a known constant then folds wherever it is, like a known
local.

Where a constant is made stays as it is: whether this is the first read is a
fact of the running program, so the maker keeps its check, and the code that
makes the value folds inside it. `constants`' `later`, whose maker calls
`loud(Int(9))`, becomes a maker that prints `made` and stores `9`. A constant
whose value folds keeps its variable and its maker rather than becoming
static data. Every read of it folds, so the maker runs at most once, to store
a constant, and a library's constant is defined in every object that reads it
(`separate-compilation.md` C4), where an optimized and an unoptimized object
must agree on what its variables hold.

---

## 4. How it follows the spec

[`effects.md`](https://github.com/zane-lang/spec/blob/54b3566/spec/effects.md)
§5.3 lets a compiler evaluate at compile time any computation that depends on
no parameter of its verb and no read of capability-backed state, or leave it
for run time, and requires that doing so change none of the program's side
effects and nothing it computes: each write still happens at run time, at the
same point and in the same order. How is left to the compiler. Stage 5's answer is this document:

- what reads capability-backed state is an input (O3), and stops a fold;
- an output is replayed where it was made (O4), and a known local a
  computation wrote is stored back (O6), which is what keeps folding
  unobservable;
- the bound on work is O6's: the step budgets, the depth and the size cap.

Stage 5 leaves some such computations for run time, as §5.3 allows: a value
holding a lent address, an owner of a reference type, a list among them,
changed by code that does not fold with every statement that names it (only
values are stored back),
and a package constant's first-read check (O9).

---

## 5. How it is tested

`tests/codegen/` builds every fixture unoptimized and optimized and holds
both to one golden output, so every fixture checks that folding changes
nothing a program does. `golden/NAME.optimized.cgt` holds the tree an
optimized build makes, for the fixtures that show folding:

- `folding` folds each scalar at its edges and a zero's sign, strings, values
  and their copies, an abort, a list
  and a box built and measured inside a call, a list and a box a call gives
  and the program then changes, recursion, a `mut` call, a function value and
  spawned calls;
- `replayed` keeps output in order, leaves the calls past the budget, the
  depth and the size cap to run, reads a slot when the program runs after a
  store that folded, a count's included, knows nothing past a call left
  to run that writes a local, and knows a value that call is given no
  address of, a string a folded `mut` call stored back among them, but not
  an owner it reaches through a stored reference;
- `runs` folds a sieve as one run of statements, and keeps a list that is
  still named after the program's arguments are read;
- `math` folds every exact math function at its edges, and keeps the
  approximate ones and an `F32` `fma` as calls;
- `constants`, `counting` and `zero` show their optimized trees.

`tests/objects/facts_test.py` checks what codegen tells LLVM, and what
LLVM makes of it in an optimized build: no snapshot in a program that
spawns nothing and every snapshot where something may write back, the
runtime's small list operations in line, and a loop over a list's elements,
each written and read again, with no index check left in it.

`tests/perf/` holds how fast a build's code runs, optimized and plain: each
of its programs, most of them ports of the spec repo's `langbench/`, is
built both ways and runs under Valgrind's Callgrind with the cache and
branch simulators on, and what they count becomes estimated cycles. A
simulated cycle is the same on every run of one build, so a change to
codegen, to the pipeline LLVM runs, to what plain builds inline (O12) or to
what LLVM is told shows as a moved number rather than as noise in a timing.
CI keeps both numbers of each program for the last commit on `main`, and
one large program's for every commit, and fails a pull request that makes
either build of a program more than 1% slower
([`tests/perf/README.md`](../../tests/perf/README.md)).

`tests/unit/` checks the evaluator's arithmetic against codegen's, its math
functions, the intrinsic classes, a value written as code and read back, calls, outputs,
memoization of a call that reaches a loop or a runtime function, or runs a
large body or a long chain of small ones, and not of one that does none of
these, a chain of calls that each make two staying
linear, the budget, stores in place, the locals a call left to run
forgets, two folds of handmade
functions, a replacement past the size cap only as a whole, a string that
doubles past the budget, a call that replays its previous level's output
twice stopping at the output cap, with a word and with empty prints, a member of a program variable written in place,
and a call remembered for a zero and for its negative.

---

## 6. Open questions

- **The limits.** The budgets, the depth and the size cap are starting
  points, left to measurement on real programs.
- **Unrolled output.** A loop over known values that prints becomes one print
  per line it writes, within the size cap. Whether a loop that prints should
  stay a loop is left to measurement.
