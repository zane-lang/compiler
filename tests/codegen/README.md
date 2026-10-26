# Codegen tests

Stages 4 to 6: lowering, optimization and codegen (docs/design/lowering.md,
docs/design/optimization.md). Each directory under `fixtures/` is one package,
lowered and printed as its code-generation tree when `golden/NAME.cgt` exists,
printed as the tree an optimized build makes of it when
`golden/NAME.optimized.cgt` exists, and built into an executable and run when
`golden/NAME.out` exists, unoptimized, optimized and tiered: the golden
files hold the trees and what every build of the program wrote. The tiered
build is tier 0 run with its tier 1 loaded before `main`
(docs/design/tiers.md T8), so all of the program but `main` itself runs tier
1's code, and a tier 1 that does not load stops it. A fixture whose
`expected-status` file holds a nonzero status stops with it, and its `.out`
holds stdout and stderr together. A fixture's `arguments` file, one argument
per line, is what every build of its program runs with, and its `flags` file,
one per line, what every one is built with besides.

Every program runs checked and unchecked, and both runs are held to the same
golden file; each rule sets `ZANE_CHECK` itself. Checked (`ZANE_CHECK=1`),
each drain returns its values' blocks one at a time, and a block still out in
the region afterwards stops the program (docs/design/lowering.md §9).
Unchecked (`ZANE_CHECK=0`), as a program built for use runs, a region is
released in bulk and nothing is checked, and a scope with nothing to wait for
drains in line, by the code `Emit.drain_scope` emits rather than in the
runtime.

The rules are written by `tests/gen/gen_rules.ml` into `dune.inc`. Every
fixture has at least one golden file, and every golden file names a fixture
that exists: the generator stops at either kind of orphan and names it, as it
does in `tests/parser/`, `tests/runtime/` and the `typing` builds of
`tests/semantics/`. A fixture is tested or it is deleted; none is kept and
skipped. To add a fixture, add its directory and an empty golden file, run
`dune runtest`, check the new rules in the `dune.inc` diff and `dune promote`,
then run it again, read the golden diff and promote that.

## Fixtures

- `scalarTexts` exercises the four scalar String constructors end to end,
  including I32 wrapping, compact float notation, negative zero and special
  values. Optimized and unoptimized builds must print the same text.
- `arguments` is the program's arguments, read from the runtime, and numbers
  read from text with `parseI64` and `parseF64`, each held to what it accepts
  and when it aborts, then divided by 0 and -1 read at run time, which take
  the branch around the `sdiv` (`Emit.divide`). Both builds run with the `arguments` file's lines.
  `arguments.optimized.cgt` shows what folds before the read and that the
  read itself stays. Every check prints `yes` when it holds.
- `expressions` is verbs whose body is one expression, written out where they
  are called (docs/design/lowering.md L11): a generic one's instance, a chain
  of them, and one whose arguments print in the order they are written, each
  once. A spawned call to one still calls its function. `expressions.cgt`
  shows `main` calling only those kept as calls: `tripled`, `starts` and
  `first`, past the size bound or spawning, and `noted`, written as
  statements.
- `hello` prints a string literal through `@program$console`: the first program
  that ran (docs/design/lowering.md §8 step 2).
- `interpolation` is string literals end to end (lexical.md §7.1, types.md
  §2.7, §2.8): the escaped quote and backslash, a backslash sequence kept
  as written, `\%name` with a primitive and with an implicit conversion,
  one beside another and before identifier punctuation, and a literal
  passed to a concept parameter, read twice and passed on. A block run
  before the literal is read changes the value it interpolated, and the
  text keeps the value it had when the literal was written.
  `String.escaped` reads `\n`, `\t` and `\\` in the literal's text and
  not in a value interpolated into it. A field constructor given
  its entries out of order runs an interpolated value's implicit conversion
  in written order, and two spawned literals that differ only in where a
  site falls beside a written `\%` each get their own function.
- `escapes.cgt` is every escape `String.escaped` reads, `\n`, `\t`, `\r`,
  `\0` and `\\`, in the text constant it lowers to, beside the plain
  constructor keeping the same sequences as written (types.md §2.7).
- `counting` is step 2 of docs/design/lowering.md §8: scalar arithmetic, verbs
  that call verbs, and the fixture's own `if`, `elif`, `else` and `to` expanded
  where they are called. Every check it makes prints `yes` when it holds.
- `math` is every `@math$` function on each type it takes (math.md §2):
  shift and rotation counts at and past the width, zero's leading and
  trailing zeros, `abs` of the most negative integer, `sqrt` below zero,
  rounding ties and signed zeros, an `fma` that a multiply and an add would
  round differently, `copySign` with a NaN, and `min` and `max` with a NaN
  and with both zeros, in a build that folds the exact ones and one that
  does not. The approximate functions are held to within a tolerance of the
  true value, since their last digit is the C math library's.
  `math.optimized.cgt` shows the exact ones folded and the approximate ones
  left as calls. Every check prints `yes` when it holds.
- `operators` is the derived operators of operators.md §2.3 on declared
  operators, written over `@operators$`: each gives its value, and a `a b`
  line shows its operands ran in written order however the desugaring passes
  them. Then `and` and `or`, operators that take a literal on either side,
  through the derived forms too, and numeric literals whose digits a `'`
  separates. Every check prints `yes` when it holds.
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
  floated, returned, discarded and aborted with. A checked drain stops a
  program that ends with a block still out.
- `lists` is step 7's lists: pushed to, measured, indexed and written at an
  index, of scalars, strings, hosts and lists, under a generic type with a
  declared subscript. Guests follow hosts into a list and through its growth.
- `pushRuns` is runs of pushes onto a new list, each given its room at its
  first push (`Emit.runs`): one that fits the first block a scope makes
  itself, two that take the runtime's room, one pushed past its run, one a
  read cuts short, and one under a loop.
- `boxes` is step 7's boxed members: value types that contain themselves,
  copied whole, a reference chain whose guests hold while it moves, and case
  reads of boxed payloads. `Solo`, a struct whose one member is boxed, is a
  single address, so reading one out of a list takes the snapshot's acquire
  load.
- `longChain` is a chain of 300 distinct structs ending in an `Int` and a
  `String`, held beside a `&` member. However long a chain of types that
  does not grow is, its layout, its owned blocks and what a write reaches
  through its references are found, with no limit on its length.
- `removal` removes lists' elements with `remove`, which keeps the order of
  the rest, and `swapRemove`, which moves the last element in: of scalars,
  strings, owners and lists, each removed element kept, settled, pushed back
  or left to die where it was removed, a list emptied and grown again, and a
  list that is an element, removed from with an index that grows the list
  holding it, which the call locates only after the index runs. A list made
  by a call runs before the index, which prints `list index`, and a list of
  `Unit` only changes its count.
  `removalFolded` is removals the optimizer runs while folding. `removeRange`
  removes past a list's end, which stops the program as reading there does.
- `headers` writes list elements, and what they own, between reads that need
  the list's current count or block: a field written and read again through
  the list, a push that grows the list between two reads of one element, a
  `swapRemove` between two writes at one index, lists in a list whose
  elements are pushed to, and a type holding a list beside a scalar. Its
  sizes come from the `arguments` file, so the optimized build leaves the
  loops for LLVM, which is told a list's header is not an element
  (docs/design/lowering.md §9). Every check prints `yes` when it holds.
- `range` indexes past a list's end: the program stops with status 1 after what
  it wrote so far, and says why on stderr. `rangeZero` does the same with
  index 0, below a list's first element.
- `regions` is each scope's dynamic region: a value that leaves a scope --
  returned, left from an arm, aborted with, stored or pushed from an inner
  block -- takes its blocks out before the scope drains, and a checked drain
  that finds one still out stops the program.
- `keeping` is step 12: which callees keep what they are given
  (docs/design/lowering.md §9). A constructor that moves its `^T`
  parameters into its result, a function that builds a roaming result, and
  one that pushes into a list its caller lent open no arena, and `keeping.cgt`
  shows their owners held in slots of their own. A callee that drops a
  parameter keeps its arena, and so does a loop that moves fresh owners into
  it, on every pass; a value parameter copied once into the result takes a
  fresh argument and copies a place where the call is; a function that lends
  a slot to a callee with an arena keeps its own; and a spawned call builds
  its result over the spawning context's blocks. Every check prints `yes`
  when it holds, and a checked drain stops a program with a block still out.
- `spawns` is step 8: calls started with `spawn` run on the pool's threads.
  Their results come home when read or when their block drains, which waits for
  every call spawned in it, and a checked drain stops a program that ends
  with a block still out.
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
  what it wrote so far, and says why on stderr. `boundsNegative` does the same
  with a negative index.
- `defaults` is step 10's field constructors: called as verbs whose bodies
  run, with an entry left out given its default, the entries run in the
  order written, a generic constructor's defaults per instance, and a
  constructor expanded where it is called.
- `constants` is step 10's package constants: each made once before `main`,
  one reading another made first whatever their order, a string that owns
  its block, a host a guest names, and a value struct, read from a verb and a
  spawned call.
- `entryArray`, `entryString`, `entryStruct` and `entryUnit` are a `main`
  that returns an `Array<I64, 10>`, a `String` that owns its block, a
  `#struct` that owns a list, and `Unit`, which the start function discards
  (docs/design/lowering.md L16). Each `...Constant` twin adds a package
  constant nothing reads, which once changed which entry the runtime called.
  `entryWide` returns an `ArrayRef` of 65,536 `I64`s, too many parts to load
  as one value: the start function holds it in a frame of its own, as any
  dropped owner is held, rather than in a slot of the machine stack.
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
- `runs` is a run of statements folded whole: a sieve makes a list, marks it
  in place and reads it, and the optimized build keeps only what it printed.
  A list still named after the arguments are read stays for the program.
  Every check prints `yes` when it holds.
- `replayed` is what stage 5 keeps: output made while a value is computed,
  replayed in order; calls past the step budget, the depth and the size cap,
  left to run; a slot read when the program runs, after a store made by
  code that folded; and what stays known past a call left to run: a value
  it is given no address of, a string a `mut` call changed among them, but
  not an owner it reaches through a reference stored in another.
- `doubling` is output replayed from a remembered call, charged and capped
  (docs/design/optimization.md O6): a call that makes its previous level
  twice and prints once at its base folds to its prints at ten levels, stays
  runtime code at seventeen levels of empty prints, which pass the output
  cap, and stops at the cap at forty levels, behind a condition that is
  false when the program runs, rather than make 2^40 outputs.
- `stringArrays` is arrays of strings described by one position each
  (docs/design/lowering.md §9, "Each type's walks"): an `ArrayRef` of
  100,000 strings filled, moved and dropped twenty times over, one of 50,000
  overwritten, and a value array of 20,000 strings, four arrays deep,
  copied whole and changed. Each pass sums its strings read back as
  numbers, and each check prints `yes` when it holds.
- `walks` is values nested deeper than an emitted walk calls itself
  (docs/design/lowering.md §9): a countdown a thousand boxes deep made,
  copied and overwritten by deeper and shallower ones, a variant whose
  cases own a string or a deep countdown, a list of deep values, a deep
  chain of owners each naming a string, and a spawned call's deep result.
  Past the depth each walk hands the rest on to the runtime, and the
  checked drains stop the program if a block is missed or returned twice.
  Every check prints `yes` when it holds and `no` when it does not.

`constants`, `counting` and `zero` also show the tree an optimized build
makes of them.

- `frames` is a scope's frame (docs/design/lowering.md §9): one of 1.5 MiB,
  larger than the guard after a context's range, and frames of 512 KiB and
  1.5 MiB a few deep, within the default range. Every check prints `yes`.
- `deepFrames`, `wideFrames` and `spawnedFrames` nest frames past a range
  their `flags` make 2 MiB: frames of 512 KiB that fault in the guard,
  frames of 1.5 MiB that the check before placing them stops, and frames in
  a spawned call's context. Each stops with status 1 and an error naming
  the range and its manifest field.
- `recursion` nests calls without end, and stops with status 1 when the
  machine stack is full, rather than crashing.

## Rejects

Each package under `fixtures/reject/` is a program semantics accepts and
lowering refuses, and `golden/reject.NAME.err` is what lowering says. There is
one for each construct lowering does not handle yet (docs/design/lowering.md
§7), so implementing one changes its golden file, and so does a refusal that
stops firing by mistake:

- `valueFlow` uses a control-flow intrinsic as a value;
- `unitFuture` stores into a spawned call's `Unit` result.

`literalRange` is a refusal of the program itself: a literal too large for
its primitive, which reaches the primitive through a verb's literal parameter
and so is found only where the verb is written out.

`hugeArray`, `nestedArray` and `beyondLimit` are refusals of a type too
large to hold (docs/design/lowering.md §9): an `Array<I64, 4294967296>` and
an `Array<Array<I64, 65536>, 65536>`, each 32 GiB, more than the main
context's range of frames, and an `Array<I64, 1152921504606846976>`, whose
size wrapped to 0 before it was checked and is past the `2^48` bytes any
type is limited to.
