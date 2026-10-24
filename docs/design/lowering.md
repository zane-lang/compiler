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
no text is written and read back. The target machine tunes code for the
processor clang would pick: `x86-64` on any x86-64 target, `core-avx2` on
`x86_64h`, the Haswell architecture, and LLVM's default elsewhere. Each
allows only the instructions every processor of the architecture has. Linking that object with the runtime (§6) is done by LLD,
linked into the compiler as a library, with the arguments the C compiler
would give it (§7).

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
| value type (a borrow) | the address of the caller's slot, or the value itself when it is a scalar; one the body copies once into what it keeps takes the value instead, a fresh argument moved in and a place copied where the call is (§9) |
| `T`, a reference type (a borrow) | the address of the caller's slot, which keeps the owner |
| `^T` (a take) | the moved value itself, which the callee holds in its body's arena, so the body's drain ends it unless the body moves it on ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.5), or in a slot of its own when every way out moves it on (§9) |
| `&T` (a reference) | the address of the settled owner it names |
| `this` | the address of the subject's place, taken once at the call |

A call site that mints a reference for an `&T` parameter, or moves an owner
into a `^T` one, does so with an explicit CGT operation (§3), not inside the
call.

A function also lists its locals that hold a value type. No reference names
one ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
§2.4), so only the addresses the function takes of it reach its slot, which
is what folding counts on when code it cannot run is given other addresses
([`optimization.md`](optimization.md) O6).

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
§4.1). Then it releases the scope's fixed-size and dynamic chunks together,
with every value still in them ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §3.2).
There is no per-object pass at a drain; an object that dies earlier —
overwritten, or its container gone — is destroyed there, by its own
`destroy` (L9). Lowering
may fold nested scopes into one arena when nothing observes the difference
([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1); the first version gives every block that
declares a local its own.

**L9. Storage operations are CGT nodes, each a call into the runtime or a few
instructions.** The set lowering writes, with the sections of [`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
that define each:

- `slot` — a fixed-size slot in a scope's arena, at an offset in the
  scope's frame that codegen fixes (§9);
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

An **expression verb**, one whose body is a single expression it returns, is
expanded at each direct call as well, in every build, but it keeps its
function for every use that needs one: a spawned call, a library's export,
and an object built apart. That is each of `core`'s one-line wrappers, such
as `Int +(left Int, right Int) => Int(@operators$add(left._value,
right._value))`, so a program's arithmetic reaches stage 5 and codegen as
intrinsics rather than calls, a generic one's instance included. The same
binding rules hold, with one more: a verb that writes none of its parameters
reads a local it is given where the caller keeps it, since nothing else in
the call writes what the call borrows
([`memory.md`](https://github.com/zane-lang/spec/blob/ae25c51/spec/memory.md)
§2.9.1) and nothing its body runs can. A verb qualifies when it declares no
abort and nothing it would write out spawns or holds a lambda, whose
function is named after the verb it is written in. Its size counts what it
writes out with it: each expression verb it calls, and the whole body of a
verb that always expands and of a declared subscript. A verb over 40 nodes
with them is called, so a chain of verbs that each call the next twice
stays a chain of calls a few levels up. One that would be written out
inside itself, as a recursive verb would be, is called there instead. So a
recursive verb's own function writes each call to itself out once, and
calls the function from the copy: a tree's walk does two levels of work per
call, which is most of what writing out gains `copies` and optimized
`trees`. And a call that gives a fresh value to a value
parameter that owns blocks calls the function: written out, the value would
be held in a slot of the caller's and copied wherever the body keeps it,
where the function takes it as it is (`Regions.taken_params`).

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
`main` runs. A program's `main` is called, through the start function
below, by the runtime's C `main` after it sets itself up.

Each constant has a function of its own, named by the constant, and two
variables: its value and how far its making has got. The first call makes
the value in a scope of its own, stores it, and moves the blocks it owns into
the program's region; every call returns the value's address, and a read of
the constant is a read through it. A constant that reads another calls that
one's function first, so dependency order holds whatever order they are
declared in, and a constant that reads itself, through any chain, stops the
program. A context that finds another making a constant waits for it.

Those waits can form a cycle across contexts: making a constant may spawn
a call that reads, through any chain, the constant being made, and joining
that call waits for a context that waits for the joiner. The runtime keeps
the graph of waits (`runtime/value.c`). A context about to block names what
it waits for, a constant's state, whose maker it waits for while the
constant is made, or a call it joins, whose context it waits for while the
call runs. A call run where it is joined is waited for the same way. Each
edge is read from what it names when it is followed, so a made constant or
a finished call leads nowhere, and a reused context is never reached
through a wait that has ended. Edges are set, cleared and followed under
one lock, so the last wait to close a cycle follows the edges from its own
context back to itself, and the program stops with "package constants read
each other while they are made" and status 1, the program's error as an
index out of range is. A maker reading its own constant again is the
one-step case of the same test.

A program's entry is always a start function, `zane.start`, that calls each
constant's function, the packages a package depends on first, and then
`main`, discarding what `main` returns. The runtime calls the entry as
`void zane_main(void)` (`runtime/zane.h`), and `main` may return any type,
so calling `main` itself would give the runtime a function of another type
whenever `main` returns a value, and whether it did would depend on whether
the program has constants. A discarded result that is an owner or owns a
block is held in the start function's own arena, as any dropped result like
it is (§3), so a large one takes a frame of the main context's range, not
the machine stack, and its blocks drain with that arena. An optimized build
inlines the start function; an unoptimized one pays one call.

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
language: printing, the program's arguments, reading a number from text,
`List` growth, `String` storage. Its interface is a small
set of C functions that CGT storage operations (L9) and intrinsic calls lower
to, so a change to how an arena works changes the runtime and nothing in the
compiler. What walks a type's blocks -- to copy, end, move or overwrite a
value of it -- is the one part the compiler emits instead, for each type
(§9); the runtime runs the walks it is handed. It lives in `runtime/`, is
built by `clang`, which already links every program, and is tested in C on
its own.

C because it adds no toolchain beside the LLVM the compiler already uses, and
because an arena is exactly the kind of code C states without ceremony.

The math functions of `@math$` ([`math.md`](https://github.com/zane-lang/spec/blob/1457830/spec/math.md)
§2) need no runtime function. A call to one lowers to a `Math` node, which
codegen emits as an instruction or an LLVM intrinsic when the function is
exact, a shift's count masked to the width first, and as a call to the C
math library's function of the same name when it is approximate, marked
`nobuiltin` so that LLVM neither computes it ahead of time nor rewrites it.
Its result is then the library's where the program runs, as §2.6 has it
(`platforms.md`).

---

## 7. How it is built, and how to look at it

Lowering lives in `lib/cgt/`, beside `lib/tst/`: `nodes.ml` for the tree,
`lower.ml` for the TST → CGT walk over a verb's body (its expressions,
the storage they read, and its blocks and statements), the `lower_*.ml`
modules for the rest of that lowering, each taking the walk as an argument
so that it stays outside the walk's recursion (`lower_intrinsics.ml`,
`lower_data.ml`, `lower_calls.ml`, `lower_match.ml`, `lower_spawn.ml` and
`lower_lambda.ml`), `program.ml` for a whole program built with it, `traverse.ml` for what each node is made of
and the walks and rewrites every pass over the tree uses, and
`to_tree_graph.ml` to render it. Codegen
lives in `lib/codegen/`: `emit.ml` builds the module through the bindings,
and `build.ml` writes the object file and links it with the runtime. The
runtime is written as nine parts in `runtime/` (`main.c`, `arena.c`,
`region.c`, `block.c` and so on), with `zane.h` as the ABI that emitted code calls,
`zane_abi.h` as the offsets and sizes emitted code relies on, which codegen
reads as `Abi`, and `zane_internal.h` as what the parts share. `runtime/dune` joins the parts in
a fixed order into one generated `zane.c` and embeds it, with the headers,
into the compiler as strings, so a build needs nothing beside the compiler
and a C compiler (`clang`, or `ZANE_CC`). The C compiler compiles the runtime
apart from the link, and the object is kept in a cache directory
(`ZANE_CACHE_DIR`, else `$XDG_CACHE_HOME/zane`, `~/.cache/zane`, or
`%LOCALAPPDATA%\zane` on Windows) under a hash of the runtime's sources, the C
compiler's command and its `--version`, the target triple, and the flags it
compiled with. The `--version` answer is itself kept there, under the path,
size, modification time and inode of the file the command runs, so a build
asks again only once that file has changed; on Windows, whose command search
it does not follow, it asks every time. A
later build that would compile the same object links the kept one instead,
which saves most of a small program's build. A build with no cache directory,
or with a C compiler that will not say its version, compiles the runtime every
time.

The runtime is compiled with `-fzero-call-used-regs=skip`,
`-fno-stack-protector`, `-fno-stack-clash-protection` and `-fno-wrapv`, and,
on every target but Apple's, whose ABI keeps frame pointers,
`-fomit-frame-pointer`, whatever the C compiler would add by itself. On ELF
it also takes `-ftls-model=local-exec`: the runtime is only ever linked into
an executable, so a thread's variable is read at a fixed offset from the
thread's pointer, rather than through the descriptor a position-independent
compile asks for. Some toolchains add the rest by default, Nix's hardened
clang among them, and they cost the runtime's small, hot functions more than
anything else in them; `-fwrapv`, signed arithmetic that wraps, keeps LLVM
from simplifying the runtime's rounding of sizes. The C library's checked
forms of its functions, which such a toolchain turns on with a
`_FORTIFY_SOURCE` it defines after every flag, are turned off in
`zane_internal.h` itself. A C compiler that refuses any of the flags
compiles the runtime without them, and says nothing of it.

An optimized executable takes the whole runtime into its module instead of
linking the runtime's object: the runtime compiled to LLVM bitcode, kept in
the cache beside its objects under the same kind of key, is linked in before
the passes, every definition in it made the program's own, internal, or
hidden when stamped dependencies' objects linked with the program call the
runtime too, and an empty object takes the runtime's place in the link.
There is then one copy of the runtime, so LLVM may inline any of it and sees
the runtime and the program as one. Where a call is the slow path of
something emitted code already does itself, such as a push past a list's
room, it is marked `noinline`, since the runtime's body would only repeat
the fast path there. A program built so is checked against the same golden
files as every other build. `--ll` prints an optimized module as the
builds below take it, with only the runtime's bodies, since the whole
runtime's text would bury the program's.

A tiered build's two tiers and an optimized library object (`--object`)
cannot take the whole runtime, since the runtime they run is another
object's: tier 0's, or the program's that links them. Before the passes
they link into the module the bodies of the runtime's functions it
calls, and of the functions those call, as
`available_externally` (`lib/codegen/runtime_bodies.ml`). LLVM inlines them
where it judges a call worth it, and every call it leaves still goes to the
runtime the program links, so nothing the runtime keeps is copied: each of
its variables comes in as a declaration of the runtime's own, a thread's
read at a fixed offset from the thread's pointer as the program's own are.
The bitcode is compiled position-independent, so no definition in it is
taken for the program's. A body is left out, and its function stays a call,
when it would not mean the same copied: it reads a variable of the
runtime's own translation unit, which no other unit can name, takes the
address of one of the unit's functions, which a copy would not share, or
calls one marked `noinline` or `cold`, which would be copied whole; a
function that calls such a function is left out too. A function marked
`cold`, such as `zane_hold`, which runs only when drains are checked, is
left out as well, since inlined it costs its caller registers on the path
that never runs it. The variables the runtime's hot paths read, such as
its page table, are therefore not `static`. In a tiered build a body that
calls outside the runtime is left out as well, since tier 1 imports
everything through tier 0's table ([`tiers.md`](tiers.md)), and each C
library function in it would cost a symbol lookup as every run starts. A
body taken loses any stack protection the C compiler gave it: it becomes
the program's code, which has none, and inlined it would give its caller
the protection too. Bitcode is read only by the LLVM that wrote it or a
later one, so the C compiler must be a clang of the compiler's LLVM version
or older, as devbox's is; with any other, or one that makes no bitcode, a
build links the runtime's object and calls its functions, and the cache
keeps an empty file so the C compiler is asked once.

The link itself runs in the compiler. Starting the C compiler and its linker
as programs of their own costs about eight times the link: each loads LLVM's
shared library again. So the first build for a C compiler, target, set of
flags and objects to link asks the C compiler, with `-###`, for the linker
command it would run, keeps it in the cache under those, and every build
runs that command with its own files put in, through the LLD linked into
`zanec` (`lib/codegen/lld_stubs.cpp`): `ld.lld` for ELF, `ld64.lld` for
Mach-O and `lld-link` for COFF. What the C compiler prints is the work of
its driver, which knows where the target's start-up files, C library and
compiler runtime are on this machine; LLD knows none of it. LLD runs the
command whichever linker the C compiler would have run: GCC's `collect2`
takes the linker's own arguments, so it is run as `ld.lld` without GCC's LTO
plugin, and `zig ld`, Zig's Mach-O linker, takes ld64's, so it is run as
`ld64.lld` with the target's architecture and the `libSystem` stubs Zig
carries (docs/design/platforms.md). A C compiler whose own linker is another,
such as clang with the system's `ld`, is asked again with `-fuse-ld=lld`.
LTO's `-mllvm` options are left out, since they would set options of the
compiler's own LLVM.

A C compiler whose command LLD cannot run, because it prints none of those or
does not name the program's files, links the program itself; that is kept in
the cache too, so it is asked only once, and `ZANE_VERBOSE` makes each such
build say why. When LLD cannot link with a command and the C compiler can,
the build warns. A command kept by an earlier build may have gone stale, as
when a libc update moves its start-up files, so it is forgotten and asked
for again; one just asked for is not, so the C compiler links for that
target and those flags until the kept answer is removed. A program neither
can link is an error, and nothing is forgotten.

A released toolchain runs no C compiler at all for the targets it bundles.
Its `zanec` sets `ZANE_RUNTIME_OBJECTS` to the toolchain's `share/runtime/`
when it also sets the C compiler to its own `zig cc`, and a build looks
there before the cache, for an object named by a hash of the runtime's
sources, the target triple in LLVM's normal form and the flags besides the
target's, and in its `link/` for the linker command named by a hash of the
triple, those flags and the libraries every program for the target links
with. Spellings of a target with one normal form, such as
`x86_64-linux-gnu` and `x86_64-unknown-linux-gnu`, and a build for the host
that names no target, so find one object and one command; a spelling LLVM
normalizes apart, such as one naming another vendor, compiles its own.
Packaging fills the directory with `zanec --bundle-runtime DIR --target
TRIPLE [--optimize]`, for each target `dev/release/package-linux.py` lists.
It compiles the runtime as a build for that target would, then asks the C
compiler for the command linking a program with it, through a program object
defining only what the runtime takes from a program, and copies every file
the command links besides the program's own into `link/files/`, named by its
contents, where the command names it relative to the bundle. With
`--optimize` it also compiles the runtime's bitcode beside the object,
when the C compiler makes bitcode this compiler's LLVM reads; otherwise
the release bundles none, and its optimized builds call the runtime's
functions rather than inline them. The loader a
program names, `--dynamic-linker`, is a path on the machine the program runs
on, and is not copied. A program's other objects, its dependencies', are put
in after its own. A target is always named there, since a C compiler given
none compiles for the processor it runs on. A build for any other target, or
with another C compiler or Zig, compiles its runtime and keeps it in the
cache, and asks for its linker command as above.

Lowering starts at the root package's `main` and lowers each verb the first
time a call reaches it, so a program's unused declarations never need to
lower. Whatever it cannot handle yet it refuses with a diagnostic at that
node, never by lowering it wrongly.

Lowering does not handle these yet, and refuses each where it is written:

- a control-flow intrinsic, such as `@controlflow$branch`, used as a value
  rather than as a statement;
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
| `--tiered` | with `--build`, makes tier 0 of a tiered build, whose calls go through slots tier 1 fills while it runs, linked with the runtime compiled with `-O2` ([`tiers.md`](tiers.md) T1, T4, T5) |
| `--tier-up OUT` | makes tier 1 of a tiered build, the program optimized into the shared library `OUT` ([`tiers.md`](tiers.md) T1, T2) |
| `--stamp PATH=STAMP` | names the symbols of the package at `PATH` with `STAMP`, as `--package STAMPPATH=DIR` does; a dependency given one arrives as objects of its own, so its verbs are declared rather than lowered (C1, C6, C10) |
| `--import PACKAGE:KEY=PACKAGE` | the package the first imports by `KEY`, each named by its identity (C10) |
| `--link FILE` | links the object `FILE` into the program `--build` makes, as a stamped dependency's objects are (C7) |
| `--target TRIPLE` | compiles `--ll`, `--build` and `--object` for the LLVM target `TRIPLE` instead of the host, and has the C compiler link `--build` for it; LLVM gets the triple's normal form, and the C compiler the triple as written ([`platforms.md`](platforms.md)) |
| `--optimize` | runs stage 5 over the tree ([`optimization.md`](optimization.md)), then LLVM's `-O2` pipeline over the module, with the whole runtime in it (§7), generates optimized code, and compiles the runtime with `-O2` |
| `--fixed-region BYTES` | the size of the main context's range of frames, a whole number of MiB, 256 MiB when absent (§9) |
| `--spawned-fixed-region BYTES` | the size of each spawned call's range of frames, a whole number of MiB, 8 MiB when absent (§9) |
| `--pack-aggregates` | passes an aggregate that fits in the registers a call gives it as packed 8-byte words rather than as itself or by address; off by default, an option to measure (§9) |
| `--no-memoize` | builds without the tables of results calls are remembered in while the program runs ([`memoization.md`](memoization.md)) |

`zanec --rewrite STAMP INPUT OUTPUT` takes no packages: it writes the
library object `INPUT` to `OUTPUT` with its `!` placeholder turned into
`STAMP`, as fetching does ([`separate-compilation.md`](separate-compilation.md) C9).
`zanec --remap FROM TO INPUT OUTPUT` writes `INPUT` to `OUTPUT` with every
reference to the package version stamped `FROM` moved to the version stamped
`TO`, as remapping does (C11).

`--no-root` refuses `--build`, since a build without a root is not an executable.
With it, lowering starts from every verb each of the project's own packages
declares that is not generic and has a function of its own, and from their
lambda-variables, rather than from `main`, and names them with the `!`
placeholder ([`separate-compilation.md`](separate-compilation.md) C1, C5),
or with their stamp when they have one (C6).

Without `--optimize` no optimization runs over the program, neither stage 5
nor LLVM's, which makes the build about three times faster; only the
runtime linked by tier 0 of a tiered build is compiled with `-O2`
([`tiers.md`](tiers.md) T5). `zane build`
optimizes, and `zane run` makes both builds at once and moves the program
from the unoptimized one to a lighter optimized one while it runs
([`tiers.md`](tiers.md)). A program means the same every way, since the
semantics leave nothing for an optimizer to decide, so `tests/codegen/` builds
each fixture plain, optimized and tiered and holds all three to one golden
file.

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
   is tested in C on its own, and a checked drain stops a program that
   ends with a block still out.
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
    a program value such as `@program$console` passed as a guest, and
    spawned calls to an intrinsic or to a verb expanded where it is called. After this step lowering refuses no
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
    `@primitives$ArrayRef<T, n>` lowers as `Array` does from any of its
    literal constructors, `.refs` and `.roaming` included, with `fill` a
    counted loop over its lambda. `@primitives$String` is a value type. The runtime
    is tested in C on its own: an overwrite keeps a boxed member's address,
    and arrival leaves blocks that outlive their destination where they are.
12. **Where blocks are made.** Once every function is lowered, a pass over
    the whole tree (`lib/cgt/regions.ml`) works out which callees keep the
    `^T` arguments they are given. A function whose arena holds only owners
    that every way out moves on opens none, so what it makes is made where
    its result goes and nothing relocates it, and a value parameter copied
    once into what the callee keeps takes a fresh argument as it is. A block
    that moves a fresh owner into a callee that can drop it keeps an arena,
    so the owner goes with the block. Issue
    [#210](https://github.com/zane-lang/compiler/issues/210).

---

## 9. Open questions

- **How many scopes get an arena.** L8 gives every block that declares a local
  its own. Lowering opens one only for a block that holds a reference-type
  local, and a value-type local stays an LLVM stack slot, since nothing
  tells the two placements apart until a value owns dynamic storage, which
  it does only through a boxed member; such a value is held in the arena
  too. Once every function is lowered, `lib/cgt/regions.ml` folds more of
  them away ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §3.1), from what it works out about every function at
  once:
  - A `^T` parameter is **kept** when every way out of its function has
    moved it on: into the result, into a place the caller lent, or into a
    callee that keeps it in turn. A callee another object defines, one
    called through a function value, and a verb expanded where it is
    called are taken to drop what they are given.
  - A slot written with a new owner holds a second owner, which every way
    out must move on too. The first must have gone on before the write,
    since writing over an owner drops it.
  - A function whose whole body is one arena, holding only owners that
    every way out moves on, opens none. It holds them in slots of its own,
    and what it makes is made in its caller's innermost region, which is
    where its result goes, so nothing relocates it (§3.5). A function with
    a spawn, a reserved slot, an arena nested in its body, or a callee lent
    one of its slots that opens an arena keeps its own, since the runtime
    takes a slot outside every arena to be in the innermost one's region.
  - A value parameter the body only reads to copy it once into what it
    keeps takes its argument: a fresh one is moved in rather than held by
    the caller and copied, and a place is copied where the call is. Only a
    function no other object calls, and none calls through its address,
    is changed this way.
  - A block that moves a fresh owner into a callee's `^T` parameter keeps
    an arena when the callee can drop it, so the owner's blocks go when the
    block drains (below); for one that keeps it, the block opens none for
    it, and an arena left holding nothing goes.
- **A scope's slots are one frame, in one range per context.** Every slot a
  scope places has a size known at compile time, so `lib/codegen/frames.ml`
  lays the scope out as one frame: the runtime's record of the scope at
  offset 0, then each slot and each spawned call's header and frame at a
  constant offset. Scopes nest last-in-first-out, so each context reserves
  one contiguous range of addresses for its frames: a scope's frame starts
  where the frame around it ended, and draining it moves that point back.
  Where [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1 gives each scope 1 MiB chunks of its own,
  this places the frames back to back. The spec leaves arena granularity to
  the implementation and fixes only that a scope's memory is released
  together, which this does.
  - **Entry and drain are inline.** While no call the context spawned is
    out, nothing else reaches it, so emitted code opens a scope itself: it
    takes the frontier as the frame's start, moves it past the frame, zeroes
    the record and links it to the scope around it. A slot is the frame's
    start plus its offset. A drain that has no spawned call to wait for, no
    dynamic chunk to give back and no check to run moves the frontier back
    to the record. Otherwise both call the runtime, which does the same
    under the context's lock. A reserved slot and a spawned call's header
    and result slot are zeroed where they are placed; a held slot is written
    at once.
  - **The range is reserved, and becomes usable as it is touched.**
    `runtime/region.c` reserves the range with no access, then a guard of
    1 MiB. The first touch of each further MiB faults, and the fault handler
    makes it usable and lets the access run again (`mprotect` on POSIX,
    `VirtualAlloc(MEM_COMMIT)` on Windows), so a system with strict
    overcommit charges only what is used. If the system cannot commit a
    step, the program reports "out of memory: cannot commit a context's
    fixed-size region" and exits with status 1. A frame of up to 1 MiB that does
    not fit faults in the guard; a larger one is checked against the
    range's end before it is placed, on a branch marked unlikely. Either way
    the program stops with "scopes nested too deep", the range's size, and
    the manifest field that sets it, and exits with status 1. So reading
    any slot of an open scope's frame either reads the program's memory or
    stops it as the frame was owed, whichever slot is read first, which
    codegen tells LLVM ("What LLVM is told").
  - **The sizes come from the root manifest.** The main context reserves
    `--fixed-region` bytes, 256 MiB by default, and each spawned call's
    context `--spawned-fixed-region`, 8 MiB by default. `zane` passes them
    from the root manifest's `fixed-region` and `spawned-fixed-region`
    ([`dependencies.md`](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md#21-manifest-zanecoda) §2.1), and
    the module that defines `zane_main` defines them for the runtime.
  - **No cap on nesting.** A scope's record links to the scope around it
    and to one it skips to (Myers' skew-binary jump pointers), so finding
    the scope whose frame holds an address takes steps logarithmic in the
    depth, and nothing keeps an array of scopes by depth. The chunk map
    holds a pointer for each MiB, to a dynamic chunk's scope or to the
    context whose range it is in, so it caps no depth either.
  - **The machine stack.** A program's calls also nest on the machine
    stack, which for most programs fills long before the range does. Every
    worker has 8 MiB of it; the main thread's size is set by its launch
    environment on POSIX and to 8 MiB by the linker on Windows
    ([`platforms.md`](platforms.md)). Emitted functions probe it page by page as they
    grow it, and the fault handler runs on a stack of its own, so a full
    machine stack stops the program with "recursion too deep" and status 1
    rather than a crash.
  - **The program's output.** A print writes into a buffer of the
    runtime's own (`runtime/main.c`), never through stdio, so that the
    fault handler can flush it with only async-signal-safe calls. It has
    stdio's size for stdout, the block size `fstat` reports or `BUFSIZ`,
    and flushes where stdio's would: when it fills and when the program
    ends, and at every print that writes a newline when stdout is a
    terminal, which the runtime asks once at startup. A mutex orders
    ordinary writers, and an atomic `busy` flag grants the buffer: a
    writer claims it from free to 1 after taking the mutex, and touches the
    buffer only then. A failed write marks the output failed, and the
    program then ends with status 1. The exit path, an index out of range,
    a cycle of constants and `zane_broken` flush it first.
    - **From the fault handler.** A stop for a full machine stack, a
      range full of frames or a failed commit claims `busy` from free to 2
      without the mutex, and flushes only if that succeeds, so it loses at
      most the buffer when another thread, or the faulting one, was mid
      print, and a writer that later finds 2 waits for the program to end.
      A write to a full pipe would block, and a check before it cannot
      rule that out, since another process may fill the pipe in between.
      So the handler writes a socket with `MSG_DONTWAIT`, and a pipe, on
      Linux, through `/proc/self/fd/1` opened anew with `O_NONBLOCK`, a
      description of its own that no process sharing fd 1 sees, dropping
      what it cannot write at once. Elsewhere it drops a pipe's output. On
      Windows, where a pipe offers no way to ask whether a write would
      block, it writes only a terminal or a file. The message on stderr
      appears either way.
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
  drain. A block of up to 16 words aligned to a word is in a size class,
  whose stack is one of a fixed array at the start of the region's mark,
  beside its frontier, its frontier's end and its count of blocks out, so
  emitted code reads each at a fixed offset (below); any other size has a
  stack found by a search. A list's block doubles from 128 bytes (§3.6): up
  to 1 MiB into a returned block of that size, in place when it is last at
  the frontier, or else into new bytes. Past 1 MiB it moves once into a span
  at the start of a reservation of 64 times the span's size, made with no
  access as a context's range is (below), and each later doubling makes
  more of it usable instead of moving the elements. Where the system will
  not reserve that much, as under a cap on the address space, the
  reservation is the span alone, and a list that outgrows its reservation
  moves into a fresh one. A push is inline: while the block has room, the
  emitted code takes the element's address and counts it itself, and only a
  full block calls `zane_list_push`, which grows it. An empty list's first
  block, of 128 bytes, is made inline too, in a function with a scope of its
  own open (below). Together these make
  `listgrowth` in the spec's `langbench/`, which appends two million
  entities to a list twenty times, take less than half the time it did, and
  as much as C's `realloc` does within a few percent. It never shrinks: a
  removal moves the element out of its place and closes the list over it,
  by moving the later elements down or the last one in, and the list keeps
  the block until it dies. Where the runtime departs from the spec:
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
    list's growth goes to the region that holds the list. A box and a hold
    are made in the innermost region, which every block of what they take
    already outlives, so nothing arrives at either.
  - A value leaving scopes that drain -- a `return`, a `resolve`, an
    `abort`, a `return` from a block argument or an arm -- moves every block
    it owns in them into the scope the exit returns to, before the drain
    (§3.1). Results are returned by value (below), so that scope is the
    caller's innermost, and the value moves again if the caller places it
    further out.
  - A scope's first blocks are in its own frame, not in a chunk. While the
    scope is its context's innermost, the frontier moves on past them: the
    frame stretches beyond its slots by at least 4 KiB at a time, to at
    most 64 KiB with its record and slots (`ZANE_STRETCH` and
    `ZANE_STRETCHED`, `runtime/zane_abi.h`), as long as the range holds
    it. A list whose block is last there grows in place by stretching the
    frame further, to at most 1 MiB, and a small block after such a list,
    as the record of the stack its old block goes to, stretches it 4 KiB
    more rather than taking a chunk. An empty list's first block comes
    from the emitted push itself, with no call, when the list's handle is
    in the innermost scope's region and the push is in a function with a
    scope of its own open: the next line of the scope's heap while it has
    room and no returned block, or, while nothing has been allocated in
    the scope, a stretch of the frame. A function with none, as a
    recursive one that only builds what it returns, keeps the call, so its
    code stays small enough for LLVM to unroll its loops. A block that
    comes once an inner scope has opened, or that the stretched frame
    cannot hold, goes into a chunk of the scope's own as the spec has it. A drain moves the frontier back
    to the record, which gives back the stretched bytes with the frame, so
    a scope whose blocks all fit there maps no chunk, and its drain stays
    inline. The spec keeps a scope's fixed-size and dynamic storage apart
    (§3.1); a block here is still the scope's alone and is released with
    it. On `tests/perf` `scopes`, whose every call makes and fills a small
    list in a scope of its own, this takes 29% of the optimized build's
    estimated cycles, 33% of the plain build's and 26% of the tiered
    build's, since such a scope no longer maps, lists and gives back a
    chunk.
  - The runtime finds a block's region from a map of every chunk it made,
    and a slot's from where each open scope's slots began, trying the
    innermost scope first, rather than from a segmented offset (§3.1). A dynamic chunk begins with a cache line of
    its own bookkeeping, and an oversized block's chunks are one mapping.
  - Every block is at least a word, and aligned to one; a list's is aligned
    to a cache line.
  - Dynamic chunks come from the system directly, reserved at a 1 MiB
    boundary and committed, not from the C allocator: memory `malloc`
    owns cannot be decommitted on Windows, and on POSIX its pages are not
    the runtime's to give back. A spare chunk, one a drained region gave
    back, is **warm**, its pages resident, or **cold**, its addresses
    kept and its pages after the first given back. The first page holds
    the chunk's header and the link of the list it is on, so it stays.
    - **Warm.** A context keeps `ZANE_WARM_KEPT` (4) drained chunks warm
      for good, and any others while they have sat unused through fewer
      than `ZANE_COOLING` (8) of its later drains. A context whose call is
      over gives its warm chunks to the pool, which keeps up to
      `ZANE_POOL_WARM` (16) of them warm.
    - **Cold.** Every other spare turns cold: its pages go back with
      `madvise(MADV_DONTNEED)` on Linux, a fresh anonymous mapping over
      them elsewhere on POSIX, since macOS may keep a page's memory and
      contents through `MADV_DONTNEED`, and `VirtualFree(MEM_DECOMMIT)` on
      Windows. A cold chunk is reused like a warm one; its pages come back
      zeroed when touched, after a commit on Windows, and a failed commit
      stops the program as a new chunk's does. Past `ZANE_COLD_KEPT` (256)
      cold chunks, which hold 1 MiB of first pages, a drained chunk goes
      back to the system whole, as an oversized block's chunks always do.
    - **Reuse.** A region takes its context's latest warm spare, then one
      from the pool, then a cold one, then a new chunk. Counts beside each
      list keep every limit O(1).
    - **Windows.** A 1 MiB-aligned reservation costs an extra MiB of
      addresses there, and `VirtualFree(MEM_RELEASE)` frees only a whole
      reservation, so chunks are carved from slabs of 64 MiB, or one of
      its own for a larger block. A slab counts its chunks that are live or
      warm. A chunk given back whole is decommitted entirely, and once every
      chunk carved from a slab is cold or given back, and no more will be
      carved from it, its cold chunks leave the cold list and the slab is
      released.
    - **The delay, measured.** Langbench at spec `8298a3a`, core
      `02852ef`, built with `--optimize` before and after, on a 4-core
      x86_64 container, medians with ranges in brackets. With chunks
      turning cold at once (five runs each), ntree 10 went from 0.380 s [0.354–0.456] to 0.523 s
      [0.494–0.630] and treecopy 18 from 0.257 s [0.249–0.266] to 0.395 s
      [0.349–0.412]: both drain more chunks per scope than a context keeps
      for good, and faulted their pages back in at every drain. With the
      delay at 8 drains (seven runs each), ntree took 0.391 s [0.367–0.448] before and
      0.383 s [0.370–0.439] after, treecopy 0.295 s [0.292–0.311] and
      0.283 s [0.271–0.297], and binarytrees 16, listgrowth 2000000 and
      allocfree 1000000 overlapped too; delays of 64 and 512 drains
      measured the same. Every other langbench program overlapped without
      the delay. Peak memory did not change for any of them.
  - A value that owns a block is held in its scope's arena like an owner,
    and so is a fresh owner or value that nothing keeps, such as a result
    that is dropped or an operand, so its blocks are in a region that
    drains with it. A dropped result that owns no block has nothing for a
    drain to end, so nothing holds it: the element a discarded `swapRemove`
    moves out needs no scope.
  - A drain walks none of its values. Nothing that outlives the scope owns
    a block in its region, since an escape moves its blocks out first, so
    every block still there dies with it. A value of the scope may own
    blocks in an outer region, which a move into a deeper owner, such as a
    `^T` parameter, leaves where they are (§3.5). They are dead space there
    until that region drains. They cannot pile up. A symbol moved there is
    spent, and is refilled only in the block where it is declared
    ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.6),
    which drains no later than that region. A fresh owner moved into a
    callee that can drop it was made in an arena the block that made it
    keeps for it (above), which drains on every pass of a loop.
  - A program run with `ZANE_CHECK` set checks every drain instead. The
    scope's values and the values write-backs retired there return their
    blocks one at a time, and a block still out in the region after that is
    one whose owner is somewhere the scope cannot reach, which stops the
    program. The codegen and object tests run every program both ways,
    each held to the same output.

  Nothing a program does can tell these apart.
- **Each type's walks.** Copying, ending, moving and overwriting a value
  each walk the blocks it owns, down through the blocks inside them. Codegen
  emits the four walks for each type whose layout lists a block, the first
  time the program walks a value of it, and a table of them, named for the type, which is what the runtime is handed
  wherever it is to walk a value of the type: a copy, a slot whose value a
  checked drain ends, an arrival, a promotion, an overwrite, a spawned
  call's result, a write-back and a constant. A type that owns no blocks has
  no walks, and is handed as none. Types whose layouts list alike
  positions, each nesting layouts that walk alike in turn, share one table
  and its walks, named for the first of them by name, so `List<String>`
  under three names is walked by one set. A walk knows its type's positions, the
  offset of each and the variant tags each lies under, so it reads each
  handle and box where it is, and calls the walk of what a box or a list's
  elements hold directly, one level deeper. An array whose elements own
  blocks is one position, its count, the bytes between its elements and
  the element's layout, so a type's positions do not grow with an array's
  length: its walks loop over the elements and call the element's walk for
  each, one level deeper. They never hand an element's walk on, since an
  element is inline and an overwrite writes over its bytes before the work
  would run; how deep arrays nest is bounded by the type. Past 256 levels it hands that
  walk to the runtime's work instead, which runs it from the top once the
  walk handing it on returns, so a value nested any number of boxes deep is
  walked without the machine stack growing with it ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md)
  §2.3 sets no depth limit). An end hands on the return of a block before
  the walks of what lives in it, so the block is returned after them, and
  an overwrite hands on its own arrival before it writes anything below it,
  so the deepest places arrive first. Codegen emits the vacating of a value
  of the type too, which the runtime never needs. A copy takes all its
  blocks in the innermost region and holds that region's lock for the whole
  walk, so it takes a boxed payload's block inline: the top of its size
  class's stack, or else the next bytes at the frontier, and calls the
  runtime only when neither has one. A box takes its block the same way,
  in the region the runtime names `zane_open`: the innermost one of the
  context running on the thread, while no call it spawned is out, so that
  no other thread can reach it, and otherwise null. A payload larger than
  the largest size class, or a null `zane_open`, is left to the runtime.
  This makes binarytrees, which boxes every node, use a third of the
  instructions it did. A move, an end and an overwrite return
  blocks to other regions, so they call the runtime for each block. Walking
  a table instead decoded each position from it at run time, for each block;
  the emitted walks make treecopy, which copies a tree whole, 2.6 times
  faster (`tests/runtime/README.md`).
- **Each spawned call has a context of its own.** A spawned call runs with
  its own nest of scopes and its own range of frames, so a thread places
  frames only in its own; a thread that runs one while waiting for it switches to that
  context for the call. The call's result is kept in its frame, with its
  blocks in the first scope of the call's context, until it comes home: at a
  read of the local it is bound to, or at its block's drain. There it is
  copied into a slot the block reserved, and its blocks move into the
  block's region, as any value's do where it arrives from another context.
  The context then goes back to a pool for the next call, and keeps its
  range for it. The chunk map names the context each MiB of a range belongs
  to, and the scope each dynamic chunk does.

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
  bytes are replaced while one global count of write-backs begun is ahead of
  the count done. Each piece is stored in one atomic access of the widest
  width, up to 8 bytes, that its address is aligned to, so every naturally
  aligned 1, 2, 4 or 8 bytes of the subject changes in a single store. A
  subject reached any other way is written where it is, since no other
  thread can reach it (§4.3). Other threads see the call's writes all at
  once, when it returns, which is one of the orders §3.7 already allows.
- **Snapshots.** A value read through an owner into a fresh binding -- a
  local, an argument, an operand -- is read as a snapshot (§4.4): its bytes
  are taken when every write-back begun is done, and taken again if one
  began meanwhile. Nothing a snapshot names is ever returned while a reader
  could follow it, since a write-back retires what it replaces, so a value
  that owns blocks is then copied whole from the snapshot with no further
  checks: none of §4.4's bounds on a walk are needed, and no attempt
  allocates anything it has to give back. A `match` or a case read on such a
  place reads it where it is. A value of 8 bytes aligned to 8 is read in one
  atomic load that codegen emits: a write-back changes exactly those 8 bytes
  in a single store, since its pieces are aligned blocks of at most 8 bytes
  and such a value holds no smaller place a write-back could target, so the
  load sees all of the old value or all of the new one, which is the
  snapshot. A narrower value can sit inside a wider piece that one store
  writes, which LLVM does not make atomic with a narrower load, so it stays
  a call. The load is `unordered`, which LLVM may
  move and combine as it does plain loads, unless the value holds an
  address, such as a box's: that one is an acquire load, so what the address
  names, written before the write-back's release fence, is seen with it on a
  processor that reorders loads. A wider value is a call into the runtime,
  which checks the two counts and fences the same way. The load makes trialdiv,
  fannkuch and entities 1.8 to 4.6 times faster than the call, and a
  diagnostic build with plain loads in its place is no faster
  ([#203](https://github.com/zane-lang/compiler/issues/203#issuecomment-6062273902)).
  How long retired values are kept is left to measurement.

  A program none of whose code spawns reads such a value where it is, as
  a plain load. Only a spawned call writes back, and only spawned calls
  run on the pool's threads, so in such a program nothing writes while it
  reads. Lowering decides it from the source of every package in the build,
  a stamped dependency's included, since its objects are built from that
  source ([`separate-compilation.md`](separate-compilation.md) C2), and a
  spawn anywhere counts, reached or not. A library's object keeps its
  snapshots, since a program that spawns may link it. The plain load is
  what lets LLVM forward a value just written to the read after it, and
  keep a field in a register across a loop, which no atomic load allows.
- **An owner lent to a running spawn.** The spawning block may not write an
  owner it lent a spawn that may still be reading it; the checker rejects
  that write ([`spec-divergences.md`](../spec-divergences.md) §11), so the
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
  ([`spec-divergences.md`](../spec-divergences.md) §10). A flag the spawn sets
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
- **How a value crosses a call.** L6 lends a value parameter by the address
  of the caller's slot and L7 has a result written into a destination the
  caller names. Lowering passes and returns value types, a reference-type
  result and a `^T` argument as values in the CGT, and codegen decides per
  type how each crosses (`Emit.passing`, beside `fn_type`), the way clang,
  rustc and swiftc keep a small aggregate in registers and pass a large one
  by pointer. A `mut` subject, a reference-type subject and a borrowed
  reference-type argument are addresses already.
  - **The count.** A type takes as many registers as the scalar pieces LLVM
    splits it into (`Emit.pieces`): a struct's and a sum's are its members',
    a sum's tag and each word of its payload room one apiece, an array's its
    element's times its length, and `Unit` none. It is counted on the CGT
    type, not LLVM's, so it cannot depend on the data layout, and worked out
    once per type. `{ I32; I32; I32; I32; }` is 16 bytes but 4 registers; a
    string or list handle is 3.
  - **The limit.** An argument of no more pieces than the target's C
    calling convention gives one aggregate passes as itself: 2 on x86-64
    Linux and macOS and on AArch64, and 1 on x86-64 Windows
    (`Emit.registers`). A larger one passes by address.
  - **A result's limit.** A result comes back as itself while it takes no
    more pieces than LLVM returns in registers (`Emit.results`,
    `Emit.returning`): 3 on x86-64 and AArch64, on every system, at most 2
    of them floating-point, and the argument limit on any other target. On
    x86-64 that is `rax`, `rdx` and `rcx`, and `xmm0` and `xmm1`; a third
    floating-point piece would come back on the x87 stack, and a fourth
    piece through memory LLVM allocates itself. So a string or list handle,
    and a reference-type result that holds one, comes back in registers. A
    larger result is written through a leading `sret` pointer to a fresh
    slot of the caller's. The result's limit is wider than the argument's
    because a result through `sret` is stored by the callee and loaded
    again by the caller after every call, which a recursive function that
    builds list-holding nodes pays at each level
    ([#276](https://github.com/zane-lang/compiler/issues/276)).
  - **Fixed while compiling.** Both choices are made per signature while
    compiling, so no call branches on them, and a function value's call
    (L14) follows the same rules, since they depend only on the type and
    the target. Objects for different targets never link, so every object
    a program links agrees on them.
  - **The address passed.** An argument that is a place, a local or what an
    address names, is lent where it is: nothing else in the call writes what
    the call borrows ([`memory.md`](https://github.com/zane-lang/spec/blob/1d11ea4/spec/memory.md) §2.9.1), so no copy is needed. A
    call that returns by address writes straight into a fresh slot, and any
    other value is stored in a fresh slot of the caller's frame first. The
    callee uses the pointer as the parameter's slot. Lowering never writes a
    parameter's own slot, a borrow being read-only and a `^T` parameter held
    in a slot of the body's own first, and codegen stops with an internal
    error if one does (`Emit.unwritten`).
  - **What LLVM is told.** A parameter passed by address is `readonly` and
    `noalias`, with its alignment and `dereferenceable` for its whole size:
    nothing in the call writes what it borrows, so the optimizer may treat
    the value behind it as a private copy. It is not `nocapture`, since a
    call the callee spawns can hold the address for as long as it runs. An
    `sret` result is `noalias` and aligned, its slot being one nothing else
    names. Each call site carries the same attributes as the function.
  - **Packing, an option.** `--pack-aggregates` passes an aggregate that fits
    in the registers a call gives it as that many 8-byte words, every word
    an integer, as clang passes a small C struct: the caller stores the value
    in a slot of words and passes them, and the callee stores them back into
    one it uses as the parameter's slot. `{ I8; I8; I8; }` then takes one
    register and `{ I32; I32; I32; I32; }` two, so on a two-register target
    both travel in registers, and on x86-64 Windows only the first. It costs
    a few instructions around each call. The option is off by default.
    Since it changes how a call crosses, every function but the entry is
    named with `~packed` after its symbol when it is on, so an object built
    with it links only against objects built with it too, and a mismatch is
    an undefined symbol rather than a miscall. Packing only calls within one
    compilation would keep separate objects compatible, but the benchmark
    builds `core` as an object of its own, and its calls are the ones being
    measured; a function value, called without knowing its function, would
    also need one convention for both. It is kept only if the benchmark
    below is faster with it on some target and slower on none; following
    the platform's separate floating-point registers is a further variant,
    to measure only if packing is kept.
  - **Measuring.** `just bench-abi` (`dev/bin/abi-bench`) builds the spec
    repo's `langbench/` programs, the binarytrees reference among them
    (depth 16, as in
    [`binarytrees-reference-results.json`](binarytrees-reference-results.json)),
    and `dev/bench/calls`, which makes non-inlined calls on a 16-byte
    two-field struct, a three-byte struct, a string handle and a variant with
    a 64-byte payload. It builds them with the compiler before this rule
    (main before audit batch 3), with the rule, and with the rule and
    packing, optimized and unoptimized, checks every output, and prints the
    medians. On Windows, from WSL2:
    `ZANE_CC=dev/bin/zig-cc just bench-abi --target x86_64-windows-gnu`. The
    expected result is that the rule is no slower than the compiler before
    it; a benchmark that is slower is to be understood before the limit
    changes. The measurement, and with it the decision whether packing is
    kept, waits on the maintainer's run of that recipe on each first-tier
    target, since timings from a container are not comparable; the table
    goes here when it is made.
  - **The backstop.** Before the target machine sees a module,
    `lib/codegen/big_moves.ml` checks every defined and declared function's
    parameter and return types, and reports one still too large to move as
    one value as an internal error: the rule above makes it unreachable.
- **Large aggregates as memory.** LLVM's code generator gives one value at
  most 65,535 parts, and is slow well before that. Before the target machine
  sees a module, `lib/codegen/big_moves.ml` turns each load of an aggregate of
  4 KiB or more whose only uses are stores into a copy per store (a
  `memmove` when it reads the source directly, since `xs[i] = xs[j]` may
  name one element twice), and a value still too large to move whole inside
  a function is reported as a limit rather than handed to LLVM.
- **A type's size is limited.** A type takes fewer than `2^48` bytes, the
  addresses the runtime's chunk map covers ([`platforms.md`](platforms.md),
  "Address range supported by the runtime"), and no more than the main
  context's range of frames, `--fixed-region`, could hold. A type past
  either is refused where it is named, as "`@primitives$Array<@primitives$I64, 4294967296>`
  takes 32 GiB, which the `--fixed-region` of 256 MiB cannot hold", rather
  than built into a program that stops when it runs. A size is built up with
  checked arithmetic (`Ty.size_align`, `Type_layout.stride`, `Frames.layout`):
  a product `stride * n` is formed only after `n <= limit / stride` holds and
  a sum `a + b` only after `a <= limit - b`, so no step can overflow on the
  way to the check, as `2^60` `I64`s once wrapped to 0 bytes. LLVM's array
  types are made and read through `LLVMArrayType2` and
  `LLVMGetArrayLength2` (`lib/codegen/llvm_stubs.c`), since the bindings'
  own `array_type` and `array_length` truncate a length to 32 bits.
- **An outcome as a sum, for now.** L12 returns a tag and has the caller
  pass slots for the result and the abort value. Until results are written
  into destinations, a function that can abort or exit returns a
  sum of three cases instead: done with its result, aborted with its abort
  value, and exited. A function that can only finish returns its result as
  before. An exit ends the run of the block the call is written in
  ([`spec-divergences.md`](../spec-divergences.md) §9), so each run of a block
  argument has a label to leave.
- **A 64-bit target.** Lowering sizes every type, a sum's payload room
  included, for 8-byte pointers, `i64` and `double` aligned to 8, and C
  struct layout, which holds for x86-64 and AArch64, and the runtime's
  records have fixed offsets on the same terms. So a target whose data
  layout differs is refused before anything is emitted for it
  ([`platforms.md`](platforms.md), "64-bit targets only").
- **Integer division by zero, and a float truncated out of range.**
  `operators.md` §2.6 gives a division by zero the result zero, and
  `types.md` §2.9 saturates a `truncate` whose integer part the target cannot
  hold and gives zero for a NaN. Neither instruction LLVM has means that by
  itself, since `sdiv` by zero and `fptosi` out of range are undefined. So
  codegen sends a division by 0 or -1 down a branch marked unlikely to the
  result those divisors take, and the `sdiv` on the other branch sees only
  divisors it is defined for. The test is a branch, which the processor
  predicts, so the `sdiv` starts as soon as its operands are ready. Codegen
  truncates with `llvm.fptosi.sat`, whose result is exactly
  §2.9's: toward zero, the target's nearest end past it, and zero for a
  NaN. The one other quotient an integer cannot hold, the most negative
  value over `-1`, wraps, as `+` and `*` do. A conversion is one CGT node,
  `Convert`, whose instruction the source and target types pick, and the
  optimizer folds a truncation by the bounds `Scalar.truncation` gives.
- **An index out of range.** The spec leaves it open ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md)
  §5.2, [`spec-divergences.md`](../spec-divergences.md) §13). Until it says, the program stops:
  what it wrote so far is kept, the runtime writes `index out of range` to
  stderr, and the status is 1, for a list and an array alike, and for a
  list's `remove` and `swapRemove`, which find the element they move out
  through `List_at`. The CGT names
  the element's address as `List_at` or `Array_at`, and codegen checks the
  index where the address is made: one unsigned compare of the index less one
  against the count covers both ends, and only an index outside calls
  `zane_out_of_range`, which is cold and does not return. LLVM so sees the
  count, the index and the address as ordinary arithmetic, and can hoist or
  drop a check it proves redundant.
- **What LLVM is told.** Codegen states what it knows about the code it
  emits in LLVM's own terms, so LLVM's passes can drop the checks and
  reloads it proves redundant, rather than lowering trying to. Each is a
  contract, which LLVM may act on however it likes, so each holds for every
  program:
  - *A list's header is not an element.* A handle is never a member or an
    element of a scalar's place, so a handle's fields and a scalar place
    are disjoint storage, which type-based alias tags (`!tbaa`) say: the
    header fields read and written where an element is located, pushed or
    removed, and a handle loaded or stored whole, carry one tag, and a
    scalar loaded or stored through an address, or moved into a fresh place
    such as the element a push makes room for, carries the other, one for
    every scalar type. A removal's move of the elements after it carries
    the scalar tag too when no handle is among an element's bytes, since
    then it writes only scalar places. Every other access, a frame's, a
    walk's, an aggregate's, a move of elements that hold a handle and the
    runtime's, carries none, which LLVM takes as one that may touch both.
    So a write of an element's field leaves the count and the block LLVM
    read before it, and LLVM keeps them, and the check made with them,
    across the write, pushes of scalars in a row keep the count and room
    they read, and a loop that removes scalar elements in one of its ways
    keeps the count through the others.
  - *A place's whole slot.* A `mut` subject, or an owned value passed by
    address, is the address of a slot of the caller's, which outlives the
    call. An `&T` is the address of a settled owner's slot
    ([`memory.md`](https://github.com/zane-lang/spec/blob/4d09c87/spec/memory.md)
    §4.1), which outlives the reference (§4.2): it never moves, and an
    overwrite writes the slot in place, a boxed member's block included.
    Nothing references a list element or a variant payload (§2.1), so no
    `&T` names storage a push or a removal could move or free. Each such
    parameter whose slot has a layout lowering knows, a declared type, a
    list or a text (the CGT `Func`'s `places`), is `nonnull`, aligned and
    `dereferenceable` for the slot's size. It is not `readonly` or
    `noalias`, since the function may write the slot and another parameter
    may name it.
  - *An open scope's frame.* Once a scope is open, any slot of its frame
    may be read (above), and the frame is on a 16-byte boundary, since
    every frame is a multiple of 16 bytes placed where the one before it
    ended. The open scope says so with `llvm.assume` and its
    `dereferenceable` and `align` operand bundles, which LLVM's OCaml
    bindings cannot build (`llvm_stubs.c`).

    Both let LLVM read a slot ahead of a branch: a list reached through
    `this` or kept in `main`'s frame has its count and block loaded once
    before a loop that checks its indices, rather than after each check.
  - *What some runtime functions do.* `zane_out_of_range` and
    `zane_too_deep` stop the program, so they are cold and do not return;
    `zane_text_equal` only reads memory, so what LLVM read before a call to
    it still holds after.
  - *The list operations small enough to see.* A new list is the constant
    empty handle, and a `remove` or `swapRemove` moves the elements with
    LLVM's `memmove` or `memcpy` of the element's own stride, and lowers
    the count, in the function that removes. LLVM then sees exactly which
    bytes change, as it sees an element's address and a push's
    (`runtime/list.c` keeps the runtime's own forms of all three).
- **The passes.** `lib/codegen/passes.ml` names what LLVM runs over the
  module. An unoptimized build and tier 0 run `Passes.unoptimized`
  ([`optimization.md`](optimization.md) O12). An optimized build and tier 1
  run `Passes.optimized`, LLVM's `default<O2>` with two passes added. Each
  runs jump threading where it still sees each `elif`
  as written: `core`'s `elif` branches on `~this and condition`, where
  `this` is what the `if` before it branched on, so each way into the
  `elif` already decides that half. Jump threading sends the `if`'s body
  straight past the `elif` and the other way to the condition alone, which
  is one chain, as C's `else if` is. Once the CFG simplifier has made a
  cheap `if` body a `select`, both bodies' work runs on every pass round a
  loop instead. The unoptimized passes therefore merge blocks without
  making selects before they thread, and the optimized ones thread at the
  end of `-O2`'s first function simplification, once each function's
  locals are in registers and before the inliner's passes run. Promoting
  the locals in a pass of their own ahead of `-O2` would also do, but
  leaves `-O2` a different order of values to allocate registers for,
  which cost tier 1 of `tests/perf` `floats` 2.7%.

  The other added pass is inductive range check elimination (IRCE), run
  where `-O2` has just rotated each loop and
  hoisted what it reads, ahead of the passes that would turn an index check
  into an exit test IRCE no longer recognizes.
  `lib/codegen/gen/o2_pipeline.sh` writes the pipeline out at build time
  from the `opt` beside the LLVM the compiler is built against, so it
  tracks that LLVM's `-O2`. IRCE splits a loop whose element reads and
  writes are checked into the iterations its checks may fail on and a main
  loop between them that it has proved needs none. The split costs each
  entry to the loop a few dozen instructions, which a short loop does not
  earn back, so IRCE runs only on a loop LLVM is told goes round at least
  64 times for each entry (`Passes.llvm_options`). Codegen says which loops
  those are: a `repeat` that no other loop holds, that holds no loop, spawn,
  join, `return` or call back into its own function, that nothing leaves
  early, and that reads or writes an element, is emitted twice (`Emit.versioned`) in an optimized build and in
  both tiers of a tiered one, which emit the same module
  ([`tiers.md`](tiers.md) T3); a plain build, whose passes have no use for the
  copies, emits it once. A count of at least 16 runs
  the copy whose branch weights say it goes round 1,000 times; a smaller
  one runs the copy said to go round 4 times, which IRCE leaves alone. A
  list's count is loaded with the range `[0, 2^63)`, which IRCE's bounds
  need.

  The same options start every function on a 64-byte line
  (`-align-all-functions=6`), where LLVM would start it on 16 bytes. Which
  branches share a predictor's entries depends on where they lie, so with
  16-byte starts a change that only resized code before a function moved
  its branches into new conflicts: an unchanged loop of `tests/perf`
  `copies` mispredicted 40% more after an edit to other functions, and 64-byte
  starts made both layouts mispredict as the first had.
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
