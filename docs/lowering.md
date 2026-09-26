# Designing the CGT

> **Status: design.** Stage 4 — lowering the TST to the code-generation tree —
> and the codegen that reads it follow this design once they are built. Each
> decision is numbered (**L1**…). §8 lists the order they are built in, and §9
> the questions still open.

The **CGT** is the one input codegen reads ([`stages.md`](stages.md)). The TST
says what a program means, in the language's own terms: calls to overloads,
concepts, block arguments, handlers, hosts and guests. The CGT says what the
machine does: functions over primitive storage, with every allocation, copy,
move, guest and death written out. Lowering is the only stage that turns one
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

The bindings are tied to one LLVM release. The compiler uses LLVM 18, which
`dev/bin/bootstrap-toolchain` pins and finds as `llvm-config-18`, so the
system's `llvm-18-dev` is what they link against. The module's text is
LLVM's to print and changes between releases, so the tests read the CGT and
what a built program writes instead (§7).

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
- a struct of CGT types, in declaration order ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.3), with
  a `u32` backpointer first when it is a reference type;
- a sum: a tag and the widest case's bytes, aligned for every case;
- a tether: a `u32` segmented offset ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §4.2);
- a fixed array: `@primitives$Array<T, n>` is `n` elements of `T` inline, one
  after another at `T`'s stride (its size rounded up to its alignment), so it
  is statically sized and sits in a slot like a struct. Positions count from
  1 ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §5.1): element `i` is at
  byte offset `(i - 1) × stride`. What an index outside `1..n` does is not yet
  specified (`control-flow.md` §5.2), so lowering emits one runtime check for it and leaves its
  outcome to §9;
- a handle: the fixed-size part of a `List`, a `String` or a boxed member
  ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.6), whose payload lives in the dynamic region.

`Unit` has no storage, and a verb that returns it returns nothing. A distinct
type is its underlying type. A concept literal (`Integer_lit`, `Text_lit`) is
already gone, because the TST put an implicit constructor around every one
([`semantics.md`](semantics.md) D9); lowering turns `@primitives$Int(3)` into the constant `i64 3`.

Which members are boxed is lowering's decision too: every member on a cycle
of owning edges, and none other to start with ([`adt.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/adt.md) §4).

**L6. Calls name one function and pass places.** A CGT call names the
function it calls, so overload resolution, method lookup and the operator and
flip forms are gone. What each argument passes follows its parameter's mode
([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §2.9):

| Parameter | Passed as |
|---|---|
| value type (a borrow) | the address of the caller's slot, or the value itself when it is a scalar |
| `T`, a reference type (swallowed) | the address of the caller's slot, which keeps the value ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/lifetimes.md) §1.5) |
| `&T` (a guest) | a tether |
| `this` | the address of the subject's place, resolved once at the call |

A call site that passes a guest to a `T`-typed place, or mints one for an
`&T` parameter, does so with an explicit CGT operation (§3), not inside the
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
§4.1). Then it ends every hosting identity the scope still holds in bulk: it
returns the terminal anchors of those identities and the forwarders on the
scope's retirement stack ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §4.6), and unmaps
the scope's fixed-size and dynamic chunks together (`memory.md` §3.2). There is no
per-object pass at a drain; an object that dies earlier — overwritten, or
its container gone — is destroyed there, by its own `destroy` (L9). Lowering
may fold nested scopes into one arena when nothing observes the difference
([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1); the first version gives every block that
declares a local its own.

**L9. Storage operations are CGT nodes, each a call into the runtime or a few
instructions.** The set lowering writes, with the sections of [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md)
that define each:

- `slot` — a fixed-size slot in a scope's arena;
- `copy` — a value-type copy, recursive through its boxed payloads (§2.3);
- `move` — a rehost into a destination of the same type, with its anchor
  merge (§3.7, §4.5);
- `destroy` — a reference object's or a value's death, returning its dynamic
  blocks and retiring its anchor (§4.6);
- `float` — a contingent occupant's move into an anonymous host of the same
  owner (§2.8.1);
- `mint` — a tether taken from a place, creating its anchor if it has none
  (§4.3);
- `resolve` — a tether's address, through its anchor chain (§4.4).

Where the TST has a `Let`, an `Assign` or a hosting argument, lowering picks
from this list using what the move analysis already knows: whether the source
is a place or a fresh result, whether the destination is fresh, stable or
contingent, and whether the type is a value or a reference.

**L10. A place is an address inside a call, and a tether when stored.** A
field read, an element read or a `this` is an LLVM pointer for as long as one
expression needs it. Only `&` storage — a local, a field, an element, a
parameter — holds a tether. So a guest costs its anchor load where the spec
says it does, and nowhere else.

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
is the function's address. A call through a lambda-variable is an indirect
call with the same outcome convention.

---

## 5. Programs and packages

**L15. One LLVM module per program.** Lowering reads every package the TST
holds and writes one module: every instance, every non-generic verb, every
lifted lambda. A package does not reach codegen as a unit of its own.

**L16. Constants live in the program's scope.** A package constant is
evaluated once, in dependency order, into the arena of the outermost scope,
before `main` runs. A program's `main` becomes a function the runtime's C
`main` calls after setting itself up and before draining that scope.

---

## 6. The runtime is a C library

**L17. The runtime is written in C and linked with every program.** It owns
the chunk directory, the scope arenas and their size stacks, the global anchor
pool, the thread pool, and the few primitives a program cannot state in the
language: printing, `List` growth, `String` storage. Its interface is a small
set of C functions that CGT storage operations (L9) and intrinsic calls lower
to, so a change to how an arena works changes the runtime and nothing in the
compiler. It lives in `runtime/`, is built by `clang`, which already links
every program, and is tested in C on its own.

C because it adds no toolchain beside the LLVM the compiler already uses, and
because an arena and an anchor pool are exactly the kind of
code C states without ceremony.

---

## 7. How it is built, and how to look at it

Lowering lives in `lib/cgt/`, beside `lib/tst/`: `nodes.ml` for the tree,
`lower.ml` for the TST → CGT walk, `to_tree_graph.ml` to render it. Codegen
lives in `lib/codegen/`: `emit.ml` builds the module through the bindings,
and `build.ml` writes the object file and links it with the runtime. The
runtime's source, `runtime/zane.c`, is compiled into the compiler as a
string, so a build needs nothing beside the compiler and a C compiler
(`clang`, or `ZANE_CC`).

Lowering starts at the root package's `main` and lowers each verb the first
time a call reaches it, so a program's unused declarations never need to
lower. Whatever it cannot handle yet it refuses with a diagnostic at that
node, never by lowering it wrongly.

The binary takes the same `--package` flags as the semantic views:

| Flag | Does |
|---|---|
| `--cgt` | prints the code-generation tree |
| `--ll` | prints the LLVM module |
| `--build OUT` | builds the program into the executable `OUT` |

`test/codegen/` lowers and builds each fixture, runs it, and compares the
tree and what the program wrote against golden files.

The first version runs no optimization passes (stage 5), so an unoptimized
build is the whole pipeline from the start.

---

## 8. The order it is built in

Each step is one PR, ends with programs that run, and keeps every earlier
test passing.

1. **This design**, and `concepts-vs-primitives.md` brought in line with it.
2. **Scalars and calls.** First a program that prints a string literal
   through `@program$console`: the CGT, codegen, the runtime and the test
   that builds and runs it. Then lowering for `Int`,
   `Float` and `Bool` arithmetic, functions, returns, and `branch`/`repeat`
   expanded from `core`'s `if` and `to`. Codegen and a runtime that can print
   an `Int`. A test that builds and runs a program.
3. **Values.** Value structs and sums: layout, copies, fields, `match`.
4. **Aborts and exits.** The outcome tag, handlers, `resolve`, `guard`.
5. **Reference types.** Arenas, hosting, moves, destruction, `float`.
6. **Guests.** The anchor pool, `mint`, `resolve`, and anchor merges.
7. **Handles.** `String`, `List`, and boxed members.
8. **`spawn`.** The thread pool, futures, and the water tower.

---

## 9. Open questions

- **How many scopes get an arena.** L8 gives every block that declares a local
  its own. Folding them is allowed and saves the most in loops; which ones to
  fold is left to measurement once step 5 runs.
- **A `this` address across a call that moves.** L10 resolves `this` once per
  call. That is safe while nothing in the call relocates what it names, which
  the single-writer rule ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §4.3) should
  guarantee; step 5 confirms it or resolves again after each call that could.
- **Where the exit check lives.** The spec rejects an exiting verb called from
  a caller that must produce a value ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §4.2).
  Semantics does not check it yet; step 4 adds the check there, since lowering
  reports nothing.
- **Which LLVM.** The bindings use the system's LLVM 18 (L2), which CI
  installs from apt. `devbox.json` still lists LLVM 21, which provides no
  `llvm-config` and nothing the bindings use; moving devbox to a release the
  bindings cover would make the shell self-contained.
- **String escapes.** The spec names none, and the lexer keeps a backslash
  with the character after it. Lowering decodes `\n`, `\t`, `\r` and `\0`, and
  any other pair stands for its second character, until the spec says.
- **An index out of range.** The spec leaves it open ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md)
  §5.2). Until it says, the check L5 emits traps.
