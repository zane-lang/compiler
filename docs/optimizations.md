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
calls the function, or its local copy, which takes the value rather than
copying it.

### Walks written out where a loop calls them

- **Builds:** every build
- **Where:** `lib/cgt/verbs.ml` (`walk_size`, `walks`), `lib/cgt/lower.ml`
  (`code`), `lib/cgt/lower_calls.ml` (`writes_out`, `expand`)
- **Design:** [`design/lowering.md`](design/lowering.md) L11
- **Effect:** estimated cycles of the perf programs it changes, plain,
  optimized and tiered: `division` −10.0%, 0.0% and −0.4%, `paths` 0.0%,
  −0.6% and 0.0%, `stress` −0.2%, −0.4% and −0.3%; the rest are built the
  same. A hash probe written as a plain function and called in a loop ran
  as fast as its call (×0.96 to ×1.00, best of 5 paired runs each, 256 KiB
  to 2 GiB tables, 4-core Xeon at 2.1 GHz): the gain is in what codegen's
  loop analyses can then do with the walk. The compiler runs 3.2% more
  instructions building `stress` plain and 0.1% fewer optimized

A function a loop's body calls is written out there when it is given a
list or reference to read through, writes none of it (no `mut` method),
takes no owner, calls itself nowhere, declares no abort and is at most 120
nodes. A search written as a function becomes a loop inside the caller's,
so codegen's loop analyses see its reads, and a `return` from inside its
loop leaves only the copy. Nothing inside a walk is written out as one
again, and the function stays for every call outside a loop.

### Conversions lent rather than copied

- **Builds:** every build
- **Where:** `lib/cgt/lower_calls.ml` (`lent`, `lent_arguments`)
- **Design:** [`design/lowering.md`](design/lowering.md) L11, "Lent
  conversions"
- **Effect:** a loop reading every byte of a string through a wrapper's
  implicit conversion into a foreign verb, as LangArena's `byte(text, i)`
  does, goes from quadratic to linear: at 64 KiB, 4.32 billion
  instructions to 0.73 million; at 512 KiB, 6.4 s to 2 ms, optimized and
  plain alike. No perf program or golden tree changes

A call whose argument is a verb returning one of its parameters' members,
such as `core`'s `implicit @primitives$String(v String) => v._value`, is
given the member where the caller keeps it rather than a copy, when the
argument only lends it to a borrow parameter and nothing in the call can
write the source: the call is direct and unspawned, the callee writes
none of its parameters, and every other argument is a plain read.
A value has no identity and a borrow is read-only, so only time and
allocation change.

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
  a fresh argument is moved in rather than held and copied. A function whose
  calls must keep their signature (one another package's object defines, one
  this object exports, or one called through its address), such as core's
  `String(@primitives$String)`, gets a local copy that takes it, which only
  calls passing a fresh argument use;
- a local returned, aborted with, or returned to an expansion is moved out of
  its slot rather than copied, since the exit ends it, unless the function
  spawns;
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

### Plain loads where nothing is written back

- **Builds:** every build (programs, not libraries)
- **Where:** `lib/cgt/program.ml` (`written_back`),
  `lib/cgt/type_layout.ml` (`owned_place`, `snapshots`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Snapshots"
- **Effect:** lets LLVM forward stores to loads, keep fields in registers
  across loops and vectorize them, which no atomic load allows. Summing a
  `List<Int>` in a program that spawns a call writing nothing back: 6.00 G
  instructions as snapshots, 3.50 G as plain loads, what the program takes
  without its spawn

A value read through an owner may race a spawned write-back, the only write
another thread makes to a place this thread can read. A write-back comes
only from a spawned `mut` call whose subject is reached through an owner, so
the places it can write are known from the source of every package in the
build, each as the type of its innermost owner and the members, cases and
elements down from it. A read takes a snapshot only when its place overlaps
one of them; every other such read is a plain load, as is every read in a
program that spawns nothing. Writing back `tally.n` leaves every other
`Int` read plain.

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
- **Where:** `lib/cgt/memo.ml`, `lib/codegen/memos.ml` (`memo`)
- **Design:** [`design/memoization.md`](design/memoization.md)
- **Effect:** [`dev/bench/memo/`](../dev/bench/memo/README.md), in plain,
  optimized and tiered builds: recursions that repeat their arguments
  70–99.6% fewer estimated cycles, among them a tic-tac-toe search keyed on
  its board (94–96%) and a recursion that calls itself once, called again
  from a loop (96–98%); a heavy call in a loop whose arguments repeat
  93%; programs whose arguments do not repeat, or whose repeats save less
  than a lookup costs, within +0.71%, but one that LLVM folds whole without
  a table, which costs a fixed 22,000 cycles more. Over 150 random
  recursions, a median of 86% fewer plain, 37% optimized and 36% tiered,
  and at worst +0.34%, +0.95% and +1.79%.

A function whose result depends only on its arguments, which takes and
returns fixed-size values, and which calls back into its own cycle, or is
heavy and called from a loop, keeps a table of its results, so a call whose
arguments repeat returns at once. Each function scores its lookups against
the work its hits save, counted from below, and stops looking for good when
they do not pay. A loop decides once, before it starts, whether its calls
still look, so a loop whose functions have stopped runs as written. In a
program that spawns, and in a library, threads share each table, whose
entries' versions a lookup reads before and after it reads them, and keep
their own state and count of work. A table holds at most 256 KiB, in
memory the system backs only where an entry has been written.

### Struct members ordered by alignment

- **Builds:** every build
- **Where:** `lib/cgt/nodes.ml` (`Ty.order`, `Callback.to_c`,
  `Callback.of_c`), `lib/cgt/type_layout.ml` (`shape`, `member_index`),
  `lib/cgt/lower_foreign.ml`, `lib/cgt/callbacks.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) L5;
  [`design/ffi.md`](design/ffi.md) F10
- **Effect:** a list of 2,000,000 `{Bool, Int, I32}` values peaks at
  34.1 MB instead of 49.8 MB, each element 16 bytes instead of 24

A struct's members are placed in decreasing order of alignment, those of
one alignment in declaration order, so the only padding C's layout would
leave is at the tail, which the next entry removes. Every list element,
array element, owner slot and box of the type shrinks with it. Placement
is not visible to a Zane program (spec `memory.md` §3.3, §3.5). C sees a
struct only as a copy, rebuilt in its declaration order as it crosses.

### Padded values packed, and a sum's tag in a spare byte

- **Builds:** every build
- **Where:** `lib/cgt/nodes.ml` (`Ty.tight`, `Ty.byte_niche`, `Ty.spare`),
  `lib/cgt/type_layout.ml`, `lib/codegen/emit.ml`, `lib/codegen/walks.ml`,
  `lib/codegen/alignment.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) L5;
  [`experiments/tight-layouts/README.md`](experiments/tight-layouts/README.md)
- **Effect:** a list of padded values peaks at 25–71% less memory
  (`experiments/tight-layouts` `bench/layouts`); `entities` runs
  10.5%, `paths` 6.5%, `copies` 4.8%, `particles` 4.9% and `tokens` 3.3%
  fewer estimated cycles optimized (`tests/perf`)

A struct that C's layout would pad is packed: its members follow one
another with no padding and its alignment is 1. A sum whose one case
carrying data has a byte with values it never holds, a `Bool` or a packed
sum's tag, keeps the other cases' tags in that byte and is no larger than
its payload; any other sum is packed with a one-byte tag, unless it has
more than 256 cases. A value of a
packed type may begin at any byte, so each load and store is as aligned as
its address is known to be, not as its type is. Placement is not visible
to a Zane program (spec `memory.md` §3.3, §3.5), so the compiler is free
to choose it; C sees
a C-compatible type in its own layout, converted as it crosses.

### One box per cycle

- **Builds:** every build; `ZANE_ONE_BOX=0` turns it off, and so does
  `ZANE_POOLED_VARIANTS=1`
- **Where:** `lib/cgt/type_layout.ml` (`boxed`)
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "One box per cycle"
- **Effect:** binarytrees at depth 14 runs 123.3 M instructions instead of
  186.9 M, and a node is one 32-byte block instead of three of 48 bytes in
  all; treecopy at 18 takes 0.073 s instead of 0.245 s (medians)

A variant's payload that leads back to the variant is boxed, and a struct
member is boxed only when it leads back without passing through such a
payload, whose box already breaks the cycle. So a node's members sit inline
in it, and a leaf allocates nothing.

### References and list handles in 32 bits

- **Builds:** every build for a Linux target; `ZANE_FRAME_REFS=0` turns it
  off, and with it the two entries below
- **Where:** `lib/cgt/ref32.ml`, `lib/codegen/list_handle.ml`,
  `lib/cgt/build.ml` (`stored_ref`), `runtime/region.c`, `runtime/zane.h`
- **Design:** [`experiments/goose-comparison/FINDINGS.md`](experiments/goose-comparison/FINDINGS.md),
  "The new model"; [`README.md`](experiments/goose-comparison/README.md),
  "Frame references" and "Room counted in elements"
- **Effect:** ntree at 10 peaks at 23.4 MB instead of 34.1 MB, and the
  edges test at 63.6 MB instead of 94.3 MB, both faster; listgrowth's push
  takes one instruction more

A stored `&T` is its owner's signed 32-bit distance in bytes from the
program's image (`__ehdr_start`): every context's frames come from the
2 GiB below the image, or from 512 MiB above it within 2 GiB when the
program is loaded too low for that (as under Valgrind), and globals are in
it, so every reference fits, and reading one is one address computation. A list's handle is 16 bytes: its
items pointer, then a 32-bit count and a 32-bit room counted in elements,
so a list holds up to 2^32 − 1 elements. A push adds to the count at 32
bits, so LLVM folds the element's address into its store. Other targets
keep 8-byte references and 24-byte handles, since the layout needs the ELF
linker's `__ehdr_start` and Linux's `MAP_FIXED_NOREPLACE`.

### Boxes in 32 bits

- **Builds:** every build for a Linux target; `ZANE_IMAGE_BOXES=0` turns
  it off, and `ZANE_CHUNK_BOXES=1` numbers boxes by chunk instead
- **Where:** `lib/cgt/ref32.ml`, `lib/codegen/list_handle.ml`
  (`encode_box`), `runtime/region.c` (`zane_window_take`)
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "Image-relative boxes"
- **Effect:** binarytrees at 16 peaks at 8 MB instead of 10 MB, 0.042 s
  against 0.046 s (medians); binarytrees runs 8% more instructions and
  treecopy 19%, which do not show in time. Numbering boxes by chunk is
  about 5% slower on binarytrees

A boxed member is its block's signed distance from the image in 8-byte
units, which reaches 16 GiB either way, and 0 is null. The runtime takes
every 1 MiB chunk from a window it reserves once, from 16 GiB to 2 GiB
below the image, or the largest of 12, 8, 4 or 2 GiB free from 4 GiB above
it when the program is loaded too low for that, so every box fits. A
list's growing span and a pool lie outside the window, since their handles
hold 8-byte pointers.

### A sum of nothing or one box is one word

- **Builds:** every build for a Linux target with boxes in 32 bits (above,
  so `ZANE_FRAME_REFS=0` or `ZANE_IMAGE_BOXES=0` without
  `ZANE_CHUNK_BOXES=1` turns it off too); `ZANE_NICHE_SUMS=0` turns it off
- **Where:** `lib/cgt/nodes.ml` (`Ty.niche`), `lib/codegen/emit.ml`,
  `lib/codegen/walks.ml`
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "A node as small as Goose's"
- **Effect:** binarytrees at 20 peaks at 34 MB instead of 66 MB, with the
  same time

A two-case sum whose first case carries nothing and whose second is a box
or a reference needs no tag: it is the 4-byte word, 0 for the first case,
since no stored box or reference is 0. A binarytrees node is then one
8-byte block.

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

### Calls into C run at compile time

- **Builds:** optimized only
- **Where:** `lib/optimize/c_eval.ml`, `lib/optimize/c_cross.ml`,
  `lib/optimize/c_ir_stubs.cpp`, `lib/optimize/handles.ml`
- **Design:** [`design/ffi.md`](design/ffi.md) F16–F19
- **Effect:** folds the checksum of a literal, a data handle's whole life,
  a C sort with a Zane comparison and a string C returns in the
  `folding` fixture of `tests/ffi/`

A foreign call whose arguments are known, and which reaches no
capability, runs at compile time: a second evaluator interprets the LLVM
IR of the package's C, before LLVM has optimized it, with memory as bytes
and the target's layout, and the values cross in the layout the glue
gives them. A data handle made and released within the fold folds with
it, its setter and free function run in the order the program runs them.
Undefined behavior, a `volatile` or atomic access, a fast-math flag, an
address's number, storage whose identity is unknown, and a C function
the build has no body for, such as `sin`, stop the fold and leave the call
to run. C evaluation spends the fold's budget.

A call that reads C state the package keeps and that no capability names
folds from that state's first value, so the optimized build can print
what the plain one does not (spec `ffi.md` §5.5): the `hazard` fixture
prints `1`, `1`, `1` optimized and `1`, `2`, `3` plain.

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

### Base cases copied before a function's calls to itself

- **Builds:** optimized only; `ZANE_PARTIAL_INLINE=0` turns it off
- **Where:** `lib/optimize/peel.ml`
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "Partial inlining" and "What a lead hides"
- **Effect:** binarytrees' `make` at depth 14 runs 60.7 M instructions
  instead of 92.2 M, and the program 90.6 M instead of 123.3 M

In a function whose cheap way out fits the rules below, each call it
makes to itself is preceded by a copy of that way out, so building a
leaf, or counting one, is not a call. The copy keeps only the branches that call nothing and do a few
steps of work, and only effects that are part of the value it returns, so
the call does nothing again that the copy did. LLVM never inlines a
function into itself, and runs no partial inliner at `-O2`.

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
to it. The runtime is compiled with `-O2` too, and so is the one linked by
tier 0 of a tiered build, since tier 1 calls it
([`design/tiers.md`](design/tiers.md) T5). The
compiler implements a transformation itself only where it rests on
something about Zane that LLVM does not know.

### The runtime's bodies inlined

- **Builds:** optimized only, and both tiers of a tiered build
- **Where:** `lib/codegen/runtime_bodies.ml`, `lib/codegen/build.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §7,
  [`design/tiers.md`](design/tiers.md) T5
- **Effect:** `tests/perf` `texts` 16% fewer estimated cycles optimized,
  `scopes` 7%, `zalloc` 4%, `returns` 4%, against the runtime linked as an
  object

The runtime is compiled to LLVM bitcode too. An optimized executable links
the whole of it into its module, as the program's own, in place of the
runtime's object, so LLVM optimizes the two as one program; a tiered build,
and a library object, which run another object's runtime, take only the
bodies safe to copy, the functions of the runtime they call, for LLVM to
inline. In optimized code, tier 1's included, allocation, deferral and
text joins then cost no call, and printing none in an executable with the
whole runtime; with only the bodies, printing still calls the runtime,
whose output buffer is its own. Tier 0, built unoptimized, keeps the calls.
A runtime function that runs off the hot path, such as `zane_hold` under
checked drains, is marked cold and stays a call, and so does a push's
slow-path call, whose fast path emitted code already has.

### A package's C inlined into the Zane that calls it

- **Builds:** optimized only
- **Where:** `lib/codegen/foreign_c.ml`, `lib/codegen/build.ml`,
  `lib/codegen/retain_stubs.cpp`, `lib/foreign/glue.ml`
- **Design:** [`design/ffi.md`](design/ffi.md) F8, F13
- **Effect:** not measured

A package's C modules and its glue are linked into the program's module
before LLVM's passes run, so a foreign verb's function, the thunk it
calls and the C function the thunk calls are one program to the inliner:
a call into a small C function becomes its body at the call site, with
no argument table or result slot left. Each package's C globals are
renamed first (F9), so linking them in cannot bind one package's names
to another's. A dependency linked as a release has its C and glue compiled
from its checkout and linked in as bodies to inline only, where their
hashes agree with the ones the release published and nothing can tell an
inlined copy from the dependency's object (F13).

The `retained` fixture of `tests/ffi/` shows it: its
`golden/retained.released.calls` lists which parts of a release's C the
optimized build still calls, the rest inlined or folded at compile time. What an `archive` row's
library and an assembled object hold is the exception, called as the
dependency's object defines it, and the `archives` fixture's
`golden/archives.released.calls` shows that.

### A package's C optimized apart in unoptimized builds

- **Builds:** unoptimized only, and a tiered build's tier 0
- **Where:** `lib/codegen/build.ml`
- **Design:** [`design/ffi.md`](design/ffi.md) F14
- **Effect:** not measured

An unoptimized executable still runs its C optimized: the C modules and
glue are linked into a module of their own, run through `-O2` and emitted
as an object, which the cache keeps under a hash of the target, the
compiler and each source's own key (F3), so a rebuild that changes only
Zane emits none of it again. The Zane module stays unoptimized and calls the thunks. A
tiered build's tier 0 links the same object, and tier 1 calls its thunks
through tier 0.

### Functions started on a cache line

- **Builds:** optimized only
- **Where:** `lib/codegen/passes.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** `tests/perf` `copies` kept from 5% more estimated cycles when
  code before its loop changed size

Every function starts on a 64-byte boundary, so the branches inside it keep
their place within their lines however the code before them changes, and a
change to one function does not move another's into a predictor's
conflicts.

### Memo tables started on a cache line

- **Builds:** every build; `--no-memoize` turns tables off
- **Where:** `lib/codegen/memos.ml` (`memo`)
- **Design:** [`design/memoization.md`](design/memoization.md) M2
- **Effect:** `tests/perf` `depths` kept from 72% more first-level cache
  misses when the table landed 16 bytes past a line

Each memo table is aligned to 64 bytes, so where it lands in the binary
does not decide which of its entries straddle two cache lines.

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
  `lib/llvm/config/discover.ml`
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

### A sum's case picked without a branch

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/passes.ml` (`llvm_options`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** `tests/perf` estimated cycles: `entities` 23.9% fewer
  tiered (67% fewer mispredicted branches) and 7.5% fewer optimized,
  `floats` 4.7%, `scopes` 2.6–4.7%, `particles` 3.1–3.2% fewer; `growth`
  2.5% more ([`experiments/tight-layouts`](experiments/tight-layouts/README.md)
  step 14)

LLVM's instruction combining is kept from sinking instructions into the
block that uses them. It reads a packed sum as its tag and its room, and
with sinking on it moves the room's load into the case that reads the
payload, where nothing tells LLVM the load is safe to make before the tag
is tested. Left beside the tag's load, the room is read either way, and a
case's test and payload become a select instead of a branch on the tag
that the predictor cannot learn.

### Loops unrolled past `-O2`'s budgets

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/passes.ml` (`llvm_options`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** `tests/perf` estimated cycles: `paths` 42.8% fewer,
  `borrows` 11.9%, `returns` 10.0%, `kept` tiered 5.2%, `particles` 3.6%,
  `entities` 3.4%, `repeats` 3.1% fewer; `removal` 1.1% more; langbench
  `entities` 8.6% fewer, `nbody` 3.0% more; `.text` up to 10.5% more, tier 1
  of `repeats` 25% ([`perf-unroll`](perf-unroll/README.md))

LLVM is given a full-unroll budget of 250, against `-O2`'s 150, and a
partial-unroll budget of 100. A loop of a few constant iterations whose
body tests the counter becomes straight-line code with each test decided,
and a counted loop over a list shares its copies' index arithmetic and
bounds checks. Unrolling never changes what a program means. A cold loop's
copies can cost a hot loop in the same function a register, and a loop that
runs only one to four times is unrolled four times for nothing.

### Index checks taken out of long loops

- **Builds:** optimized only (and tier 1)
- **Where:** `lib/codegen/passes.ml` (`optimized`),
  `lib/llvm/config/discover.ml`, `lib/codegen/emit.ml` (`versioned`,
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
and IRCE splits the long copy and not the short one, since the split costs
a short loop more than it saves. A loop that calls back into its own
function is left as it is: the call costs far more than the check. A loop
emitted once has no weights, and IRCE splits it on LLVM's guess; loop idiom
recognition may then make its main loop a `memmove` call. In `flips` that
call, about 12 bytes, costs fewer estimated cycles than either way of
keeping the loop ([`design/lowering.md`](design/lowering.md) §9, "The
passes", has the measurements).

### Reads through a loaded index prefetched ahead

- **Builds:** optimized, and both tiers of a tiered build, which emit one
  module; `ZANE_PREFETCH=0` turns it off
- **Where:** `lib/codegen/lookahead.ml`, `lib/codegen/emit.ml`
  (`prefetch`), `lib/codegen/loop_shapes.ml` (`facts`, `counter`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes";
  [`experiments/prefetch-reorder`](experiments/prefetch-reorder/README.md),
  round 5
- **Effect:** wall clock, 4 KiB pages, paired runs on one cloud Xeon, best
  of 5: the model's `heavy` ×2.12 at 32 MiB and ×1.96 at 2 GiB, `hash`
  written as a plain function ×1.89 and ×2.68, neither slower at 256 KiB
  ([`prefetch-reorder`](experiments/prefetch-reorder/README.md), rounds 5
  and 7); `gather`, `tree` and `chains` unchanged in round 5; no
  `tests/perf` program's build changes

A counted loop whose body branches, switches or loops, and reads a list at
an index worked out from another list's element, as `recs[idx[i]]` or a hash
probe's home slot is, prefetches at the top of each time round the element it
will read 32 iterations on. The address of that read is made of constants,
the counter, locals the loop leaves alone, integer arithmetic that cannot
fail, and element reads, each made early only when its index is inside its
list, so nothing it reads early can stop the program; the body's own reads
and their checks stay where they are. Each list read early is in a slot or
a struct's member reached from one, never in a variant's payload or an
element of another list, whose read the top of the loop could not make
without a check. A loop that walks a chain is left
alone, as is a light body such as `s += a[idx[i]]`, which the model found
nothing to gain on with 4 KiB pages.

### Short loops that leave early unrolled twice

- **Builds:** every build marks the loops; optimized builds and tier 1
  act on the mark
- **Where:** `lib/codegen/emit.ml` (`unrolled`, `unroll_twice`),
  `lib/codegen/llvm_stubs.c` (`zane_loop_id`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** `tests/perf` `floats` 16.5% fewer estimated cycles, optimized
  and tiered; `stress` 0.6% (optimized) and 1.1% (tiered) and `division`
  1.0% fewer; every other program unchanged

A counted loop that can return or leave a block before its count runs out,
and holds no loop, spawn, join or call, has its back edge marked
`llvm.loop.unroll.count` 2. Such a loop has two exits, which `-O2` merges
into one test where both lead to the same place, and its cost model on
x86-64 leaves even a dozen arithmetic operations rolled, so without the
mark Mandelbrot's escape test runs one step per trip. A loop that calls is
left alone: the call costs more than the test unrolling saves, and
unrolling the loop the memo pass checks made `depths` 2.5% slower.

### Loops unswitched on AArch64

- **Builds:** optimized only (and tier 1), AArch64 targets
- **Where:** `lib/codegen/passes.ml` (`unswitch`, `nontrivial`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** on Apple silicon, a loop over 13-byte packed values whose
  field a loop-invariant condition picks runs 32% faster than over the
  unpacked layout instead of 28% slower
  ([`experiments/tight-layouts`](experiments/tight-layouts/README.md))

A loop whose body branches on a condition the loop does not change is
copied once for each way it goes, so each copy steps a pointer by a packed
element's stride instead of multiplying the index by it on every pass. On
x86-64 the copies cost more than they save, and the pass is left out.

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

A parameter passed by address is `readonly`, `noalias` and
`dereferenceable` for its size, so LLVM may treat the value behind it as a
private copy. An `sret` result is `noalias` and aligned. Call sites carry the same
attributes. A parameter that is the address of a slot that outlives the call, a
`mut` subject, an owned value passed by address or an `&T`, is `nonnull`
and `dereferenceable` for the whole slot when the slot holds a
declared type, a list or a text, so a loop reads a list in it once rather
than after every index check. A runtime value such as `Console` has no
layout lowering knows, and gets none of these. Neither kind claims an
alignment: what it names may be a member at any byte of a packed value.

### List headers and scalars in separate alias classes

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`!tbaa`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "What LLVM is
  told"
- **Effect:** a loop writing and re-reading a list's elements keeps no
  index check, a loop that removes scalar elements keeps the count in a
  register, in optimized and tiered builds, and pushes of scalars in a row
  keep the count and room (`tests/objects/facts_test.py`)

Type-based alias tags say a list handle's fields never alias a scalar
place, so writing a scalar field of an element, or a scalar element a
push makes room for, does not invalidate the count and block LLVM already
loaded, nor the bounds check made with them. A removal
of elements that hold no handle moves them as scalars, so it leaves the
count too, and a loop removing from the list on one path reads the count
once rather than on every pass
([zane-lang/compiler#296](https://github.com/zane-lang/compiler/issues/296)).
That takes 1.05% of `tests/perf/removal`'s estimated cycles in an optimized
build and 2.14% in a tiered one, and 7.8% of the instructions `main`
executes, as Callgrind counts them, in langbench's `gameloop` at 2,000
frames.

### Runtime functions described to LLVM

- **Builds:** every build
- **Where:** `lib/codegen/runtime_facts.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "What LLVM is
  told"
- **Effect:** `tests/perf/returns` −1.4% estimated cycles optimized and
  tiered; nothing else in `tests/perf` or langbench moves
  ([`perf-runtime-attrs/`](perf-runtime-attrs/README.md))

`zane_out_of_range` and `zane_too_deep` are `noreturn`, `cold` and
`nounwind`, so the paths to them are laid out of the way. `zane_text_equal`
only reads memory, so loads before it stay valid after it.
`zane_list_push`, `zane_list_reserve` and `zane_list_room` keep no pointer
to the list's handle (`captures(address)`): a handle in a local slot stays
the function's own across other calls, so LLVM knows a fresh list is still
empty at its first push after a call, as in `returns`' `grow`, and drops the
check for room. An optimized or tiered build puts these back after it links
the runtime's bodies, which replace the declarations.

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
only when the block is full (on a branch marked unlikely), and an empty
list's first block is often made inline too (below). `remove` and
`swapRemove` are an inline `memmove`/`memcpy` and a decrement; a long
removal of small elements moves in pieces (below).

### An empty list's first block made inline

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`, `runtime/list.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** `tests/perf` `scopes` 16% fewer estimated cycles optimized,
  13% plain

A push of an element of at most 128 bytes onto an empty list in the
innermost scope's region makes its first block itself: four elements'
bytes, rounded to a word and kept between 32 and 128, from the region's
free stack for that size, the heap's room or a fresh stretch of the frame,
in a function with a scope of its own open, when the scope has no returned block and its frame or heap
has the room. Elsewhere
`zane_list_push` makes it without a call of its own. A function with no
scope keeps the call, so a short loop of pushes there stays small enough to
unroll.

### Runs of pushes given their room at once

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml`, `runtime/list.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** `tests/perf` `scopes` 14% fewer estimated cycles optimized,
  13% plain, 15% tiered; the allocation benchmark `zalloc` 15% optimized

A new list followed by a straight run of pushes, with nothing between
them naming the list or able to leave, has room made for the whole run at its first push,
in the first block the push makes itself when the run fits in it, else by
`zane_list_reserve`. Every other push of the run is then a store and a new
count, with no look at the room. Only the run's own pushes can reach a new
list, each at most once, and the first comes before the rest, so the room
it makes is never short. A held slot is listed for a checked drain before
it is written, so LLVM sees the new list's empty header as the last write
before the run.

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

### Scopes with no blocks on the machine stack

- **Builds:** every build; `ZANE_LIGHT_SCOPES=0` turns it off
- **Where:** `lib/codegen/loop_shapes.ml` (`light`), `lib/codegen/emit.ml`
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "allocfree, fixed"
- **Effect:** with a loop's pushes given their room before it (below),
  allocfree runs 108.4 M instructions instead of 255.7 M and takes 0.308 s
  instead of 0.729 s (medians); particles 136.0 M instead of 144.6 M

A scope nothing can put a block in opens no region, and its frame, when it
is 4 KiB or less, is a slot of the function on the machine stack. Every
slot it places holds scalars, and its body makes no box, list or string,
copies only scalars, and neither spawns nor joins; it calls the runtime
only to index, push, make room in a list, remove scalars, compare strings
or parse, and calls functions only for scalar results. With references
in 32 bits, a scope that gives a call an address, or makes a reference
itself, keeps its frame among the context's frames, which a reference
reaches.

### A loop's pushes given their room before it

- **Builds:** every build; `ZANE_LOOP_PUSHES=0` turns it off. An optimized
  build also writes `core`'s `push` out in a loop
  (`lib/optimize/loop_pushes.ml`), so the emitter sees it
- **Where:** `lib/codegen/loop_shapes.ml` (`looped_pushes`),
  `lib/codegen/emit.ml`, `lib/optimize/loop_pushes.ml`
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "listgrowth: where the push's instructions go"
- **Effect:** listgrowth's push runs 16 instructions instead of 25, and the
  program takes 0.174 s instead of 0.216 s (medians), level with Goose.
  LangArena's `repros/list-fill` (ten fills of a million `I32`s through
  `core`'s `push`) runs 6.66 M instructions instead of 115.7 M, a vector
  store loop; Graph::AStar 8.61 G instead of 22.79 G, Maze::AStar 5.75 G
  instead of 10.53 G

A counted loop that cannot leave early and pushes once each time round onto
a list nothing else in the loop can change gets room for every push from
one `zane_list_room` before it, and each push is a store with no check of
the room. A count whose bytes no block could hold stops the program there,
out of memory, before any of those pushes. A loop leaves early when it returns or leaves an expansion around
it (`Cgt.Traverse.leaves`); a verb expanded inside it, a written-out push
or the counter step of `core`'s `to`, ends with a leave of its own
expansion, which keeps the loop running. Nothing in such a loop pushes to, makes room in or removes from
another list, spawns, or calls a function that could, which a
whole-program analysis tells in an optimized build. A call into C could
only through a function value C was given, so it counts as one that could
unless the program is a whole program that gives C none and holds every
function's body ([`design/ffi.md`](design/ffi.md) F10). A struct of scalars is stored member by
member with the scalar alias tag, so LLVM keeps the count and the
element's address in registers through the loop.

### List handles read once before a loop

- **Builds:** every build; `ZANE_HOIST_HANDLES=0` turns it off
- **Where:** `lib/codegen/loop_shapes.ml` (`invariant_lists`, `own_lists`),
  `lib/cgt/list_pure.ml`, `lib/optimize/loop_pushes.ml` (`pure`),
  `lib/codegen/emit.ml`
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "fannkuch: list handles read once a loop"
- **Effect:** fannkuch at 9 runs 151.5 M instructions instead of 169.3 M,
  in the same time. LangArena, Callgrind instructions against `main`:
  Graph::BFS 7.83 G instead of 12.87 G, Graph::DFS 5.90 G instead of
  7.77 G, Brainfuck::Recursion 35.59 G instead of 38.92 G,
  Brainfuck::Array 33.30 G instead of 35.47 G, Compress::HuffDecode
  27.74 G instead of 29.38 G, Etc::NeuralNet 23.77 G instead of 25.41 G;
  `tests/perf` `returns` −9.7% and `particles` −6.5% estimated cycles
  optimized

A counted loop whose body cannot change the handle of a list it indexes
reads that list's items and count once before the loop. The checks then
compare with a count the loop does not change, so in an optimized build
and tier 1, LLVM's IRCE takes them out of the loop and the loop can
vectorize. A list's count read as its size in the loop is the one read
before it too.

Such a body spawns nothing, writes only scalars through an address, and
calls the runtime only to index, or to push to, make room in or remove
scalars from a list only its function reaches. That is a list in a slot of
its own frame whose address is only indexed, read or written through, or
given to such a runtime call or to a verb whose whole body is a push. No
other address reaches that slot, so a push there,
even one inside an `if` that only sometimes runs and whose slow path calls
the runtime, changes no other list. The pushed list itself is not read
before the loop.

In an optimized build, which runs the whole-program analysis
(`Cgt.List_pure`), the body may also call a function that changes no
list's handle outside its own frame, or a verb whose whole body is a push,
such as `core`'s `push`, onto a list only the loop's function reaches. It may call into C when the program is a whole
program that gives C no function value and holds every function's body,
so C cannot call back into Zane: C is lent a list's elements, never its
handle ([`design/ffi.md`](design/ffi.md) F10).

A list in an element of a list read before the loop, at an index the
loop does not change, is read before it too: a member of such an element,
as `this.neurons[i].incoming` is in a loop over one neuron's synapses, and,
where the body pushes or calls, a list that is itself such an element, as
`this.adj[vertex]` is in a breadth-first search over adjacency lists, or an
element of one. The loop does not change the index: nothing in it binds or
assigns the index's local, or uses its slot's address other than to read
it, as a call of a verb that changes its subject does. Nothing through a
variant's payload is read this way: the payload may be another case's
bytes. Nothing is checked before the loop: when an index is out
of range, a zeroed element stands in, whose every list is empty, so the
first read through it in the loop stops the program where the element's
own read would have, and a loop that never reads it does not stop. A list
that is itself an element, in a loop that neither pushes nor calls, is left
to LLVM, which reads it once by itself; there the extra test before every
entry of a short loop costs more than it saves (LangArena Etc::NeuralNet
was 5% slower).

In an optimized build, a list an enclosing loop read before itself is
the one the inner loop uses: the enclosing loop's body, the inner loop
included, cannot change its handle. LLVM then sees the inner loop's bound
and the count read before it as one value. A plain build reads it again
before each inner loop instead, which is cheaper there (`tests/perf`
`entities` was 2.9% slower holding it).

### Ordered removals moved in 2 KiB pieces

- **Builds:** every build
- **Where:** `lib/codegen/emit.ml` (`remove`), `runtime/list.c`
  (`zane_shift_down`)
- **Design:** [`experiments/goose-comparison/README.md`](experiments/goose-comparison/README.md),
  "Ordered removals and `rep movsb` over a short distance"
- **Effect:** moving 60 KB down by 8 to 32 bytes runs at 57–60 GB/s
  instead of 3.1 GB/s on an Intel Xeon whose `rep movsb` is slow over a
  short distance; not visible to Callgrind, which models no `rep movsb`

A removal from a list of elements under 64 bytes that moves more than
4 KiB moves in 2 KiB pieces, lowest first. glibc's `memmove` copies 4 KiB
or more with `rep movsb`, which some processors run at about a byte a cycle
when the source is less than 64 bytes past the destination; each piece is
below that size, so it takes the vector loop. The pieces keep the scalar
alias tag, so a loop of removals still keeps the count in a register.

### Independent walks interleaved

- **Builds:** optimized, and both tiers of a tiered build;
  `ZANE_INTERLEAVE=0` turns it off, `ZANE_INTERLEAVE_REPORT=1` names the
  loops it took and left
- **Where:** `lib/codegen/interleave.ml`, `lib/codegen/emit.ml`
  (`Runtime.Prefetch`, `func`)
- **Design:** [`design/interleaving.md`](design/interleaving.md), I9;
  [`experiments/prefetch-reorder`](experiments/prefetch-reorder/README.md),
  rounds 8 and 9
- **Effect:** wall clock, 4 KiB pages, paired runs on one cloud Xeon, best
  of 5: `tree` ×1.11 at 256 KiB, ×5.10 at 32 MiB and ×4.53 at 2 GiB;
  `chains` ×3.27 and ×4.68, plain at 256 KiB; `found`, whose pushes retire
  in order, ×3.43 and ×5.35, plain at 256 KiB; no `tests/perf` program's
  build changes

A counted loop whose every iteration walks a chain, as a tree lookup or a
linked list does, in a search written out where the loop calls it, runs 32
iterations' walks at once: each takes one step, prefetches the node its
next step reads, and gives way to the next, so the 32 chains' misses
overlap. The walk half of each iteration writes only its own locals and
runs out of order; what follows the walk runs in iteration order, or as
each walk ends when it only adds integers into accumulators. A loop runs
interleaved when it has at least 64 iterations and its walks read 512 KiB
of lists or more, or, for one that retires in any order, when its walk is
a constant 32 trips or more. A loop whose iterations depend on each other
through what the walks read, that writes outside the iteration before its
walk, calls anything, or can leave or return is left as it is.

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
values. The runtime's own allocators inline only the frontier's bump; taking
a new stretch, and allocating a block past a chunk's size, stay out of
line, so the common path is short.

### A scope's first blocks in its own frame

- **Builds:** every build
- **Where:** `runtime/arena.c`, `runtime/list.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** `tests/perf` `scopes` 29% fewer estimated cycles optimized,
  33% plain, 26% tiered

While a scope is the innermost one, its blocks go into its own frame,
stretched past its slots 4 KiB at a time up to 64 KiB, before any chunk.
The drain gives them back with the frame, so a scope whose blocks fit there
maps no chunk and drains inline.

### The runtime compiled lean

- **Builds:** every build
- **Where:** `lib/codegen/build.ml`, `runtime/zane_internal.h`
- **Design:** [`design/lowering.md`](design/lowering.md) §7
- **Effect:** `tests/perf` `returns` 10% fewer estimated cycles optimized,
  `texts` 6%, under a hardened clang; with the runtime inlined,
  `texts` 3% more

The runtime is compiled without clearing the registers a function used
before it returns, without stack protection, the C library's checked
functions or wrapping signed arithmetic, without frame pointers except on
Apple's targets, and reading its threads' variables at their offsets in the
executable, whatever the C compiler adds by default.

### List growth in place

- **Builds:** every build
- **Where:** `runtime/list.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** `listgrowth` in under half its former time, within a few
  percent of C's `realloc`

A list's block doubles from its first block (four elements' bytes, kept
between 32 and 128), in place when it is last at the frontier, stretching
its scope's frame for it up to 1 MiB. Past 1 MiB it moves once into a
reservation 64 times its size, and each later doubling commits more of it
instead of moving the elements.

### Every overwrite in place

- **Builds:** every build
- **Where:** `runtime/value.c`, `lib/codegen/walks.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Every
  overwrite is in place"
- **Effect:** not measured

An overwrite writes the replacement into the occupant's existing blocks,
recursively, instead of freeing them and allocating new ones.

### An outgrown span's pages given back as it moves

- **Builds:** every build
- **Where:** `runtime/list.c` (`zane_list_move_out`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** entities' and concscan's peak memory 94 MB instead of 158 MB,
  level with C

A list that outgrows its reservation copies its elements to the new span a
chunk at a time and gives each copied chunk's pages back to the system,
all but the first page, which holds the mapping's header. So a list never
holds both copies of its elements for long.

### Large lists' reservations kept warm

- **Builds:** every build
- **Where:** `runtime/arena.c`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Lists'
  reservations"
- **Effect:** listgrowth takes 0.241 s instead of 0.655 s, with 16 k page
  faults instead of 313 k; allocfree's faults 8 k instead of 78 k

A drained list's oversized span keeps its reservation and pages: a context
keeps up to `ZANE_WARM_SPANS` (16) holding at most `ZANE_WARM_SPAN_BYTES`
(64 MiB), the one kept longest going back first, each until it has sat
unused through `ZANE_COOLING` of its later drains, and gives them back when
its call is over or a reservation fails. The next list to grow past 1 MiB
takes one that holds what it would reserve, so a list built again each
round grows into resident pages. The cap was 2 spans until LangArena's
Maze::BFS (three lists per search) and BWT encode (up to seven per round)
showed every further one faulted in again each call: with the budget,
Maze::BFS takes 13,388 minor faults instead of 53,146, Maze::AStar 18,005
instead of 184,610, and Compress::BWTDecode 9,934 instead of 84,187 (C:
29,477, 512,098 and 18,835).

### A replaced list's span reused

- **Builds:** every build
- **Where:** `runtime/arena.c` (`zane_returned_span`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** LangArena's `repros/field-replace 3000000 40` peaks at 26 MB
  instead of 919 MB, with 6,214 minor faults instead of 234,762

A list's span that an end or an overwrite returns goes onto its size's
stack with its pages resident. A block past 1 MiB first takes such a span
when its reservation holds the addresses a new one would get: one of its
own size, else the smallest on top of its region's stacks above 1 MiB. Growth never read the
stacks before, so a list a field assignment replaced each round stayed
resident, unused, until its region drained.

### Arrivals in the innermost region return at once

- **Builds:** every build; the check is inline in optimized builds, and
  in tier 1 when LLVM can read the runtime's bitcode
- **Where:** `runtime/value.c` (`zane_arrive`), `lib/codegen/emit.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Each scope's
  dynamic region"
- **Effect:** not measured on its own

A value arriving in the innermost region moves nothing, so `zane_arrive`
returns at once there, the common case, and only another region's place
goes out of line. For a place in one of that region's chunks, such as a
list's element, the check is the place's chunk-map entry against the open
region, which an optimized build inlines.

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
