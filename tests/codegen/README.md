# Codegen tests

Stages 4 to 6: lowering, optimization and codegen (docs/design/lowering.md,
docs/design/optimization.md). Each directory under `fixtures/` is one package,
lowered and printed as its code-generation tree when `golden/NAME.cgt` exists,
printed as the tree an optimized build makes of it when
`golden/NAME.optimized.cgt` exists, and built into an executable and run when
`golden/NAME.out` exists, unoptimized and optimized: the golden files hold the
trees and what both builds of the program wrote. A fixture whose
`expected-status` file holds a nonzero status stops with it, and its `.out`
holds stdout and stderr together. A fixture's `arguments` file, one argument
per line, is what both builds of its program run with.

The rules are written by `tests/gen/gen_rules.ml` into `dune.inc`. To add a
fixture, add its directory and an empty golden file, run `dune runtest`,
check the new rules in the `dune.inc` diff and `dune promote`, then run it
again, read the golden diff and promote that.

## Fixtures

- `scalarTexts` exercises the four scalar String constructors end to end,
  including I32 wrapping, compact float notation, negative zero and special
  values. Optimized and unoptimized builds must print the same text.
- `arguments` is the program's arguments, read from the runtime, and numbers
  read from text with `parseI64` and `parseF64`, each held to what it accepts
  and when it aborts. Both builds run with the `arguments` file's lines.
  `arguments.optimized.cgt` shows what folds before the read and that the
  read itself stays. Every check prints `yes` when it holds.
- `hello` prints a string literal through `@program$console`: the first program
  that ran (docs/design/lowering.md §8 step 2).
- `counting` is step 2 of docs/design/lowering.md §8: scalar arithmetic, verbs
  that call verbs, and the fixture's own `if`, `elif`, `else` and `to` expanded
  where they are called. Every check it makes prints `yes` when it holds.
- `operators` is the derived operators of operators.md §2.3 on declared
  operators, written over `@operators$`: each gives its value, and a `a b`
  line shows its operands ran in written order however the desugaring passes
  them. Then numeric literals whose digits a `'` separates. Every check prints
  `yes` when it holds.
- `scalars` is every `@operators$` function on each type it takes, `F32`
  rounding, division by zero, and every conversion between two scalars
  (types.md §2.9), saturating truncation included, each
  checked in a build that folds it and one that does not. Every check prints
  `yes` when it holds.
- `shapes` is step 3: value structs of several members, variants and enums,
  copies, member reads and stores, `mut` subjects, `match` and enum maps. Every
  check it makes prints `yes` when it holds and `no` when it does not.
- `outcomes` is step 4: aborts, `?` and `??` handlers, `resolve`, `match`
  handlers, case reads and `guard`. Every check prints `yes` when it holds and
  `no` when it does not; the one after a `guard` in the same block is never
  reached.
- `hosts` is step 5: reference types hosted in their scope's arena, moved and
  written in place, with every way out of a hosting block draining its arena.
  The runtime stops the program if a scope drains out of order or is left open,
  so a missed drain fails the run.
- `guests` is step 6: `&T` minted, read and written through, passed, returned
  and stored, following its host through moves, stable overwrites, merges and a
  variant payload's float.
- `texts` is step 7's strings: `@primitives$String` handles that own their
  bytes, joined, compared, printed, hosted, moved, guested, overwritten,
  floated, returned, discarded and aborted with. The runtime stops a program
  that ends with a block still out.
- `lists` is step 7's lists: pushed to, measured, indexed and written at an
  index, of scalars, strings, hosts and lists, under a generic type with a
  declared subscript. Guests follow hosts into a list and through its growth.
- `boxes` is step 7's boxed members: value types that contain themselves,
  copied whole, a reference chain whose guests hold while it moves, and case
  reads of boxed payloads.
- `range` indexes past a list's end: the program stops with status 1 after what
  it wrote so far, and says why on stderr.
- `regions` is each scope's dynamic region: a value that leaves a scope --
  returned, left from an arm, aborted with, stored or pushed from an inner
  block -- takes its blocks out before the scope drains, and a drain that finds
  one still out stops the program.
- `spawns` is step 8: calls started with `spawn` run on the pool's threads.
  Their results come home when read or when their block drains, which waits for
  every call spawned in it, and the runtime stops a program that ends with a
  block still out.
- `lambdas` is step 9: lambdas lifted to functions, held by lambda-variables
  in a body and at package scope, passed, returned, stored in a member and an
  enum map, called through and spawned, with an abort, a subject, a string, a
  host and a guest. Every check prints `yes` when it holds and `no` when it
  does not.
- `arrays` is step 10's fixed arrays: built from a literal, read and written
  at an index, copied whole, held in a struct, a host and a variant, and a
  type that boxes itself through one; a number parameter read as its number;
  and `@primitives$I32` arithmetic, which wraps at its own width. Every check
  prints `yes` when it holds and `no` when it does not.
- `bounds` indexes past an array's end: the program stops with status 1 after
  what it wrote so far, and says why on stderr.
- `defaults` is step 10's field constructors: called as verbs whose bodies
  run, with an entry left out given its default, the entries run in the
  order written, a generic constructor's defaults per instance, and a
  constructor expanded where it is called.
- `constants` is step 10's package constants: each made once before `main`,
  one reading another made first whatever their order, a string that owns
  its block, a host a guest names, and a value struct, read from a verb and a
  spawned call.
- `spawned` is step 10's spawned calls that need a function made for them: an
  intrinsic method, verbs expanded where they are called because they take
  literals, an array literal among them, one that aborts, and one with a
  `mut` subject; and a spawned call bound to a `mut` function type.
- `references` is step 10's `&` written before a place, minting and copying
  guests, and `@program$console` passed where a guest is wanted.
- `probed` keeps running what the memory-semantics probes
  (`tests/memory-probes/`) found broken: an `&` element read from an
  `ArrayRef`, and a recursive value 30,000 boxes deep built, copied,
  overwritten and destroyed, which the runtime walks in a loop rather than
  on the C stack, a 512 KiB array, moved as memory, and an element store and
  a `!` call on an element whose value grows the list, which find the element
  only after it has moved.
- `folding` is stage 5: what an optimized build computes at compile time.
  Each scalar at its edges, strings, values, an abort, a list and a boxed
  value built and measured inside a call, a list and a boxed value a call
  gives and the program then changes, recursion, a `mut` call, a function
  value and spawned calls. Every check prints `yes` when it holds, so the
  unoptimized build, which folds nothing, shows the folded one is right.
- `replayed` is what stage 5 keeps: output made while a value is computed,
  replayed in order; calls past the step budget, the depth and the size cap,
  left to run; and a slot read when the program runs, after a store made by
  code that folded.

`constants`, `counting` and `zero` also show the tree an optimized build
makes of them.

## Rejects

Each package under `fixtures/reject/` is a program semantics accepts and
lowering refuses, and `golden/reject.NAME.err` is what lowering says. There is
one for each construct lowering does not handle yet (docs/design/lowering.md
§7), so implementing one changes its golden file, and so does a refusal that
stops firing by mistake:

- `valueFlow` uses a control-flow intrinsic as a value;
- `literalOperator` calls an operator that takes a literal;
- `unitFuture` stores into a spawned call's `Unit` result.

`literalRange` is a refusal of the program itself: a literal too large for
its primitive, which reaches the primitive through a verb's literal parameter
and so is found only where the verb is written out.
