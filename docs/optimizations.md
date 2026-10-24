# Optimizations

Every optimization the compiler applies to the programs it builds: what it
does to the binary, which builds get it, and where it lives. Making the
compiler itself faster is out of scope here.

This is a catalog. The design documents remain where each optimization is
explained and justified; an entry here says what it is in a few lines and
links there.

## How to add or edit an entry

- One `###` heading per optimization, under the section for the part of
  the compiler that does it. Headings name the transformation, not the
  file.
- Every entry has the same four fields, in this order, then a short
  description:
  - **Builds:** `every build`, `optimized only` (`--optimize`),
    `unoptimized only`, or `opt-in` (with the flag that turns it on). An
    optimization a flag turns off names the flag after the builds.
  - **Where:** the files that implement it.
  - **Design:** the section of `docs/design/` that explains it.
  - **Effect:** a measured result, or `not measured`.
- Keep the description to what the binary gains and what the optimization
  rests on. Anything longer belongs in the design document it links.
- When an optimization is removed, delete its entry; when it changes, edit
  it in the same change as the code.

A blank entry to copy:

```markdown
### Name of the transformation

- **Builds:** every build
- **Where:** `lib/…`
- **Design:** [`design/….md`](design/….md) §…
- **Effect:** not measured

What it does to the program, and what about Zane makes it sound.
```

---

## Lowering (stage 4, `lib/cgt/`)

### Block- and literal-taking verbs expanded where they are called

- **Builds:** every build
- **Where:** `lib/cgt/lower.ml`, `lib/cgt/lower_calls.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) L11
- **Effect:** not measured

A verb with a `@concepts$Block` parameter, or any other concept parameter
such as a literal, has no function of its own: each call is replaced by the
body, with the block or literal spliced in. `branch` becomes an `if`,
`repeat` a counted loop, and an `implicit Int(value @concepts$Int)` embeds
the literal directly. No closure or call is left for a block.

### Expression verbs written out where they are called

- **Builds:** every build
- **Where:** `lib/cgt/verbs.ml` (`size`, `inlines`), `lib/cgt/lower_calls.ml`
  (`writes_out`, `expand`)
- **Design:** [`design/lowering.md`](design/lowering.md) L11
- **Effect:** estimated cycles of the perf programs, plain and optimized:
  `trees` −8.9% and −4.9%, `copies` −3.2% and −4.0%, `stress` −2.1% and
  −0.5%, `flips` optimized +1.1% from branch placement alone, the rest
  unchanged; the speech-analysis program's plain run −2.6% of its
  instructions, its optimized run unchanged. The compiler runs 2.5% more
  instructions building it plain and 6.8% more optimized

A verb whose body is one expression it returns, with no abort, spawn or
lambda in it, is replaced by its body at each direct call, as a block-taking
verb is, and keeps its function for spawned calls and other objects. That is
every one of `core`'s wrappers, generic ones such as `size` included, which
the unoptimized build's own inliner leaves as calls. A chain of them is
written out only while it stays 40 nodes, a recursive one is called inside
itself, and a call that hands a fresh owner of blocks to a value parameter
calls the function, which takes the value rather than copying it.

### Arenas only for blocks that need one

- **Builds:** every build
- **Where:** `lib/cgt/lower.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "How many
  scopes get an arena"
- **Effect:** not measured

A block opens a scope arena only when it holds a reference-type local or a
value that owns a block. Every other value-type local is an ordinary LLVM
stack slot, which LLVM can promote to a register.

### Region folding across functions

- **Builds:** every build
- **Where:** `lib/cgt/regions.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "How many
  scopes get an arena"
- **Effect:** not measured

After every function is lowered, a whole-program analysis removes arenas
nothing observes ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
§3.1):

- a `^T` parameter every way out moves on is *kept*, so the caller needs no
  arena for what it passes;
- a function whose body is one arena holding only kept owners opens none,
  and makes its values directly in the caller's innermost region, so
  nothing is relocated on return;
- a value parameter only read to be copied once takes its argument instead:
  a fresh argument is moved in rather than held and copied;
- an arena left holding nothing is dropped.

### Value parameters are borrowed

- **Builds:** every build
- **Where:** `lib/cgt/lower_calls.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "A value
  parameter is borrowed"
- **Effect:** not measured

A value parameter is read-only, so a value that owns blocks is passed where
it is rather than copied whole. Only a callee that stores the parameter
copies it.

### Plain loads in a program that never spawns

- **Builds:** every build (programs, not libraries)
- **Where:** `lib/cgt/program.ml` (`spawns`, `exclusive`), `lib/cgt/state.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Snapshots"
- **Effect:** lets LLVM forward stores to loads and keep fields in
  registers across loops, which no atomic load allows

A value read through an owner is normally read as a snapshot, since a
spawned write-back may race it. When no package in the build contains a
`spawn`, nothing can write back, so every such read is a plain load.

### Cross-package bodies for the optimizer

- **Builds:** every build
- **Where:** `lib/cgt/program.ml` (`import_bodies`), `lib/driver/driver.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O10,
  [`design/separate-compilation.md`](design/separate-compilation.md) C12
- **Effect:** [`design/cross-package-optimization-results.md`](design/cross-package-optimization-results.md):
  mandelbrot 7.6×, trialdiv 3.0×, fannkuch 1.9×, entities and listgrowth
  1.6× faster

Lowering follows calls into stamped dependencies and keeps their bodies
with `available_externally` linkage. In an optimized build stage 5 can
evaluate those calls; in every build LLVM can inline them, while any call
left still links against the dependency's own object. An unoptimized build
needs them for its own inlining: `core`, linked as a separate object, is
otherwise a declaration for every `+`.

### Type arguments pass nothing

- **Builds:** every build
- **Where:** `lib/cgt/program.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) L4, §9, "A type
  argument passes nothing"
- **Effect:** not measured

Each generic verb is lowered once per instance, so a type argument or an
explicit number parameter has already picked the function and costs nothing
at run time; the body reads a number parameter as a constant.

### Calls remembered while the program runs

- **Builds:** every build; `--no-memoize` turns it off
- **Where:** `lib/cgt/memo.ml`, `lib/codegen/emit.ml` (`memo`)
- **Design:** [`design/memoization.md`](design/memoization.md)
- **Effect:** [`dev/bench/memo/`](../dev/bench/memo/README.md), in plain,
  optimized and tiered builds: recursions that repeat their arguments
  70–99.6% fewer estimated cycles, among them a tic-tac-toe search keyed on
  its board (74–80%) and a recursion that calls itself once, called again
  from a loop (96–97%); a heavy call in a loop whose arguments repeat
  89–90%; programs whose arguments do not repeat, or whose repeats save
  less than a lookup costs, within +0.32%, but one that LLVM folds whole
  without a table, which costs a fixed 25,000 cycles more, and a plain build
  of a recursion that calls itself once on new arguments, +1.2%. Over 150
  random recursions, a median of 87% fewer plain, 37% optimized and 36%
  tiered, and at worst +0.4%, +1.2% and +1.8%.

A function whose result depends only on its arguments, which takes and
returns fixed-size values, and which calls back into its own cycle, or is
heavy and called from a loop, keeps a table of its results, so a call whose
arguments repeat returns at once. Each function scores its lookups against
the work its hits save, counted from below, and stops looking for good when
they do not pay. A loop decides once, before it starts, whether its calls
still look, so a loop whose functions have stopped runs as written.

---

## Compile-time evaluation (stage 5, `lib/optimize/`)

### Constant folding and known control flow

- **Builds:** optimized only
- **Where:** `lib/optimize/fold.ml`, `lib/optimize/eval.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O3, O5, O6
- **Effect:** not measured

Every expression whose inputs are all known is replaced by its value, from
the leaves up. A branch on a known condition becomes its body or nothing, a
switch on a known case its one arm, and a loop with a count below one is
removed. Arithmetic folds exactly as codegen would compute it (wrapping,
division by zero giving zero, saturating truncation, single rounding of
`F32`).

### Calls and runtime work run at compile time

- **Builds:** optimized only
- **Where:** `lib/optimize/eval.ml`, `lib/optimize/intrinsics.ml`,
  `lib/optimize/materialize.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O3, O5, O7
- **Effect:** removes the list constructors, spawns and snapshots LLVM
  alone leaves in the `folding`, `runs` and `removalFolded` fixtures

Calls, strings, lists, boxes, copies, moves and overwrites are evaluated
when their inputs are known, including calls into the runtime that LLVM
cannot see into. The result is written back as the code that builds it: a
constant, a record, a box, or a list made and pushed in one expansion.
Exact math folds; approximate math and `F32` `fma` stay calls, since their
result is the target's C library's.

### Output replayed where it was made

- **Builds:** optimized only
- **Where:** `lib/optimize/eval.ml`, `lib/optimize/materialize.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O4
- **Effect:** not measured

A call that prints while computing still folds: its prints (and
`setThreads`) are replayed with folded arguments at the same point, then
its value is used. A call that only outputs becomes its outputs alone.

### Runs of statements folded as a whole

- **Builds:** optimized only
- **Where:** `lib/optimize/fold.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O6
- **Effect:** `runs` folds a whole sieve to its output

A run of statements in one block is evaluated together, so a list made,
changed in place and read by later statements, which no single statement
leaves known, still folds. The longest run that can end is replaced by its
outputs and the locals it leaves.

### Values kept known past code left to run

- **Builds:** optimized only
- **Where:** `lib/optimize/fold.ml` (`reach`, `writes`, `store_back`),
  `lib/cgt/type_layout.ml` (`slot`)
- **Design:** [`design/optimization.md`](design/optimization.md) O6
- **Effect:** the perf program `kept`, optimized, −43% estimated cycles
  and −64% of its instructions, its plain build unchanged; the other perf
  programs and langbench's programs fold to the same trees as before

Code that does not fold forgets only the locals it can write: those it is
given an address of, and those an address of which may be kept. A value
type keeps no address unless one is stored, returned or spawned, so a
value-type local stays known past a call given no address of it, and a
string, struct or boxed variant a `mut` call changed is stored back by an
overwrite.

### Spawned calls folded

- **Builds:** optimized only
- **Where:** `lib/optimize/eval.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O8
- **Effect:** not measured

Inside code that folds, a `spawn` runs its call at once, which is one of
the orders the spec allows, so the spawn, its join and its snapshots
disappear from the binary.

### Package constants folded

- **Builds:** optimized only
- **Where:** `lib/optimize/constants.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O9
- **Effect:** not measured

A constant whose maker finishes with no output has a known value, and
every read of it folds like a known local. The maker and its first-read
check stay, but only store the folded value.

---

## Code generation (stage 6, `lib/codegen/`)

### LLVM's `-O2` pipeline

- **Builds:** optimized only
- **Where:** `lib/codegen/passes.ml` (`optimized`, `run`),
  `lib/codegen/build.ml` (`prepare`, `level`)
- **Design:** [`design/optimization.md`](design/optimization.md) O11, O12
- **Effect:** not measured

The module goes through LLVM's `default<O2>` pipeline: inlining, constant
folding, dead-code removal, common subexpressions, loop hoisting,
unrolling and vectorization, with the passes the next entries name added
to it. The runtime is compiled with `-O2` too. The
compiler implements a transformation itself only where it rests on
something about Zane that LLVM does not know.

### Inlining and its cleanup in unoptimized builds

- **Builds:** unoptimized only
- **Where:** `lib/codegen/wrappers.ml`, `lib/codegen/passes.ml`
  (`unoptimized`)
- **Design:** [`design/optimization.md`](design/optimization.md) O12
- **Effect:** a speech-analysis program (a 10 s signal through a
  short-time Fourier transform and a harmonic analysis), linked against
  `core` built as its own object as `zane run` links it, medians of 7
  builds and 5 runs: build 0.125 s → 0.130 s, run 6.40 s → 1.05 s, 6.1×
  faster; the optimized build takes 0.36 s and runs 0.17 s

Every function of at most 24 instructions, counted with the picked
functions it calls inlined into it, whose locals each take at most 64
bytes, and whose callees are all such functions, is inlined into every
caller: that is each of `core`'s one-line wrappers over an intrinsic, and
never a recursive function or one holding a large value array, which would
grow its caller's frame for good. A generic instance or a package constant
stays a call, so an object still defines every one that C4 says it does;
lowering has already written out the generic instances whose body is one
expression.
Passes then promote the wrappers' scalars to registers, simplify what that
makes constant, merge the blocks left behind without making a branch a
select, join each `elif` to the `if` before it (next entry) and merge
again. Each takes time in proportion to the instructions it reads; LLVM's
own inliner, scalar replacement of aggregates and instruction combining,
which do not on a large value array, are left out.

### An `elif` joined to the `if` before it

- **Builds:** every build
- **Where:** `lib/codegen/passes.ml` (`optimized`, `unoptimized`),
  `lib/codegen/gen/o2_pipeline.sh`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** the particle simulation of
  [zane-lang/compiler#292](https://github.com/zane-lang/compiler/issues/292)
  (100,000 particles bounced off four walls for 4,000 frames): optimized,
  18.1G → 12.1G instructions under Valgrind and run 1.74 s → 1.2 s;
  unoptimized, run 11.7 s → 11.1 s. `tests/perf` `removal`, 5-8% fewer
  estimated cycles in every build

`core`'s `elif` is a function that branches on `~this and condition`, so
both of its halves reach LLVM as code. Jump threading, run while each
`elif` is still as written, sends the `if`'s body straight past the
`elif`, which makes the two one chain as C's `else if` is. Otherwise LLVM
turns a cheap `if` body into selects, and both bodies run every time round
a loop.

### Index checks taken out of long loops

- **Builds:** optimized only (and tier 1)
- **Where:** `lib/codegen/passes.ml` (`optimized`, `llvm_options`),
  `lib/codegen/gen/o2_pipeline.sh`, `lib/codegen/emit.ml` (`versioned`,
  `count_field`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** the particle simulation of
  [zane-lang/compiler#292](https://github.com/zane-lang/compiler/issues/292):
  12.1G → 8.89G instructions under Valgrind, against 8.88G for the same
  program in C at `-O2`. Langbench: `fannkuch` 1.6% more instructions,
  `nbody` 0.3% and `trialdiv` 0.2% fewer, the rest within 0.1%;
  `tests/perf` `flips`, tier 1 5% fewer estimated cycles

LLVM's inductive range check elimination splits a loop that checks its
element indices into a main loop it has proved needs no check and the few
iterations around it that might fail one, which still check and stop the
program as the spec says. It runs inside `-O2` once each loop is rotated.
An optimized build emits each loop it could help twice, with branch
weights saying the long copy goes round 1,000 times and the short one 4,
and IRCE splits only the long one, since the split costs a short loop more
than it saves. A loop that calls back into its own function is left as it
is: the call costs far more than the check.

### Code tuned for the processor clang would pick

- **Builds:** every build (x86-64 targets)
- **Where:** `lib/codegen/build.ml` (`cpu`)
- **Design:** [`design/lowering.md`](design/lowering.md) L2
- **Effect:** without it, `trialdiv` is 1.4× slower
  ([#203](https://github.com/zane-lang/compiler/issues/203))

The target machine tunes for `x86-64` on x86-64 and `core-avx2` on
`x86_64h`, as clang does, rather than LLVM's bare `generic`. Both allow only
instructions every processor of the architecture has, so the binary runs
anywhere its target does, but get clang's choices, among them a 32-bit
divide when both 64-bit operands fit.

### Small values cross calls in registers

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`passing`, `returning`, `pieces`,
  `registers`, `results`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "How a value
  crosses a call"
- **Effect:** measured by `just bench-abi`; results pending. Results of
  three pieces in registers rather than through `sret`: the `returns` perf
  program's estimated cycles fall 5.4% optimized and 1.1% plain, and
  langbench's `ntree` spends 9.4% fewer instructions in `grow`
  ([#276](https://github.com/zane-lang/compiler/issues/276))

A value of no more scalar pieces than the target's C convention gives one
aggregate (2 on x86-64 Linux/macOS and AArch64, 1 on x86-64 Windows) is
passed as itself, and a larger one by address. A result of up to three
pieces, at most two of them floating-point, comes back as itself on x86-64
and AArch64, so a string or list handle does; a larger one comes back
through `sret`. An argument that is already a place is lent where it is,
with no copy.

### Packed aggregates

- **Builds:** opt-in (`--pack-aggregates`)
- **Where:** `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Packing, an
  option"
- **Effect:** under measurement; kept only if faster on some target and
  slower on none

An aggregate that fits in its registers' bytes is passed as 8-byte integer
words, as clang passes a small C struct, so `{ I8; I8; I8; }` takes one
register. Every symbol gets a `~packed` suffix so mismatched objects fail
to link.

### What LLVM is told about parameters

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`, and `lib/cgt/program.ml` for which
  parameters are whole slots
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "What LLVM is
  told" (under "How a value crosses a call")
- **Effect:** marking `&T` parameters took the perf program `borrows` from
  70.9M to 59.5M estimated cycles optimized (−16%), and from 72.6M to
  64.1M tiered (−12%); its plain build and every other perf program are
  unchanged

A parameter passed by address is `readonly`, `noalias`, aligned and
`dereferenceable` for its size, so LLVM may treat the value behind it as a
private copy. An `sret` result is `noalias`. Call sites carry the same
attributes. A parameter that is the address of a slot that outlives the call, a
`mut` subject, an owned value passed by address or an `&T`, is `nonnull`,
aligned and `dereferenceable` for the whole slot when the slot holds a
declared type, a list or a text, so a loop reads a list in it once rather
than after every index check. A runtime value such as `Console` has no
layout lowering knows, and gets none of these.

### List headers and scalars in separate alias classes

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`!tbaa`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "What LLVM is
  told"
- **Effect:** a loop writing and re-reading a list's elements keeps no
  index check, and a loop that removes scalar elements keeps the count in a
  register (`tests/objects/facts_test.py`)

Type-based alias tags say a list handle's fields never alias a scalar
place, so writing an element's field does not invalidate the count and
block LLVM already loaded, nor the bounds check made with them. A removal
of elements that hold no handle moves them as scalars, so it leaves the
count too, and a loop removing from the list on one path reads the count
once rather than on every pass
([zane-lang/compiler#296](https://github.com/zane-lang/compiler/issues/296)).
That takes 1.05% of `tests/perf/removal`'s estimated cycles in an optimized
build and 2.14% in a tiered one, and 7.8% of the instructions `main` runs in langbench's
`gameloop` at 2,000 frames.

### Runtime functions described to LLVM

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "What LLVM is
  told"
- **Effect:** not measured

`zane_out_of_range` and `zane_too_deep` are `noreturn`, `cold` and
`nounwind`, so the paths to them are laid out of the way. `zane_text_equal`
only reads memory, so loads before it stay valid after it.

### Inline index checks

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "An index out
  of range"
- **Effect:** not measured

A list or array index is checked where its address is made with one
unsigned compare covering both ends; only a failure calls the runtime. LLVM
sees plain arithmetic and can hoist or drop checks it proves redundant.

### Inline list operations

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region" and "What LLVM is told"
- **Effect:** with list growth in place, `listgrowth` runs in under half
  its former time, within a few percent of C's `realloc`

A new list is the constant empty handle. A push with room left takes the
element's address and bumps the count inline, calling `zane_list_push`
only when the block is full (on a branch marked unlikely). `remove` and
`swapRemove` are an inline `memmove`/`memcpy` and a decrement.

### Scope frames at constant offsets, entered and drained inline

- **Builds:** every build
- **Where:** `lib/codegen/frames.ml`, `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "A scope's
  slots are one frame, in one range per context"
- **Effect:** telling LLVM the frame may be read: `tests/perf` `flips`,
  tiered, 6.6% fewer estimated cycles

Each scope's slots form one frame at fixed offsets, placed back to back in
one range per context. While no spawned call is out, entering a scope is a
bump of the frontier and a few stores, and a drain with nothing to wait for
or return moves the frontier back, with no runtime call. The open scope
tells LLVM with `llvm.assume` that any slot of its frame may be read and
that the frame is 16-byte aligned, so a loop reads a list kept in the
frame once.

### Emitted walks per type, shared between alike types

- **Builds:** every build
- **Where:** `lib/codegen/walks.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each type's
  walks"
- **Effect:** `treecopy` 2.6× faster than decoding a table at run time

Copy, end, move and overwrite are compiled per type, reading each handle
and box at its known offset and calling the next walk directly, instead of
the runtime interpreting a layout. Types that walk alike share one set.

### Inline block allocation for copies and boxes

- **Builds:** every build
- **Where:** `lib/codegen/walks.ml`, `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each type's
  walks"
- **Effect:** `binarytrees` uses a third of the instructions it did

A copy or box that fits a size class takes its block inline, from the top
of the class's free stack or else the region's frontier, when the region is
the thread's own. Only a miss calls the runtime.

### Snapshots as one atomic load

- **Builds:** every build (programs that spawn)
- **Where:** `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Snapshots"
- **Effect:** trialdiv, fannkuch and entities 1.8–4.6× faster than the
  runtime call ([#203](https://github.com/zane-lang/compiler/issues/203#issuecomment-6062273902))

An 8-byte, 8-aligned snapshot is a single `unordered` atomic load (acquire
when it holds an address) instead of a call, since a write-back stores
those 8 bytes in one store.

### Branch hints on rare paths

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`unlikely`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Integer
  division by zero…" and "A scope's slots are one frame…"
- **Effect:** not measured

A full list, a frame past the range's end, and a division by 0 or −1 branch
to blocks weighted 1:2000. Division tests its divisor with a predicted
branch, so the `sdiv` starts as soon as its operands are ready.

### LLVM intrinsics for exact math and truncation

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`, `lib/cgt/math.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) L17, §9, "Integer
  division by zero, and a float truncated out of range"
- **Effect:** not measured

Exact math functions are instructions or LLVM intrinsics (`llvm.sqrt`, …),
and `truncate` is `llvm.fptosi.sat`, so LLVM can fold and vectorize them.

### Literal strings embedded, never allocated

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`text`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "A literal's
  bytes stay where the program keeps them"
- **Effect:** not measured

A literal's handle points at private, `unnamed_addr` constant bytes with a
room of 0, so it takes no block, returns none, and copies of it share the
bytes. LLVM may merge identical literals.

### Large aggregates moved as memory

- **Builds:** every build
- **Where:** `lib/codegen/big_moves.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Large
  aggregates as memory"
- **Effect:** not measured

A load of an aggregate of 4 KiB or more used only by stores becomes a
`memcpy` (or `memmove`, when source and destination may overlap) per store,
rather than a value of thousands of parts.

### `main` inlined into the start function

- **Builds:** optimized only
- **Where:** `lib/cgt/program.ml`, LLVM's inliner
- **Design:** [`design/lowering.md`](design/lowering.md) L16
- **Effect:** not measured

The program's entry is the start function `zane.start`, emitted as
`zane_main`, which makes the package constants and then calls `main`. LLVM
inlines `main` into it, so an optimized program pays no call between them.

---

## Runtime (`runtime/`)

### Size-class free stacks and a bump frontier

- **Builds:** every build
- **Where:** `runtime/arena.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** not measured

A region allocates by bumping a frontier and reuses returned blocks from a
stack per size class, kept at fixed offsets so emitted code reads them
directly. A drain releases the whole region at once and walks none of its
values.

### List growth in place

- **Builds:** every build
- **Where:** `runtime/list.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** `listgrowth` in under half its former time, within a few
  percent of C's `realloc`

A list's block doubles from 128 bytes, in place when it is last at the
frontier. Past 1 MiB it moves once into a reservation 64 times its size,
and each later doubling commits more of it instead of moving the elements.

### Every overwrite in place

- **Builds:** every build
- **Where:** `runtime/value.c`, `lib/codegen/walks.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Every
  overwrite is in place"
- **Effect:** not measured

An overwrite writes the replacement into the occupant's existing blocks,
recursively, instead of freeing them and allocating new ones.

### Warm and cold spare chunks

- **Builds:** every build
- **Where:** `runtime/arena.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Dynamic
  chunks come from the system directly"
- **Effect:** with no delay before chunks turn cold, `ntree` 10 was 38%
  slower and `treecopy` 18 54% slower; the delay removes that with no
  change to peak memory

A drained chunk is kept resident for reuse (4 for good per context, others
for up to 8 later drains, 16 in a shared pool) before its pages are given
back, so a program that drains and refills scopes does not fault its pages
in again each time.

### Frame range committed as it is touched

- **Builds:** every build
- **Where:** `runtime/region.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The range is
  reserved, and becomes usable as it is touched"
- **Effect:** not measured

Each context's frame range is reserved without access and committed a MiB
at a time on first touch, so the program is charged only for the frames it
uses.

### Buffered output

- **Builds:** every build
- **Where:** `runtime/main.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The
  program's output"
- **Effect:** not measured

Prints go into the runtime's own buffer of stdio's size, flushed when full,
at exit, and per line only when stdout is a terminal.

### Work-stealing pool and reused contexts

- **Builds:** every build
- **Where:** `runtime/spawn.c`, `runtime/snapshot.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The pool
  steals work" and "Each spawned call has a context of its own"
- **Effect:** not measured

Each worker runs its own newest call first and steals another's oldest when
idle. A thread waiting for a call nobody has started runs it itself. A
finished call's context, and its frame range, go back to a pool for the
next spawn.
