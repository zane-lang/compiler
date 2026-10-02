# Lowering: designing the CGT

> **Status: built through §8 step 8.** Stage 4 — lowering the TST to the
> code-generation tree — and the codegen that reads it follow this design, and
> every step §8 lists is built and tested. Each decision is numbered
> (**L1**…). §8 lists the order they were built in, and §9 the questions still
> open.

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

The bindings are LLVM's own, from `llvm/bindings/ocaml` in llvm-project,
which opam builds from each LLVM release as its `llvm` package. They are
tied to that release, and the compiler uses LLVM 19, the newest opam
packages. `dev/bin/bootstrap-toolchain` pins it; devbox provides LLVM 19
with its `llvm-config` and headers, and CI installs `llvm-19-dev`.

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

`Unit` has no storage, and a verb that returns it returns nothing. A value
struct of one member has that member's layout, so a struct around one
`@primitives$Int` is an `i64`, and an empty one has none. A distinct
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
| `--target TRIPLE` | compiles `--ll` and `--build` for the LLVM target `TRIPLE` instead of the host, and has the C compiler link for it |

`--kind library` refuses `--build`, since a library is not an executable.

`tests/codegen/` lowers and builds each fixture, runs it, and compares the
tree and what the program wrote against golden files. `tests/runtime/` compiles
the runtime with a C program of its own that calls it directly.

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
   backpointer (L5), and `float`. A reference-type subject and a swallowed
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

---

## 9. Open questions

- **How many scopes get an arena.** L8 gives every block that declares a local
  its own. For now only a block that hosts a reference-type local opens one,
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
- **Anchors as the runtime keeps them.** An anchor cell holds its host's
  address rather than a segmented offset, and a tether or backpointer holds
  a cell's index in one pool that grows by segments, where [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §4.1 has pages of
  cells named by segmented offsets. A forwarder retires with the identity
  it forwards to rather than at its former source scope's drain, which is
  later but still after every guest that could name it. Nothing a program
  does can tell these apart.
- **A floated host outlives its owner.** A variant payload's anchored
  occupant floats ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §2.8.1) into a block of the program's own
  region, open until the program ends, rather than until its owner scope
  drains, and the blocks it owns move there too, as does anything later
  stored into it. A host floated in a spawned call goes there as well. That
  region goes with the program, unchecked. A host has no destructor, so the
  longer life is not observable.
- **Each scope's dynamic region.** A scope's blocks are in a region of its
  own, as [`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §3.1–3.2 has it: chunks of its own, a bump frontier, and
  a stack of returned blocks per size and alignment, all given back at its
  drain. A list's block doubles from 128 bytes (§3.6): into a returned block
  of that size, in place when it is last at the frontier, or else into new
  bytes. Where the runtime departs from the spec:
  - A block is placed where its value is made, which is the innermost
    scope, and moves into the region of the scope that holds the place the
    value arrives in: a slot, an overwritten place, a list's element. The
    spec builds a fresh value in its destination directly (§3.7); here a
    value built for an older scope's place is moved there once. A list's
    growth goes to the region that holds the list.
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
  - A value that owns a block is held in its scope's arena like a host,
    and so is a fresh host or value that nothing keeps, such as a result
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
  copied into a slot the block reserved, its anchors follow it, and its
  blocks move into the block's region, as any value's do where it arrives.
  The context then goes back to a pool for the next call. The chunk map names
  each chunk's context along with its index or scope.

  A context is its own thread's alone until it spawns. While a call it
  spawned is out, that call can reach its storage: a `mut` subject that owns
  blocks is written where it lives, in the spawner's region. So while any is
  out, the context's scopes and regions change under its lock, and another
  thread always takes that lock for a context it reaches. Anchor cells are
  kept in segments that stay where they are, and are made and retired under
  a lock. The spec leaves all of this to the implementation.
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
- **A write through a host from spawned work.** A spawned `mut` call whose
  subject is reached through a host -- a member of a reference-type
  instance, of what a guest names, or an element of a list -- is the one
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
- **Snapshots.** A value read through a host into a fresh binding -- a
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
- **A host lent to a running spawn.** The spawning block may not write a
  host it lent a spawn that may still be reading it; the checker rejects
  that write ([`spec-divergences.md`](../spec-divergences.md) §14), so the
  only writes that race a reader are spawned write-backs, which the
  snapshots above cover.
- **Where a spawned call is waited for.** Only a spawned call bound by a
  `let` is waited for where its local is read ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §3.2). One
  read where it is written -- an operand, an argument, a value assigned to a
  local that already exists -- is waited for at once, so lowering calls it
  there. Only timing tells the two apart.
- **A spawned call that can abort or exit.** Its frame holds the call's
  whole outcome (L12), which comes home into a slot laid out for it: the
  result's hosts and blocks under the done tag, the abort value's under the
  aborted one. The call settles once, on the spawning thread, where it is
  first read or where its block ends
  ([`spec-divergences.md`](../spec-divergences.md) §13). A flag the spawn sets
  says whether it has. An abort takes the abort value out of the slot and
  runs the handler written at the spawn, lowered where it settles but in
  the context of the spawn, so its `abort`, `return` and exit go where they
  would from there; its `resolve` puts the result in the slot. An exit ends
  the run of the block the spawn is in.
- **An abort value no binder names is held.** A handler without a binder,
  such as `??`'s, still holds the abort value in its own scope when it is a
  host or owns a block, so the handler's drain ends it.
- **A value parameter is borrowed.** A value that owns a block is copied
  whole where it is stored from a place ([`memory.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/memory.md) §2.3), and passed
  as it is where it is only read: a value parameter is read-only (§2.9), so
  the caller keeps it, and a fresh one is held in the caller's scope first.
  A callee that stores its parameter copies it.
- **A case read of a host.** What a case read gives is its payload, which
  the variant keeps, or what its handler resolves, which is fresh. So a read
  whose type is a host, or a value that owns a block, gives an address: the
  payload's, or that of a slot reserved in the reading scope before the read,
  which the handler's `resolve` fills. Either way what it gives has one
  owner, and the drain ends the slot.
- **A literal's bytes stay where the program keeps them.** A string view's
  handle points into the dynamic region ([`types.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/types.md) §2.7). A literal's
  points at the bytes the program embeds instead, and the handle also holds
  the room of the block it owns, which is 0 for a literal's, so a literal
  takes no block and returns none. Like any reference type's instance, the
  view starts with its backpointer.
- **A `this` address across a call that moves.** L10 resolves `this` once per
  call. That is safe while nothing in the call relocates what it names, which
  the single-writer rule ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/concurrency.md) §4.3) should
  guarantee. A guest subject is resolved once, at the call; a call inside
  the method that moves the subject's host would leave the address stale,
  which nothing checks yet.
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
  parameter cannot be written, so nothing observes the difference. A
  reference-type result is returned the same way, and arrives where the
  caller hosts it: its anchors follow it there, and its blocks move into
  that scope's region. A `mut` subject, a
  reference-type subject and a swallowed argument are passed by address.
- **An outcome as a sum, for now.** L12 returns a tag and has the caller
  pass slots for the result and the abort value. Until results are written
  into destinations, a function that can abort or exit returns a
  sum of three cases instead: done with its result, aborted with its abort
  value, and exited. A function that can only finish returns its result as
  before. An exit ends the run of the block the call is written in
  ([`spec-divergences.md`](../spec-divergences.md) §11), so each run of a block
  argument has a label to leave.
- **A 64-bit target.** Codegen sizes a sum's payload room assuming 8-byte
  pointers and C struct layout, which holds for x86-64 and AArch64. Another
  target reads the sizes from LLVM's data layout.
- **Integer division by zero.** The spec leaves it open
  ([`spec-divergences.md`](../spec-divergences.md) §10). Until it says, the
  program stops: what it wrote so far is kept, the runtime writes `division by
  zero` to stderr, and the status is 1. The one other quotient an `i64` cannot
  hold, the most negative value over `-1`, wraps, as `+` and `*` do.
- **An index out of range.** The spec leaves it open ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md)
  §5.2, [`spec-divergences.md`](../spec-divergences.md) §16). Until it says, the program stops as it does at a division by zero:
  what it wrote so far is kept, the runtime writes `index out of range` to
  stderr, and the status is 1.
- **A type argument passes nothing.** A generic verb is lowered once per
  instance the TST checked ([`semantics.md`](semantics.md) D12), with a
  symbol of its own, and a type written where a value goes has already
  picked the instance, so the call passes nothing for it.
- **What does not lower yet.** Some programs the TST accepts, lowering
  refuses, with an error that says "does not … yet" at the construct:
  - a package constant, except a lambda-variable;
  - `@primitives$Array`: its type, an array literal, and its elements;
  - an `@primitives$I32` literal, since only `Int` and `I64` embed one;
  - a field-constructor call that leaves out a field with a default
    ([`types.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/types.md)
    §3.3);
  - a `spawn` of a call to an intrinsic, or to a verb that is expanded where
    it is called, and one bound to a local of another type than the call
    returns;
  - reading a boxed member of, or moving a host out of, a value no place
    holds, such as a call's result.
