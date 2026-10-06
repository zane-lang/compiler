# Optimization: folding at compile time

> **Status: built.** Stage 5 runs one pass, compile-time evaluation, which
> follows this design. Each decision is numbered (**O1**…). §4 says where the
> pass does more than the spec asks, and §6 what is left to measurement.

Stage 5 rewrites the CGT into a faster CGT ([`stages.md`](stages.md)). Its
pass evaluates, while the compiler runs, everything the program would compute
the same way every time it runs, and writes the results into the tree in
place of the code that computed them. Evaluation starts at the leaves of the
tree and works up: an expression whose inputs are all known is replaced by its
value, and its parent is tried next with that value as an input. It stops
where a value depends on something only the running program has, such as a
line read from the console or the time.

---

## 1. Where it runs

**O1. Stage 5 is a library of its own, over the CGT.** `lib/optimize/` takes
the program lowering made and gives back a program of the same tree, so
codegen reads an optimized and an unoptimized program alike. It works on the
CGT rather than the TST because the CGT is what runs: every function in it is
one instance (L4), block-taking verbs are already written out where they are
called (L11), and it holds the functions the TST never had, such as package
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
pipeline, and an unoptimized build skips it. `zane run` builds unoptimized, so
it stays as fast to build as before. `zanec --cgt --optimize` prints the tree
stage 5 made, which is how the tests see what folded (§5).

---

## 2. What folds

**O3. A value is known unless it depends on an input.** Every intrinsic
reaches the CGT either as ordinary nodes (an operator as a `Binary`,
`@controlflow$branch` as an `If`) or as a call into the runtime, so a class
for each runtime function covers them all. `intrinsics.ml` gives one to each
in an exhaustive match, so a runtime function added later does not compile
until it is classified:

| Intrinsic | In the CGT | Class |
|---|---|---|
| scalar `+ * / == < ~`, `Bool` `+ * ==` | `Binary`, `Flip` | computed |
| `String` `+ ==`, `String(…)` | `Text_join`, `Text_equal`, `Text` | computed |
| `List(T)`, `push`, `size`, `[]` | `List_new`, `List_push`, `Member`, `List_at` | computed |
| `Array`, `ArrayRef`, `fill`, `[]` | `Record`, a counted loop, `Array_at` | computed |
| `@controlflow$branch`, `repeat` | `If`, `Repeat` | computed |
| storage: slots, boxes, copies, moves, overwrites, scopes | the nodes and the runtime calls codegen makes for them | computed (O5) |
| `spawn` | `Spawn`, `Join`, `Snapshot`, `Writeback` | computed (O8) |
| package constants | `Constant_begin`, `Constant_end` | computed (O9) |
| `@runtime$print` | `Print` | output (O4) |
| `@runtime$setThreads`, `setThreadsAuto` | `Set_threads`, `Set_threads_auto` | output (O4) |
| input: a console read, the time, a random number | none | input |

No intrinsic reads input, so the input class has no member. `setThreadsAuto`
reads the processor count, but gives nothing back, so no value of the program
depends on it. The first intrinsic that does read input belongs in the input
class, which stops a fold where it is reached.

Besides an input, a value is unknown when it is a parameter of the function
being folded, or what a function with no body in this object gives: a stamped
dependency's (`separate-compilation.md` C1). Everything computed only from
known values is known. Whether a function terminates is never analyzed: the
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
negative value divided by `-1` wraps (`lowering.md` §9), `F64` is IEEE with
ordered comparisons, so a NaN is neither equal to nor less than anything, and
`Bool` takes `+` as or and `*` as and. Every NaN folds to the same positive
quiet NaN: what sign and payload a NaN gets is the machine's, and no program
can tell one NaN from another. Constants are compared bit for bit, so a zero
and its negative, which a division tells apart, are two values.

**O6. Each function is folded from the leaves up, within a budget.**
`fold.ml` walks each function's body in the order it runs and keeps what it
knows: each local whose value is a constant at that point. Every function is
folded, whether or not anything calls it, so the constant code inside a
function that never ends still folds.

- An expression is tried once its children are folded and all its inputs are
  known: constants, known locals, or addresses of them. If evaluating it
  finishes, it is replaced by its value, with its outputs before it (O4) and
  each known local it wrote stored back.
- A control statement, a loop, a branch or a switch, is run whole when the
  locals it reads are known. A loop over known values leaves only what it
  wrote: `counting`'s nested loop becomes its prints.
- A branch on a known condition becomes its body or nothing, a switch on a
  known case its one arm, and a loop with a count below one goes.
- Whatever does not fold stays as it was, and what it may write is not known
  after it: each local whose address it takes, every local it assigns, and,
  when it can write through an address, every local whose address was ever
  taken in the function. That holds inside an expression too: a call left
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

Evaluation stops, leaving the code as it was, when it reads an unknown
value, reaches a division by zero or an index out of range (the program must
still stop there when it runs, after what it wrote before), would write a
variable of the program, gives a value that holds a lent address, or runs out
of budget. Three limits bound it, each counted in steps, so that the same
source folds the same way on any machine. Work that grows with a value's
size, joining strings, copying a list or a struct, growing a list, costs a
step for each 64 bytes, charged before the work is done, so a few steps
cannot build a value of any size:

- one fold takes at most 1,000,000 steps;
- all the folds of a program take at most 50,000,000;
- calls nest at most 2,000 deep.

A replacement whose code would be larger than 64 KiB, its value, its outputs
and the locals it stores counted together, does not fold either, which keeps a cheap call that builds a large value out of the
binary. A call's result and outputs are remembered by its function and its
arguments, so a call made again with the same arguments costs a lookup, and
a call with constant arguments that did not fold is not tried again.

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

## 4. Where it does more than the spec asks

[`concurrency.md`](https://github.com/zane-lang/spec/blob/f73cc01/spec/concurrency.md)
§2.1 evaluates a call at compile time when it writes nothing its caller can
see, touches no capability-backed state, and terminates, and §2.3 keeps a call
that is not proven to terminate at runtime, using the facts
[`effects.md`](https://github.com/zane-lang/spec/blob/f73cc01/spec/effects.md)
§5.2 and §5.4 derive. Stage 5 folds more than that: a call that prints, since
its output is replayed (O4); a `mut` call on a known local, whose new value
is stored back; and a call that is
not proven to terminate but finishes within the budget (O6). It also leaves
some calls the spec would fold at runtime, when they pass the budget or the
size cap.

A running program can tell none of this apart, so it is not a divergence in
the sense of [`spec-divergences.md`](../spec-divergences.md). The spec's
rule is left as it is for now.

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
  store that folded, a count's included, and knows nothing past a call left
  to run that writes a local;
- `constants`, `counting` and `zero` show their optimized trees.

`tests/unit/` checks the evaluator's arithmetic against codegen's, the
intrinsic classes, a value written as code and read back, calls, outputs,
memoization and the budget, stores in place, two folds of handmade
functions, a replacement past the size cap only as a whole, a string that
doubles past the budget, a member of a program variable written in place,
and a call remembered for a zero and for its negative.

---

## 6. Open questions

- **The limits.** The budgets, the depth and the size cap are starting
  points, left to measurement on real programs.
- **Unrolled output.** A loop over known values that prints becomes one print
  per line it writes, within the size cap. Whether a loop that prints should
  stay a loop is left to measurement.
