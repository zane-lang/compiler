# Codegen tests

Stages 4 and 6: lowering and codegen (docs/design/lowering.md). Each directory
under `fixtures/` is one package, lowered and printed as its code-generation
tree when `golden/NAME.cgt` exists, and built into an executable and run when
`golden/NAME.out` exists: the golden files hold the tree and what the program
wrote. A fixture whose `expected-status` file holds a nonzero status stops
with it, and its `.out` holds stdout and stderr together.

The rules are written by `tests/gen/gen_rules.ml` into `dune.inc`. To add a
fixture, add its directory and an empty golden file, run `dune runtest`,
check the new rules in the `dune.inc` diff and `dune promote`, then run it
again, read the golden diff and promote that.

## Fixtures

- `hello` prints a string literal through `@program$console`: the first program
  that ran (docs/design/lowering.md §8 step 2).
- `counting` is step 2 of docs/design/lowering.md §8: scalar arithmetic, verbs
  that call verbs, and the fixture's own `if`, `elif`, `else` and `to` expanded
  where they are called. Every check it makes prints `yes` when it holds.
- `zero` divides by zero: the program stops with status 1 after what it wrote
  so far, and says why on stderr.
- `operators` is the derived operators of operators.md §2.3 on intrinsic and
  declared `<`: each gives its value, and a `a b` line shows its operands ran
  in written order however the desugaring passes them. Then numeric literals
  whose digits a `'` separates. Every check prints `yes` when it holds.
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
  in a body and at package scope, passed, returned, stored in a member and
  called through, with an abort, a subject, a string, a host and a guest.
  Every check prints `yes` when it holds and `no` when it does not.
