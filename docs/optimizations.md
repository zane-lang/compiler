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

A worker is no expansion, since it takes a function value: `work` and
`register` become a `while` loop whose condition calls the step. A step
written where the worker runs is a lifted lambda whose address LLVM sees,
so an optimized build inlines it and makes one loop with no call through
the function value (`tests/objects`, the `workers` perf program).

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

### Conversions lent from an owner's member

- **Builds:** every build
- **Where:** `lib/cgt/lower_calls.ml` (`owner_path`)
- **Design:** [`design/lowering.md`](design/lowering.md) L11, "Lent
  conversions"
- **Effect:** `tests/perf` `lent`, a byte loop through a wrapper's
  conversion of a reference-type document's member, takes 10 times the
  estimated cycles optimized, and 35 times plain, with the member copied

A lent conversion's place may also be a member of an owner, a
reference-type instance a local holds, as `parse(this.text)` reads
`this.text`. The call it lends to writes nothing through its parameters
and its other arguments read nothing that could reach the owner, so the
member is read where it is; a place a spawned call may write back is
still copied.

### A held local moved at its last read

- **Builds:** every build
- **Where:** `lib/cgt/regions.ml` (`assigned_moves`, `taken_params`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9
- **Effect:** `tests/perf` `phrases`, a string extended and assigned back
  each round, takes 14% more estimated cycles plain and 7% more optimized
  with the copy

A held local whose last read in its scope copies it into another place,
as `current = combined` does, is moved there instead, as a return moves
it: nothing reads the slot again before the scope drains it. Only
straight-line code, `if` bodies and expansions are looked into.

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

- **Builds:** every program's build, and a library's built for one program
  (`--program-write-backs`), as `zane` builds a dependency from source
- **Where:** `lib/cgt/program.ml` (`written_back`, `write_backs`),
  `lib/cgt/type_layout.ml` (`owned_place`, `snapshots`, `program_overlaps`),
  `lib/cgt/write_backs.ml`
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Snapshots"
- **Effect:** lets LLVM forward stores to loads, keep fields in registers
  across loops and vectorize them, which no atomic load allows. Summing a
  `List<Int>` in a program that spawns a call writing nothing back: 6.00 G
  instructions as snapshots, 3.50 G as plain loads, what the program takes
  without its spawn. A library's automaton reading a `List<I32>` table in
  its own loop, as core's `regex` does (tests/perf `automaton`): 1.37 G
  instructions in an object built for any program, 0.24 G in one built for
  the program

A value read through an owner may race a spawned write-back, the only write
another thread makes to a place this thread can read. A write-back comes
only from a spawned `mut` call whose subject is reached through an owner, so
the places it can write are known from the source of every package in the
build, each as the type of its innermost owner and the members, cases and
elements down from it. A read takes a snapshot only when its place overlaps
one of them; every other such read is a plain load, as is every read in a
program that spawns nothing. Writing back `tally.n` leaves every other
`Int` read plain. A library's object takes the places of the one program
it is built for from the file that program's build writes, and keeps every
snapshot when it is built for none.

### Cross-package bodies for the optimizer

- **Builds:** every build
- **Where:** `lib/cgt/program.ml` (`import_bodies`), `lib/driver/driver.ml`
- **Design:** [`design/optimization.md`](design/optimization.md) O10,
  [`design/separate-compilation.md`](design/separate-compilation.md) C12
- **Effect:** [`experiments/cross-package-optimization/README.md`](experiments/cross-package-optimization/README.md):
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
program that spawns or makes a worker pool, and in a library, threads share
each table, whose
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

- **Builds:** every build; `ZANE_FRAME_REFS=0` turns it off, and with it
  the two entries below
- **Where:** `lib/cgt/ref32.ml`, `lib/codegen/list_handle.ml`,
  `lib/cgt/build.ml` (`stored_ref`), `runtime/region.c`, `runtime/zane.h`
- **Design:** [`experiments/goose-comparison/FINDINGS.md`](experiments/goose-comparison/FINDINGS.md),
  "The new model"; [`README.md`](experiments/goose-comparison/README.md),
  "Frame references" and "Room counted in elements"
- **Effect:** ntree at 10 peaks at 23.4 MB instead of 34.1 MB, and the
  edges test at 63.6 MB instead of 94.3 MB, both faster; listgrowth's push
  takes one instruction more

A stored `&T` is its owner's signed 32-bit distance in bytes from the
start of the program's image, a symbol the target's linker defines there:
`__ehdr_start` for ELF, `_mh_execute_header` for Mach-O, `__ImageBase` for
PE. Every context's frames come from the 2 GiB below the image, or from
512 MiB above it within 2 GiB when the program is loaded too low for that
(as under Valgrind, and on macOS, which keeps the low 4 GiB unmapped), and
globals are in it, so every reference fits, and reading one is one address computation. A list's handle is 16 bytes: its
items pointer, then a 32-bit count and a 32-bit room counted in elements,
so a list holds up to 2^32 − 1 elements. A push adds to the count at 32
bits, so LLVM folds the element's address into its store.

### Boxes in 32 bits

- **Builds:** every build; `ZANE_IMAGE_BOXES=0` turns it off.
  `ZANE_CHUNK_BOXES=1` numbers boxes by chunk instead, which is the default
  for a Mach-O target, where `ZANE_CHUNK_BOXES=0` turns image boxes back on
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
hold 8-byte pointers. A box's payload past 1 MiB takes whole chunks of
its own from the window too, never a list's span, so it fits as well.

A build for macOS numbers boxes by chunk, since arm64 macOS leaves no room
for the window: the system loads the image at 4 GiB and keeps the addresses
below it unmapped, and the dyld shared cache, with the range the system
reserves after it, fills the addresses from 6 GiB to 63 GiB
([#418](https://github.com/zane-lang/compiler/issues/418)). A boxed member
is then its MiB's number, which the runtime gives each MiB of a context's
frames and of a chunk, and its offset in that MiB in 8-byte units, with
chunks anywhere.

### A sum of nothing or one box is one word

- **Builds:** every build with boxes in 32 bits (above, so
  `ZANE_FRAME_REFS=0` or `ZANE_IMAGE_BOXES=0` without `ZANE_CHUNK_BOXES=1`
  turns it off too); `ZANE_NICHE_SUMS=0` turns it off
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
constant, a record, a box, or a list made and pushed in one expansion,
pushed by a loop when it is 16 or more of one element built of scalars:
core's regex package, whose `finish` makes six 256-entry byte tables,
compiles optimized in 4.3 s rather than 50 s, its object 393 KB rather
than 1.35 MB. Exact math folds; approximate math and `F32` `fma` stay calls, since their
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

### Small-array loops strip-mined

- **Builds:** every build; only an optimized build's passes gain from it
- **Where:** `lib/optimize/strip.ml`
- **Design:** the comment at the top of `strip.ml`
- **Effect:** `tests/perf` `lanes`, eight hash lanes in an `Array<Int, 8>`
  updated at `bitAnd(i - 1, 7) + 1`, takes 6% more estimated cycles
  optimized without it; `wrapped`, `digest`'s hash over a core-style
  `Int`, 3.3 times the estimated cycles when its step is not read through
  the struct's `+`

A counted loop that steps a counter by one (directly, or through an
operator such as core's `Int +`, which lowers to an expansion assigning
its result) and indexes an array of 2 to 16
elements, a power of two, through `bitAnd` is cut into runs of that many
copies of its body, each run starting at a multiple of the size, so each
copy's index is a constant and the array's elements become registers. The
remaining iterations run as before.

### String literals in locals bound, not held

- **Builds:** every build
- **Where:** `lib/optimize/literal_locals.ml`
- **Design:** the comment at the top of `literal_locals.ml`
- **Effect:** `tests/perf` `glyphs`, a shade picked from a local string
  literal per call, takes 4.3 times the estimated cycles optimized with
  the local held

A local whose value folds to a string literal, never assigned, moved or
lent by address, is bound to the constant rather than held in its scope's
frame, and a scope it leaves empty is dropped, so the function places,
zeroes and drains no frame on each call.

## Code generation (stage 6, `lib/codegen/`)

### Constant local arrays made constant globals

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/const_arrays.ml`
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `tables`, a table of 16 squares written as an
  `Array` literal in the function that reads it, takes 2.7 times the
  estimated cycles with the literal's stores made on each call

A stack slot whose every write is a constant, the same at each offset each
time, and that is otherwise only loaded or copied from, is replaced by a
constant global holding those bytes, and its stores go.

### A recursion's base case made at its self-calls

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/leaf_peel.ml`, `lib/codegen/leaf_peel_stubs.cpp`
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `peeled`, binary trees built by recursion,
  takes 17% more estimated cycles without it

For a function of at most 200 instructions that calls itself, whose base
case is a branch on a compare of its arguments, each self-call tests the
condition on its own arguments and runs the base case inline, so the
leaves take no call. A function a memo table answers is left alone: its
table already answers the calls that repeat (`tests/perf` `leaves`). So is
one whose frame allocates more than 4 KiB of machine stack: the inlined
leaf brings its own copy of those allocations, so each level of the
recursion would take twice the stack (`tests/memory-probes` `bigbox`, a
1.1 MB value five levels deep, which then overflows macOS's 8 MiB).

### Small leaves a loop calls inlined

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/loop_inline.ml`
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `neighbors`, a maze carver's eight-neighbour
  count called from three loops, takes 11% more estimated cycles with the
  calls

A call made in a cycle of its function's blocks to a function of the
program with no cycle of its own, whose calls are only to LLVM's
intrinsics or to functions that do not return, of at most 128
instructions, is inlined there, which LLVM's own cost model, blind to
where a call is, leaves out of line.

### Frame slots kept in registers

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/frame_shadow.ml`
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `tape`, a tape machine whose loop may grow its
  tape by a rare push, takes 1.5% more estimated cycles without it;
  `refills`, an arithmetic coder's bit writer, 2.7% more optimized and
  13% more tiered when every slot is filled again after every call;
  `subjects`, a tape machine held in a struct local, 9.1% more optimized,
  `workers` 6.4% more optimized and 8.4% more tiered, `bits` 21% and
  `paths` 11% more optimized, with every store written through and a
  frame its scope enters inline left in memory

Each slot of a placed frame that is loaded and stored whole, as one
scalar type, gets a copy in an alloca, filled where the frame is placed;
loads and stores use the copy, which SROA makes a register. A copy is
written back to its slot just before something may read it there, and
only when it was stored since the two last agreed: before a call given an
address in the frame, any call once a runtime call has kept one (a drain
reads the slots `zane_hold` lists), and a wider load that holds the slot.
A copy stored to before a loop but not on its way round, as a list pushed
to before a loop that calls a function given the frame on every pass, is
written back once on the way in. A call past the frame's last use, where
it may have been drained, writes nothing back. Where an address in the
frame is stored as a value, or kept by a callee other than the runtime's
`zane_hold`, `zane_scope_drain` and list growth (a spawned call, whose
thread may read the frame at any time), every store is written through to
the slot as well. A wider access may hold the whole slot: a load of it
reads the frame, and a store of it fills the copy again, which is how a
list's count keeps its copy in a struct that a list was copied into, its
count and room stored as one pair.

After a call, only the copies it may have written are filled again: those
a `memset`, `memcpy` or `memmove` of a constant length covers (none when it
writes outside a frame whose address went nowhere else), the list header
the runtime's growth writes, and every copy after any other call. A copy
that every path from the call finds stale where it is next loaded is
filled there instead, and one stale on some paths only is filled at the
ends of the blocks it is surely stale out of, on the way to that load, so
a path that loads it no more never reads it.

A frame its scope enters inline is still a frame: the record's skip, a
phi between the frame and a scope it encloses, is stored only as a value,
as the frame is, and the check of the room past the frame only compares
its address. A frame whose address escapes any other way is left alone. A
frame placed on two paths, as LLVM leaves a scope's entry when it threads
the fast and slow paths apart, is the phi that joins them, along with a
phi beside it that carries a slot's address on each path; the paths'
frames are written through so that the phi reads what they stored, and
the reread of the runtime's innermost scope merged with it is not
followed.

### Index checks merged

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/merged_checks.ml`, `lib/codegen/arm_checks.ml`,
  `lib/codegen/range_checks.ml`
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"; [`spec-divergences.md`](spec-divergences.md) §10
- **Effect:** `tests/perf` `pairs` (one index into two parallel lists)
  takes 4.3% more estimated cycles optimized without the merge, `merges`
  (a merge step storing to `work[k]` in either arm) 11% more tiered
  without the check raised above the branch, `windows` (four
  neighbouring elements read at once) 2.7% more tiered without the run's
  checks joined, and `digest` (a strip-mined hash of eight lanes) 71% more
  optimized with its copies' exit tests left in; `wrapped` (that hash
  inlined into a caller, as LangArena's port has it) 2.9 times as many
  when the loop's guard is not read through its preheader, when its stop
  before the latch is not read, or when a test leading to a block that
  writes state back before stopping is kept

A failed check stops the program after flushing its output, so where a
later check of the same index follows an earlier one on a straight path
with no call that could write output between, the earlier one takes the
smaller of the two bounds and the later one goes. A check both arms of a
branch begin with is made once above it, after which LLVM makes the arms'
stores one store of a select. The checks of `x`, `x + 1`, ... `x + k` on
one path become one check of the lowest and one of the highest. In a
strip-mined loop, an index check LLVM has made the exit test
`b == (n + k) >> s`, against a counter that starts at 0, steps by one,
leaves at `b + 1 == (n + j) >> s` with `j <= k` (tested in the latch or
in the one block leading to it) and is entered only when that end is at
least one (a guard on the edge into the loop, or above a preheader), can
never hold and is removed, wherever it would lead.

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
payload, where nothing marks for LLVM that the load is safe to make before the
tag is tested. Left beside the tag's load, the room is read either way, and a
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
  of `repeats` 25% ([`experiments/unroll-thresholds`](experiments/unroll-thresholds/README.md))

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
  `lib/llvm/config/discover.ml`, `lib/codegen/loop_copies.ml`
  (`versioned`), `lib/codegen/emit_runtime.ml` (`count_field`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "The passes"
- **Effect:** the particle simulation of
  [zane-lang/compiler#292](https://github.com/zane-lang/compiler/issues/292):
  12.1G → 8.89G instructions under Valgrind, against 8.88G for the same
  program in C at `-O2`. Langbench: `fannkuch` 1.6% more instructions,
  `nbody` 0.3% and `trialdiv` 0.2% fewer, the rest within 0.1%;
  `tests/perf` `flips`, tier 1 5% fewer estimated cycles. Leaving
  searches whole: LangArena's Sort::Quick 11.58G → 8.37G instructions
  (C: 4.96G), every other LangArena test and `tests/perf` program within
  0.1%

LLVM's inductive range check elimination splits a loop that checks its
element indices into a main loop it has proved needs no check and the few
iterations around it that might fail one, which still check and stop the
program as the spec says. It runs inside `-O2` once each loop is rotated.
An optimized build emits each loop it could help twice, with branch
weights saying the long copy goes round 1,000 times and the short one 4,
and IRCE splits the long copy and not the short one, since the split costs
a short loop more than it saves. A loop that calls back into its own
function is left as it is: the call costs far more than the check. A loop
that can leave before its count runs out, holds no loop and reads an
element at an index it steps by a constant itself, apart from its counter,
is a search whose count is a
ceiling, so it is weighted as going round 4 times and left whole: a
quicksort's partition scans stop after an element or two, and IRCE's split
cost each one about 25 instructions of setup. So is a loop whose counter
is read nowhere but by its own step and that reads or writes an element, a
`to` over a ceiling standing for a `while`, whose index a method it calls
moves (`tests/perf` `cursor`, a whitespace skip, takes 10% more estimated
cycles optimized split). Any other loop
emitted once has no weights, and IRCE splits it on LLVM's guess; its main
loop stays a loop rather than a `memmove` call (below, "Element copy loops
kept as loops"; [`design/lowering.md`](design/lowering.md) §9, "The
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
- **Where:** `lib/codegen/loop_copies.ml` (`unrolled`),
  `lib/codegen/emit_frames.ml` (`unroll_twice`),
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
layout lowering has computed, and gets none of these. Neither kind claims an
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
  ([`experiments/runtime-attrs/`](experiments/runtime-attrs/README.md))

`zane_out_of_range`, `zane_too_deep` and `zane_main_aborted` are
`noreturn`, `cold` and `nounwind`, so the paths to them are laid out of the way. `zane_text_equal`
only reads memory, so loads before it stay valid after it.
`zane_list_push`, `zane_list_reserve` and `zane_list_room` keep no pointer
to the list's handle (`captures(address)`): a handle in a local slot stays
the function's own across other calls, so LLVM can prove a fresh list is still
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

### Element addresses from a biased base

- **Builds:** every build
- **Where:** `lib/codegen/emit_lists.ml` (`element`)
- **Design:** the comment on `address` in `element`
- **Effect:** `tests/perf` `nodes`, a Huffman decoder over a tree of
  16-byte nodes, takes 2% more estimated cycles plain without it and 8%
  more wall time optimized; LangArena's HuffDecode, Brainfuck::Recursion,
  NeuralNet and Words ran 8% to 12% faster with it

An element's address is `(base - stride) + index * stride`, not
`base + (index - 1) * stride`. The check keeps its own `index - 1`, so an
index loaded from memory (a tree's child, a graph's neighbour) goes
straight into the address, and the bias, loop-invariant, folds into the
load's displacement.

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
states to LLVM with `llvm.assume` that any slot of its frame may be read and
that the frame is 16-byte aligned, so a loop reads a list kept in the
frame once.

### Drains that look for spawned calls only where a call is spawned

- **Builds:** every build
- **Where:** `lib/codegen/frames.ml` (`spawns`), `lib/codegen/emit_frames.ml`
  (`drain_scope`)
- **Design:** [`design/lowering.md`](design/lowering.md) §9, "Entry and
  drain are inline"
- **Effect:** `tests/perf` instructions: `scopes` 0.79% fewer optimized,
  0.41% plain; `glyphs` 2.05% fewer plain, 1.86% tiered; none more than
  0.03% more.
  Estimated cycles of `phrases` tiered rose 4.35% from simulated branch
  mispredictions alone; its wall time was unchanged (medians of 150
  alternating runs, -1.6% and +1.1%)

A drain reads its scope's list of spawned calls only when the scope spawns
one. A spawned call waits on the scope its frame is placed in, which lowering
names, so a scope that places none has nothing to wait for, and its inline
drain tests only for dynamic chunks, checks and handles.

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
whole-program analysis detects in an optimized build. A call into C could
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

### Scalars' alias tags by size

- **Builds:** every build
- **Where:** `lib/codegen/emit_runtime.ml` (`sized_tag`)
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `flags`, a `Bool` flag stored per element
  while an `Int` field is read, takes 24% more estimated cycles optimized
  without it

A scalar's type-based alias tag is a child of the scalar tag by its size:
one byte, four and eight. A place is read back only as a type of the size
it was written as, so a one-byte store leaves the wider scalars read
around it in registers.

### A loop's pushes counted in a register

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/emit.ml` (`Stat.Repeat`, `kept`)
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `pushes`, a decode loop pushing one element per
  step, takes 6.6% more estimated cycles without it

A loop whose pushes were given their room before it, of a count not
known to be 64 or fewer, reads the list's block once before the loop and
keeps its count in a local that each push steps and stores back, so a push
loads nothing. LICM cannot promote the count itself: the loop's checks make
each push conditional.

### Small constant loops unrolled whole

- **Builds:** every build; only an optimized build's passes act on it
- **Where:** `lib/codegen/emit_runtime.ml` (`unrolled_whole`)
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `bits`, a bit decoder's loop of eight with a
  leaf test in it, takes 29% more estimated cycles optimized without it

A `repeat` of a constant count from 2 to 8 has its back edge marked to be
unrolled whole (`llvm.loop.unroll.full`), which LLVM's own threshold does
not do for a body with a branch in it.

### A loop that calls a single-caller function emitted once

- **Builds:** optimized only; a tiered build versions every loop as before
- **Where:** `lib/codegen/loop_copies.ml` (`single_caller`)
- **Design:** [`design/lowering.md`](design/lowering.md), "After the
  passes"
- **Effect:** `tests/perf` `interp`, an interpreter whose loop calls its
  step function, takes 15% more estimated cycles optimized versioned

A loop that would be versioned for IRCE but calls a function with only one
call site is emitted once, so the callee keeps LLVM's single-caller inline
bonus; two copies would leave a mid-sized callee out of line in both.

### Element copy loops kept as loops

- **Builds:** optimized only, and tier 1
- **Where:** `lib/codegen/passes.ml` (`-disable-loop-idiom-memcpy`)
- **Design:** [`design/lowering.md`](design/lowering.md), "The passes"
- **Effect:** `tests/perf` `rotations`, short rotations of a list's front,
  takes 1.6% more estimated cycles optimized and 11% more tiered with the
  loop made a `memmove` call

LLVM's loop idiom recognition does not turn an element-by-element copy loop
into a `memmove` or `memcpy` call: such loops copy a few elements of a
length known only at run time, which a call into the C library costs more
than it saves.

### Ordered removals moved in 2 KiB pieces

- **Builds:** every build
- **Where:** `lib/codegen/emit_lists.ml` (`remove`), `runtime/list.c`
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
- **Where:** `lib/codegen/emit_frames.ml` (`unlikely`)
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
- **Where:** `lib/codegen/emit_runtime.ml` (`text`)
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
rather than a value of thousands of parts. A value of more than 65,535
parts, which LLVM cannot move as one, is moved a part at a time when it is
read only for its parts, as a match arm reads one field of a large payload,
or built from parts and only stored, as a constructor builds its struct;
each part is as aligned as its offset allows.

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
its scope's frame for it up to 16 KiB. Past 16 KiB it moves once into a
reservation 64 times the chunk its room is doubled to, and each later
doubling commits more of it instead of moving the elements (the next
entry).

### Growing lists take a growable span early

- **Builds:** every build
- **Where:** `runtime/list.c` (`zane_list_grow`), `runtime/zane_internal.h`
  (`ZANE_LIST_SPAN_FROM`)
- **Design:** the comment on `ZANE_LIST_SPAN_FROM`
- **Effect:** `tests/perf` `spans`, a list of more than a megabyte built
  one push at a time each round, takes 21% more estimated cycles plain and
  59% more tiered with copies at each doubling; `growth` 23% more tiered

A list whose block grows past 16 KiB takes a growable span at once, its
room doubled past a chunk, and grows in place from there rather than being
copied at each doubling to a megabyte. Only its touched pages use memory.

### A moved list's span handed over

- **Builds:** every build
- **Where:** `lib/codegen/walks.ml` (`move`), `runtime/arena.c`
  (`zane_relocate`, `zane_free`)
- **Design:** the comment on `zane_relocate`
- **Effect:** `tests/perf` `handover`, a decoder whose output of more than
  a megabyte is moved into its state each step, takes 57% more estimated
  cycles optimized, 23% more tiered and 8% more plain with the block
  copied, and 45% more wall time optimized

A list's or string's block past a chunk that a move takes into another
region of the same context is a growable span, the one block of its
mapping: the mapping leaves the old region for the new one, its chunks are
the new region's in the chunk map, and no byte is copied. When the new
region returns it, it goes to its context's kept spans, where the next
list past a chunk takes it with its pages resident. A smaller block is
still copied, inline.

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
uses. Under Valgrind, which hands a fault handler stale registers, the
whole range is committed when it is reserved, so no access faults and runs
again (`zane_reserve`).

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
