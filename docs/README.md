# Documentation

What each document here is for. The [spec](https://github.com/zane-lang/spec)
defines the language; these describe how this compiler implements it.

- [`spec-divergences.md`](spec-divergences.md): where the compiler does
  something other than the spec says, or decides what the spec leaves open.
  Read it before relying on a spec section.
- [`memory-semantics-findings.md`](memory-semantics-findings.md): the memory
  model probed with example programs (`tests/memory-probes/`): what holds,
  and the bugs and spec gaps found.

## Design

One document per stage, in the order the compiler runs them.

- [`design/stages.md`](design/stages.md): the six stages and the tree each one
  hands the next. Start here.
- [`design/desugaring.md`](design/desugaring.md): stage 2, everything the SST
  rewrites away from the CST.
- [`design/semantics.md`](design/semantics.md): stage 3, the passes that build
  the typed tree, and the decisions they follow (D1…).
- [`design/concepts-vs-primitives.md`](design/concepts-vs-primitives.md): the
  two intrinsic namespaces, and which side of lowering each is on. A follow-on
  to `semantics.md` §4.
- [`design/lowering.md`](design/lowering.md): stages 4 and 6, the
  code-generation tree, codegen and the runtime, and their decisions (L1…).
- [`design/optimization.md`](design/optimization.md): stage 5, what an
  optimized build evaluates at compile time and how, and its decisions
  (O1…).
- [`design/generics.md`](design/generics.md): which package a generic instance
  belongs to and what it is called. A follow-on to `semantics.md` D12 and
  `lowering.md` L4.
- [`design/symbols.md`](design/symbols.md): what every type, verb and variable
  is called in the IR and the binary.
- [`design/separate-compilation.md`](design/separate-compilation.md): one
  object per package, the `!` placeholder and its stamp, and linking a
  program against a dependency's prebuilt objects (C1…).
- [`design/platforms.md`](design/platforms.md): the targets the compiler
  builds for, how well each is supported, and what building for them may
  need.

## Ambiguity

[`ambiguity/README.md`](ambiguity/README.md) is the index: why the grammar
must stay provably unambiguous, and which of its five documents answers what.
