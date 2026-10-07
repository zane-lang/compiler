# Lowering: designing the CGT

> **Status: built through §8 step 11.** Stage 4 — lowering the TST to the
> code-generation tree — and the codegen that reads it follow this design, and
> every step §8 lists is built and tested. Each decision is numbered
> (**L1**…). §8 lists the order they were built in, and §9 the questions still
> open.

The **CGT** is the one input codegen reads ([`stages.md`](stages.md)). The TST
says what a program means, in the language's own terms: calls to overloads,
concepts, block arguments, handlers, owners and references. The CGT says what the
machine does: functions over primitive storage, with every allocation, copy,
move, reference and death written out. Lowering is the only stage that turns one
into the other, so codegen never reads a type declaration, never resolves a
name, and never asks what a `&` means.

---

## 1. The target is LLVM IR

**L1. Codegen emits LLVM IR, and the CGT is shaped for it.** A CGT function
becomes one LLVM function, a CGT type becomes one LLVM type, and a CGT
statement becomes a run of instructions over basic blocks. Codegen does no
analysis of its own: whatever LLVM needs that the language does not say
(sizes, alignments, which slot a value lives in, when it dies) is decided by
lowering and is already in the tree.

**L2. Codegen builds the module through LLVM's OCaml bindings.** The opam
`llvm` package wraps LLVM's C API, so codegen makes types, functions and
instructions as values in the compiler's own process, and LLVM checks each
one as it is made: a wrong operand type fails at the line that built it, not
in a tool that reads a file later. The same bindings verify the module, run
LLVM's own passes, and write the object file through the target machine, so
no text is written and read back. Linking that object with the runtime (§6)
is the one step left to a system linker, which `clang` drives.

The bindings are LLVM's own, from `llvm/bindings/ocaml` in llvm-project,
which opam builds from each LLVM release as its `llvm` package. They are
tied to that release, and the compiler uses LLVM 19, the newest opam
packages. `dev/setup/bootstrap-toolchain` pins it; devbox provides LLVM 19
with its `llvm-config`, headers and shared library in development and CI.

The module's text is LLVM's to print and changes between releases, so the
tests read the CGT and what a built program writes instead (§7).

**L3. The CGT is a tree, not a control-flow graph.** It keeps structured
control flow — a block, a branch, a counted loop — and names every exit
explicitly (§4). Codegen turns that into basic blocks, which is mechanical.
The tree is what an optimization pass reads and writes (stage 5), and a tree
is where rewrites such as inlining and constant folding are easiest to state.
SSA form is LLVM's job: every CGT local is a stack slot, and `mem2reg` promotes
the ones that can live in registers.

---

## 2. What the CGT holds

**L4. Only instances.** A generic verb reaches the CGT as its instances, one
function each, named by its declaration and its arguments. The TST already
checks one body per instantiation ([`semantics.md`](semantics.md) D12), so
lowering takes those bodies as they are. No type parameter, no `Ty.Param` and
no concept survives lowering.

**L5. Concepts become primitives, and every type has a layout.** A CGT type is
one of:

- a scalar: `i1`, `i8`, `i32`, `i64`, `f64`;
- a struct of CGT types, in declaration order ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §3.3); a
  reference type's instance carries nothing else;
- a sum: a tag and the widest case's bytes, aligned for every case;
- a pointer: a reference, the address of the settled owner it names
  ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §4.1, and §9 below for the representation);
- a fixed array: `@primitives$Array<T, n>`, and `@primitives$ArrayRef<T, n>`
  which has its layout ([`generics.md`](https://github.com/zane-lang/spec/blob/911d749/spec/generics.md) §8.4), is `n` elements of `T` inline, one
  after another at `T`'s stride (its size rounded up to its alignment), so it
  is statically sized and sits in a slot like a struct. Positions count from
  1 ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §5.1): element `i` is at
  byte offset `(i - 1) × stride`. What an index outside `1..n` does is not yet
  specified (`control-flow.md` §5.2), so lowering emits one runtime check for it and leaves its
  outcome to §9;
- a handle: the fixed-size part of a `List`, a `String` or a boxed member
  ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.6), whose payload lives in the dynamic region.

`Unit` has no storage, and a verb that returns it returns nothing. A value
struct of one member has that member's layout, so a struct around one
`@primitives$I64` is an `i64`, and an empty one has none. A distinct
type is its underlying type. A concept literal (`Integer_lit`, `Text_lit`) is
already gone, because the TST put an implicit constructor around every one
([`semantics.md`](semantics.md) D9); lowering turns `@primitives$I64(3)` into the constant `i64 3`.

Which members are boxed is lowering's decision too: every member on a cycle
of owning edges, and none other to start with ([`adt.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/adt.md) §4).

**L6. Calls name one function and pass places.** A CGT call names the
function it calls, so overload resolution, method lookup and the operator and
flip forms are gone. What each argument passes follows its parameter's mode
([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.9):

| Parameter | Passed as |
|---|---|
| value type (a borrow) | the address of the caller's slot, or the value itself when it is a scalar |
| `T`, a reference type (a borrow) | the address of the caller's slot, which keeps the owner |
| `^T` (a take) | the moved value itself, which the callee holds in its body's arena, so the body's drain ends it unless the body moves it on ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.5) |
| `&T` (a reference) | the address of the settled owner it names |
| `this` | the address of the subject's place, taken once at the call |

A call site that mints a reference for an `&T` parameter, or moves an owner
into a `^T` one, does so with an explicit CGT operation (§3), not inside the
call.

**L7. A result is written into a destination the caller names.** Every verb
that returns something other than `Unit` or a scalar takes a pointer to the
slot its result goes in. That is the spec's own model: a move into a return
slot is initialization in place ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.7), and a fresh value
is built directly where it will live ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §2.3). A `let` of a call passes the new
local's slot; a field or element store passes the field's.

---

## 3. Memory is explicit

Every death point is known from the program text ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/lifetimes.md)
§2.1), so lowering writes each one down. Nothing in codegen or the runtime
tracks what is live.

**L8. Each scope is an arena, entered and drained by name.** A CGT block
that owns storage opens its scope's arena on entry and drains it on every way
out: falling off the end, `return`, `abort`, or an exit (§4). Draining first
waits for the scope's spawned work (the water tower, [`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md)
§4.1). Then it returns the blocks its values still own, and releases the
scope's fixed-size and dynamic chunks together ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §3.2).
There is no other per-object pass at a drain; an object that dies earlier —
overwritten, or its container gone — is destroyed there, by its own
`destroy` (L9). Lowering
may fold nested scopes into one arena when nothing observes the difference
([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1); the first version gives every block that
declares a local its own.

**L9. Storage operations are CGT nodes, each a call into the runtime or a few
instructions.** The set lowering writes, with the sections of [`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
that define each:

- `slot` — a fixed-size slot in a scope's arena;
- `copy` — a value-type copy, recursive through its boxed payloads (§2.3);
- `move` — a roaming owner's inline bytes copied into a destination of the
  same type, its source spent; its dynamic blocks stay where they are unless
  the move is an escape, which relocates them first (§3.5);
- `overwrite` — a replacement written in place at the occupant's address,
  each boxed member's block kept and written into, recursively, and the rest
  of the occupant's blocks returned (§2.2, §3.6);
- `destroy` — an owner's or a value's death, returning its dynamic blocks
  (§3.2).

A reference needs no operation of its own: minting one takes the address of
a settled place, which the semantic pass alone may admit (§2.8), and a
settled owner never moves, so the address holds until its scope drains
(§4.2).

Where the TST has a `Let`, an `Assign` or an owning argument, lowering picks
from this list using what the move analysis already knows: whether the source
is a place or a fresh result, whether the destination is fresh or already
holds a value, and whether the type is a value or a reference.

**L10. A place is an address inside a call, and a reference is one when
stored.** A field read, an element read or a `this` is an LLVM pointer for as
long as one expression needs it, and `&` storage — a local, a field, an
element, a parameter — keeps that pointer. So reading through a reference is
one load, which is what the spec says it costs.

---

## 4. Control flow is explicit

**L11. A block-taking verb is expanded at its call site.** A verb with a
`@concepts$Block` parameter has no function in the CGT. Each call to it is
replaced by its body, with the block argument spliced in where the body uses
the parameter, and so is every call that body passes the block on to
([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §2.3). `@controlflow$branch` becomes a CGT `if`,
`@controlflow$repeat` a counted loop. A `return` or `abort` in a spliced block
still leaves the function it was written in, because after expansion that is
the function it is in.

The same holds for a verb with any other concept parameter, such as an
`implicit Int(value @concepts$Int)`: a literal has no storage, so the verb is
expanded and the literal is embedded where the body uses the parameter. In an
expanded body the subject names the caller's own place, so a `mut` method
such as `to` advances the caller's counter; every other argument is stored in
a new slot first, in the order it was written. A `return` in the body itself
stores the call's result and leaves the expansion.

**L12. A verb has up to three outcomes, and a call checks for them.** A
function returns a small outcome tag when it can end in more than one way:

- **done** — the primary result is in its destination;
- **aborted** — the abort value is in the abort slot the caller passed;
- **exit** — an `exitFromCall` in its body: its caller's invocation ends too
  ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §4.2).

A verb that can only finish returns nothing, which is the common case, and its
calls check nothing. A call with a `?` handler branches on **aborted** into the
handler; `resolve` writes the call's destination and jumps past it. A call
that may **exit** is followed by a return of `Unit` from the caller, after the
caller's scopes are drained.

**L13. `match` is a switch on a tag.** Each arm is a CGT block; a binder is
the address of the case's payload. A `match` is abort-transparent
([`error-handling.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/error-handling.md) §3.5): an arm's aborted outcome
reaches the `match`'s own handler exactly as a call's does. A case read with
its handler is a one-arm `match` whose other cases run the handler.

**L14. A lambda is a top-level function.** A lambda captures nothing
([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §5.2), so it is lifted out as-is, and its value
is the function's address. A call through a function value is an indirect
call with the same outcome convention, read from the value's type: the
caller knows no body, so the type alone says how the call can end and how
each argument is passed. A lambda that does not declare `mut` may be held by
a `mut` function type
([`functions.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/functions.md)
§7.2), so a function value's subject is always passed by address, as a `mut`
subject is (L6), and one function serves both types. A package
lambda-variable is its lambda, and each lambda is lifted once, however many
times it is read. A lambda's body does not exit
([`control-flow.md`](https://github.com/zane-lang/spec/blob/b1fcaba/spec/control-flow.md)
§4.2), so a call through a function value finishes or aborts, and a spawned
one carries the function's address in its frame, ahead of its arguments.

---

## 5. Programs and packages

**L15. One LLVM module per program.** Lowering reads every package the TST
holds and writes one module: every instance, every non-generic verb, every
lifted lambda. A package does not reach codegen as a unit of its own.
[`separate-compilation.md`](separate-compilation.md) designs one object per
package, which a library's prebuilt release needs.

**L16. Constants live in the program's scope.** A package constant is
evaluated once, in dependency order, into the program's own scope, before
`main` runs. A program's `main` becomes a function the runtime's C `main`
calls after setting itself up and before draining that scope.

Each constant has a function of its own, named by the constant, and two
variables: its value and how far its making has got. The first call makes
the value in a scope of its own, stores it, and moves the blocks it owns into
the program's region; every call returns the value's address, and a read of
the constant is a read through it. When a program has constants, its entry
is a function that calls each one's, the packages a package depends on
first, and then `main`. A constant that reads another calls that one's
function first, so dependency order holds whatever order they are declared
in, and a constant that reads itself, through any chain, stops the program.
A context that finds another making a constant waits for it.

A function value (a lambda-variable) is its lambda (L14) and has none of
this. A library's constants are made by whichever program links it: a
library or a stamped dependency defines a constant's function and variables
in every object that reads it, shared as a generic instance is
([`separate-compilation.md`](separate-compilation.md) C4).

---

## 6. The runtime is a C library

**L17. The runtime is written in C and linked with every program.** It owns
the chunk directory, the scope arenas and their size stacks, the thread pool,
and the few primitives a program cannot state in the
language: printing, `List` growth, `String` storage. Its interface is a small
set of C functions that CGT storage operations (L9) and intrinsic calls lower
to, so a change to how an arena works changes the runtime and nothing in the
compiler. It lives in `runtime/`, is built by `clang`, which already links
every program, and is tested in C on its own.

C because it adds no toolchain beside the LLVM the compiler already uses, and
because an arena is exactly the kind of code C states without ceremony.

---

## 7. How it is built, and how to look at it

Lowering lives in `lib/cgt/`, beside `lib/tst/`: `nodes.ml` for the tree,
`lower.ml` for the TST → CGT walk over a verb's body, `program.ml` for a
whole program built with it, and `to_tree_graph.ml` to render it. Codegen
lives in `lib/codegen/`: `emit.ml` builds the module through the bindings,
and `build.ml` writes the object file and links it with the runtime. The
runtime is written as eight parts in `runtime/` (`main.c`, `arena.c`,
`block.c` and so on), with `zane.h` as the ABI that emitted code calls and
`zane_internal.h` as what the parts share. `runtime/dune` joins the parts in
a fixed order into one generated `zane.c` and embeds it, with both headers,
into the compiler as strings, so a build needs nothing beside the compiler
and a C compiler (`clang`, or `ZANE_CC`).

Lowering starts at the root package's `main` and lowers each verb the first
time a call reaches it, so a program's unused declarations never need to
lower. Whatever it cannot handle yet it refuses with a diagnostic at that
node, never by lowering it wrongly.

Lowering does not handle these yet, and refuses each where it is written:

- a control-flow intrinsic, such as `@controlflow$branch`, used as a value
  rather than as a statement;
- an operator that takes a block or a literal, which would be written out
  where it is called (L11) as a verb that takes one is;
- a store into the result of a spawned call that returns `Unit`, which has no
  storage.

Each has a reject fixture in `tests/codegen/fixtures/reject/`. Lowering also
refuses one error in the program that semantics cannot see: a literal handed
to a verb's literal parameter that does not fit the primitive the verb builds
from it, which is known only where the verb is written out. Anything else
lowering finds wrong is an invariant an earlier stage broke, and is an
internal error ([`stages.md`](stages.md)).

The binary takes the same `--package` flags as the semantic views:

| Flag | Does |
|---|---|
| `--cgt` | prints the code-generation tree, as stage 5 left it when `--optimize` is given |
| `--ll` | prints the LLVM module |
| `--build OUT` | builds the program into the executable `OUT` |
| `--object OUT` | writes the object file `OUT` of the project's own packages, with no runtime and no link ([`separate-compilation.md`](separate-compilation.md) C3) |
| `--stamp PATH=STAMP` | names the symbols of the package at `PATH` with `STAMP`, as `--package STAMPPATH=DIR` does; a dependency given one arrives as objects of its own, so its verbs are declared rather than lowered (C1, C6, C10) |
| `--import PACKAGE:KEY=PACKAGE` | the package the first imports by `KEY`, each named by its identity (C10) |
| `--link FILE` | links the object `FILE` into the program `--build` makes, as a stamped dependency's objects are (C7) |
| `--target TRIPLE` | compiles `--ll`, `--build` and `--object` for the LLVM target `TRIPLE` instead of the host, and has the C compiler link `--build` for it; LLVM gets the triple's normal form, and the C compiler the triple as written ([`platforms.md`](platforms.md)) |
| `--optimize` | runs stage 5 over the tree ([`optimization.md`](optimization.md)), then LLVM's `-O2` pipeline over the module, generates optimized code, and compiles the runtime with `-O2` |

`zanec --rewrite STAMP INPUT OUTPUT` takes no packages: it writes the
library object `INPUT` to `OUTPUT` with its `!` placeholder turned into
`STAMP`, as fetching does ([`separate-compilation.md`](separate-compilation.md) C9).
`zanec --remap FROM TO INPUT OUTPUT` writes `INPUT` to `OUTPUT` with every
reference to the package version stamped `FROM` moved to the version stamped
`TO`, as remapping does (C11).

`--kind library` refuses `--build`, since a library is not an executable.
With it, lowering starts from every verb each of the project's own packages
declares that is not generic and has a function of its own, and from their
lambda-variables, rather than from `main`, and names them with the `!`
placeholder ([`separate-compilation.md`](separate-compilation.md) C1, C5),
or with their stamp when they have one (C6).

Without `--optimize` no optimization runs anywhere, neither stage 5 nor
LLVM's, which makes the build about three times faster; `zane run` builds that
way and `zane build` does not. A program means the same either way, since the
semantics leave nothing for an optimizer to decide, so `tests/codegen/` builds
each fixture both ways and holds both to one golden file.

`tests/codegen/` lowers and builds each fixture, runs it, and compares the
tree and what the program wrote against golden files. `tests/runtime/` compiles
the runtime with a C program of its own that calls it directly.

---

## 8. The order it is built in

Each step is one PR, ends with programs that run, and keeps every earlier
test passing.

1. **This design**, and `concepts-vs-primitives.md` brought in line with it.
2. **Scalars and calls.** First a program that prints a string literal
   through `@program$console`: the CGT, codegen, the runtime and the test
   that builds and runs it. Then lowering for `Int`,
   `Float` and `Bool` arithmetic, functions, returns, and `branch`/`repeat`
   expanded from `if` and `to` verbs a program declares. A test that builds and runs a
   program. Printing an `Int` goes through a `String`, and waits for a
   conversion from one to the other, which the spec does not name yet.
3. **Values.** Value structs and sums: layout, copies, fields, `match`, and
   enum maps. A `mut` subject is passed by address. A value type that
   contains itself needs a boxed member, which waits for step 7, and a case
   read, which takes a handler, for step 4.
4. **Aborts and exits.** The outcome tag, handlers, `resolve`, `guard`, and
   case reads.
5. **Reference types.** Arenas, hosting and moves. A reference-type local is
   hosted in its block's arena, and a move copies the instance into its new
   host. The runtime checks that scopes drain in order and that none is left
   open, and is tested in C on its own.
6. **Guests.** The anchor pool, `mint`, `resolve`, anchor merges, the
   backpointer (L5), and `float`, all since replaced by step 11. A
   reference-type subject and a swallowed
   argument are passed by address (L6), and a `match` binder is its
   payload's address (L13). The runtime keeps, arrives, vacates, merges and
   floats identities from a per-type layout of where each host's
   backpointer is, and a drain retires the anchors its scope still hosts.
7. **Handles.** `String`, `List`, boxed members, and `destroy` returning
   dynamic blocks. A string's or a list's handle, and a boxed member, own a
   block in the dynamic region of the scope that holds the owner, which is
   returned when the owner dies, at an overwrite or at its scope's drain; a
   value that leaves a scope takes its blocks out first, and a value copied
   whole gets copies of its own. A
   subscript is a place, generic types and verbs lower per instance, and the
   anchors of hosts in a list follow them when its block grows. The runtime
   is tested in C on its own, and stops a program that ends with a block
   still out.
8. **`spawn`.** The thread pool, futures, and the water tower. A spawned
   call's arguments are read where it is written, into a frame in its
   block's arena, and it runs on a thread of the pool in a context of its
   own. A local bound to it waits for it where it is read, and the block
   waits for every call spawned in it before it drains; a result comes home
   with its blocks and its anchors, read or not. A call that can abort or
   exit settles on the spawning thread, and the program's runtime resizes
   the pool. The runtime is tested in C on its own.
9. **Function values.** Lambdas lifted to functions of their own (L14),
   lambda-variables in a body and at package scope, and calls through a
   function value, which may abort or be spawned. Function values are passed,
   returned and stored in members.
10. **The rest of what the TST accepts.** Package constants (L16),
    `@primitives$Array<T, n>` with its literal and checked elements,
    `@primitives$I32`, a number parameter read as its number, field
    constructors called as the verbs they are with their defaults filled in,
    `&` written before a place, a program value such as `@program$console`
    passed as a guest, and spawned calls to an intrinsic or to a verb
    expanded where it is called. After this step lowering refuses no
    program the TST accepts.
11. **Settled and roaming owners.** The memory model of spec
    [#212](https://github.com/zane-lang/spec/pull/212) and
    [#214](https://github.com/zane-lang/spec/pull/214). A reference is the
    settled owner's address, so the anchor pool, the backpointer, forwarders
    and floating are gone, and a reference-type instance is its members
    alone. A `^T` argument is moved into the callee, which holds it in its
    body's arena; a bare reference-type parameter is a borrow, passed by
    address. Every overwrite is made in place, keeping each boxed member's
    block, and a block relocates only when its owner escapes.
    `@primitives$ArrayRef<T, n>` lowers as `Array` does, with `fill` a counted
    loop over its lambda. `@primitives$String` is a value type. The runtime
    is tested in C on its own: an overwrite keeps a boxed member's address,
    and arrival leaves blocks that outlive their destination where they are.

---

## 9. Open questions

- **How many scopes get an arena.** L8 gives every block that declares a local
  its own. For now only a block that holds a reference-type local opens one,
  and a value-type local stays an LLVM stack slot, since nothing tells the
  two placements apart until a value owns dynamic storage, which it does
  only through a boxed member; such a value is held in the arena too.
  Folding arenas is allowed and saves the most in loops; which ones to fold
  is left to measurement.
- **Slots share one chain of chunks.** Scopes nest last-in-first-out, so the
  runtime keeps one chain of 1 MiB chunks for every scope's fixed-size
  region: a scope bumps from where the scope around it stopped, and draining
  it restores that point. A chunk stays mapped once made and is reused by the
  next scope that reaches it, where [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1 unmaps a scope's chunks at its drain. The spec leaves
  arena granularity to the implementation and fixes only that a scope's
  memory is released together, which this does.
- **A reference is an address.** [`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §4.1 stores a
  reference as the `u32` segmented offset of the settled owner it names. The
  runtime addresses everything else with native pointers rather than
  segmented offsets -- slots, handles and blocks alike, as the next item
  says -- so a reference is the owner's 64-bit address too. Minting one is
  taking the place's address, and reading through one is a load. A settled
  owner never moves, and the semantic pass admits a reference only to a
  settled place, so the address holds until the owner's scope drains
  (§4.2). Nothing a program does can tell the two representations apart;
  moving the runtime's addressing to segmented offsets is one change for
  all of them.
- **Every overwrite is in place.** [`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.2 requires
  it of a settled owner: the replacement is written at the occupant's
  address, and each boxed member reached through struct fields and
  `ArrayRef` elements keeps its block, which the incoming payload is written
  into, recursively. The runtime does the same for every overwrite of a value
  that owns blocks -- a roaming owner, a list's element, a variant payload of
  the same case, a value -- since nothing references those and reusing a
  block of the right size is never observable.
- **Each scope's dynamic region.** A scope's blocks are in a region of its
  own, as [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1–3.2 has it: chunks of its own, a bump frontier, and
  a stack of returned blocks per size and alignment, all given back at its
  drain. A list's block doubles from 128 bytes (§3.6): into a returned block
  of that size, in place when it is last at the frontier, or else into new
  bytes. Where the runtime departs from the spec:
  - A block is placed where its value is made, which is the innermost
    scope. When the value arrives in a place -- a slot, an overwritten
    place, a list's element -- its blocks stay where they are if their
    region outlives the place's: the same scope, an enclosing one of the
    same context, or the program's own region. Otherwise the arrival is an
    escape (§3.5), and they move into the region that holds the place
    first. The spec builds a fresh value in its destination directly
    (§2.3); here a value built for an older scope's place is moved there
    once. A region of another context, such as a spawned call's, is taken
    as shorter-lived, so a result coming home always moves its blocks. A
    list's growth goes to the region that holds the list.
  - A value leaving scopes that drain -- a `return`, a `resolve`, an
    `abort`, a `return` from a block argument or an arm -- moves every block
    it owns in them into the scope the exit returns to, before the drain
    (§3.1). Results are returned by value (below), so that scope is the
    caller's innermost, and the value moves again if the caller places it
    further out.
  - The runtime finds a block's region from a map of every chunk it made,
    and a slot's from where each open scope's slots began, rather than from
    a segmented offset (§3.1). A dynamic chunk begins with a cache line of
    its own bookkeeping, and an oversized block's chunks are one mapping.
  - Every block is at least a word, and aligned to one; a list's is aligned
    to a cache line. A chunk a region gives back is kept for the next
    region rather than unmapped.
  - A value that owns a block is held in its scope's arena like an owner,
    and so is a fresh owner or value that nothing keeps, such as a result
    that is dropped or an operand, so the drain returns its blocks. Having
    returned them, a drain finds no block out in its region, and the
    runtime stops a program where it does, since that block's owner is
    somewhere the scope cannot reach.

  Nothing a program does can tell these apart.
- **Each spawned call has a context of its own.** A spawned call runs with
  its own nest of scopes and its own chain of fixed chunks, so a thread bumps
  only its own; a thread that runs one while waiting for it switches to that
  context for the call. The call's result is kept in its frame, with its
  blocks in the first scope of the call's context, until it comes home: at a
  read of the local it is bound to, or at its block's drain. There it is
  copied into a slot the block reserved, and its blocks move into the
  block's region, as any value's do where it arrives from another context.
  The context then goes back to a pool for the next call. The chunk map names
  each chunk's context along with its index or scope.

  A context is its own thread's alone until it spawns. While a call it
  spawned is out, that call can reach its storage: a `mut` subject that owns
  blocks is written where it lives, in the spawner's region. So while any is
  out, the context's scopes and regions change under its lock, and another
  thread always takes that lock for a context it reaches. The spec leaves
  all of this to the implementation.
- **The pool steals work.** Each pool thread keeps a deque of the calls it
  spawned and runs its own newest first; a thread with none left steals
  another's oldest ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §2.4). Calls spawned from the program's
  own thread go to a deque every pool thread steals from. A thread that
  waits for a call no thread has taken yet runs it itself, so a pool of one
  thread never deadlocks on a call that spawns and waits. Each deque has a
  lock of its own rather than being lock-free, which is left to measurement.
  `setThreads` resizes the pool while it runs: more threads start at once,
  and a thread over the count leaves when it next finds no work, its deque
  kept for the next thread to start. The pool keeps at most 4095 threads.
- **A write through an owner from spawned work.** A spawned `mut` call whose
  subject is reached through an owner -- a member of a reference-type
  instance, of what a reference names, or an element of a list -- is the one
  way spawned work writes where another thread may read at the same time
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §4.2–§4.4). Such a call works on a copy of its subject in
  its frame, deep for a value that owns blocks, and writes it back when it
  returns: what the copy owns moves into the subject's region, what the
  subject owned is retired there, whole, until that region drains, and the
  bytes are replaced a word at a time while one global count of write-backs
  begun is ahead of the count done. A subject reached any other way is
  written where it is, since no other thread can reach it (§4.3). Other
  threads see the call's writes all at once, when it returns, which is one
  of the orders §3.7 already allows.
- **Snapshots.** A value read through an owner into a fresh binding -- a
  local, an argument, an operand -- is read as a snapshot (§4.4): its bytes
  are taken when every write-back begun is done, and taken again if one
  began meanwhile. Nothing a snapshot names is ever returned while a reader
  could follow it, since a write-back retires what it replaces, so a value
  that owns blocks is then copied whole from the snapshot with no further
  checks: none of §4.4's bounds on a walk are needed, and no attempt
  allocates anything it has to give back. A `match` or a case read on such a
  place reads it where it is. Each snapshot is a call into the runtime,
  where an inline check of the two counts would do; that, and how long
  retired values are kept, is left to measurement.
- **An owner lent to a running spawn.** The spawning block may not write an
  owner it lent a spawn that may still be reading it; the checker rejects
  that write ([`spec-divergences.md`](../spec-divergences.md) §12), so the
  only writes that race a reader are spawned write-backs, which the
  snapshots above cover.
- **Where a spawned call is waited for.** Only a spawned call bound by a
  `let` is waited for where its local is read ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §3.2). One
  read where it is written -- an operand, an argument, a value assigned to a
  local that already exists -- is waited for at once, so lowering calls it
  there. Only timing tells the two apart.
- **A spawned call that can abort or exit.** Its frame holds the call's
  whole outcome (L12), which comes home into a slot laid out for it: the
  result's blocks under the done tag, the abort value's under the
  aborted one. The call settles once, on the spawning thread, where it is
  first read or where its block ends
  ([`spec-divergences.md`](../spec-divergences.md) §11). A flag the spawn sets
  says whether it has. An abort takes the abort value out of the slot and
  runs the handler written at the spawn, lowered where it settles but in
  the context of the spawn, so its `abort`, `return` and exit go where they
  would from there; its `resolve` puts the result in the slot. An exit ends
  the run of the block the spawn is in.
- **An abort value no binder names is held.** A handler without a binder,
  such as `??`'s, still holds the abort value in its own scope when it is an
  owner or owns a block, so the handler's drain ends it.
- **A value parameter is borrowed.** A value that owns a block is copied
  whole where it is stored from a place ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §2.3), and passed
  as it is where it is only read: a value parameter is read-only (§2.9), so
  the caller keeps it, and a fresh one is held in the caller's scope first.
  A callee that stores its parameter copies it.
- **A case read of an owner.** What a case read gives is its payload, which
  the variant keeps, or what its handler resolves, which is fresh. So a read
  whose type is a reference type, or a value that owns a block, gives an address: the
  payload's, or that of a slot reserved in the reading scope before the read,
  which the handler's `resolve` fills. Either way what it gives has one
  owner, and the drain ends the slot.
- **A literal's bytes stay where the program keeps them.** A string's
  handle points into the dynamic region ([`types.md`](https://github.com/zane-lang/spec/blob/911d749/spec/types.md) §2.7). A literal's
  points at the bytes the program embeds instead, and the handle also holds
  the room of the block it owns, which is 0 for a literal's, so a literal
  takes no block and returns none, and a copy of one shares the embedded
  bytes.
- **A `this` address is taken once per call.** The subject is a borrow
  ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.9), so nothing in the call moves what it names:
  a settled owner never moves, and a roaming one is moved only in the block
  that declares it, which is not inside the call.
- **Moving to a newer LLVM.** llvm-project's bindings track every release,
  but opam packages them only up to 19. A newer release means building
  them from that release's `llvm/bindings/ocaml`, or waiting for opam.
- **String escapes.** The spec names none, and the lexer keeps a backslash
  with the character after it. Lowering decodes `\n`, `\t`, `\r` and `\0`, and
  any other pair stands for its second character, until the spec says.
- **Values by value, for now.** L6 passes a value struct or sum by the
  address of the caller's slot and L7 has a result written into a
  destination the caller names. Lowering passes and returns value types as
  LLVM aggregate values instead, which copies what L6 would lend; a value
  parameter cannot be written, and nothing else in the call may write what
  it borrows (memory.md §2.9.1), so nothing observes the difference. A
  reference-type result, and a `^T` argument, are passed the same way, and
  arrive where the caller or the callee holds them, their blocks staying
  where they are unless the arrival is an escape. A `mut` subject, a
  reference-type subject and a borrowed reference-type argument are passed
  by address.
- **Large aggregates as memory.** LLVM's code generator gives one value at
  most 65,535 parts, and is slow well before that. Before the target machine
  sees a module, `lib/codegen/big_moves.ml` turns each load of an aggregate of
  4 KiB or more whose only uses are stores into a copy per store (a
  `memmove` when it reads the source directly, since `xs[i] = xs[j]` may
  name one element twice), and a
  value still too large to move whole, passed or returned, is reported as a
  limit rather than handed to LLVM.
- **An outcome as a sum, for now.** L12 returns a tag and has the caller
  pass slots for the result and the abort value. Until results are written
  into destinations, a function that can abort or exit returns a
  sum of three cases instead: done with its result, aborted with its abort
  value, and exited. A function that can only finish returns its result as
  before. An exit ends the run of the block the call is written in
  ([`spec-divergences.md`](../spec-divergences.md) §9), so each run of a block
  argument has a label to leave.
- **A 64-bit target.** Codegen sizes a sum's payload room assuming 8-byte
  pointers and C struct layout, which holds for x86-64 and AArch64. Another
  target reads the sizes from LLVM's data layout.
- **Integer division by zero, and a float truncated out of range.**
  `operators.md` §2.6 gives a division by zero the result zero, and
  `types.md` §2.9 saturates a `truncate` whose integer part the target cannot
  hold and gives zero for a NaN. Neither instruction LLVM has means that by
  itself, since `sdiv` by zero and `fptosi` out of range are undefined, so
  codegen guards each with selects: the divisor is replaced before the
  `sdiv`, and the bounds `Scalar.truncation` gives pick the target's ends
  over `fptosi`'s result. The one other quotient an integer cannot hold, the
  most negative value over `-1`, wraps, as `+` and `*` do. A conversion is one
  CGT node, `Convert`, whose instruction the source and target types pick,
  and the optimizer folds by the same bounds.
- **An index out of range.** The spec leaves it open ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md)
  §5.2, [`spec-divergences.md`](../spec-divergences.md) §14). Until it says, the program stops:
  what it wrote so far is kept, the runtime writes `index out of range` to
  stderr, and the status is 1, for a list and an array alike.
- **A type argument passes nothing.** A generic verb is lowered once per
  instance the TST checked ([`semantics.md`](semantics.md) D12), with a
  symbol of its own, and a type written where a value goes, or a number
  given to an explicit number parameter, has already picked the instance, so
  the call passes nothing for it. The body reads a number parameter as the
  number its instance was given.
- **A spawned call with no function of its own.** A call is spawned by
  running a function on another thread (step 8), and two kinds of call have
  none. A verb expanded where it is called because it takes literals (L11)
  gets one per set of literals it is spawned with, `zane.expanded.N`, with
  each literal bound where the body reads it. An array literal's elements
  are values, made where the spawn is written, so that parameter becomes
  one the function takes, of the array's type. A block argument would
  capture the spawning frame, and the spec forbids spawning one
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/concurrency.md)
  §3.1). A call to an intrinsic runs through `zane.intrinsic.N`, which
  takes its arguments and makes the call.
- **A field constructor is a call.** A field-constructor call calls the
  constructor, whose body runs as any verb's does, with each entry's value
  in its slot. An entry the call leaves out passes the default the TST typed
  for it ([`semantics.md`](semantics.md) §6). The entries run in the order
  they are written, then the defaults in declaration order
  ([`types.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/types.md)
  §3.3).
