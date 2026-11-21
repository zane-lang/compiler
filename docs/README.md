# Documentation

What each document here is for. The [spec](https://github.com/zane-lang/spec)
defines the language; these describe how this compiler implements it.

- [`development.md`](development.md) and [`releasing.md`](releasing.md): how
  to set up, build and test the compiler, and how releases are published.
- [`spec-divergences.md`](spec-divergences.md): where the compiler does
  something other than the spec says, or settles what the spec leaves open.
  Read it before relying on a spec section.
- [`optimizations.md`](optimizations.md): every optimization the compiler
  applies to the programs it builds, one entry each, with the builds that get
  it and the design section that explains it. Add an entry with the change
  that adds the optimization.
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
- [`design/comptime.md`](design/comptime.md): calls marked `comptime`,
  which every build evaluates between lowering and stage 5, to completion
  and outside stage 5's budgets: what is checked, how a marked call is
  lifted, and what its evaluation may read (K1…).
- [`design/tiers.md`](design/tiers.md): tiered builds, as `zane run` and
  `zane test` make them: a program starts unoptimized and moves to optimized
  code while it runs (T1…).
- [`design/memoization.md`](design/memoization.md): the calls remembered
  while the program runs, which functions get a table, and how a function
  stops looking when looking does not pay (M1…).
- [`design/memo-tables.md`](design/memo-tables.md): the table layouts
  measured against the layout memoization uses, and why each lost.
- [`design/interleaving.md`](design/interleaving.md): built, experimental:
  running a loop's independent walks W at a time, which loops qualify and
  why, retirement in iteration order, the size gate, and what the first
  version builds (I1…I9).
- [`design/generics.md`](design/generics.md): which package a generic instance
  belongs to and which symbol name it gets. A follow-on to `semantics.md` D12 and
  `lowering.md` L4.
- [`design/symbols.md`](design/symbols.md): the symbol name that every type, verb and variable
  gets in the IR and the binary.
- [`design/separate-compilation.md`](design/separate-compilation.md): one
  object per package, the `!` placeholder and its stamp, and linking a
  program against a dependency's prebuilt objects (C1…).
- [`design/platforms.md`](design/platforms.md): the targets the compiler
  builds for, how well each is supported, and what building for them may
  need.
- [`design/ffi.md`](design/ffi.md): the C interface: compiling a package's
  C with a clang of the compiler's own LLVM, checking foreign verbs, calling
  C through generated glue, and folding C by interpreting its IR (F1…).

## Experiments and audits

- [`experiments/README.md`](experiments/README.md): every measurement and
  prototype that informed a design decision, one directory each with its
  scripts, programs and raw results, and what came of it.
- [`audit/`](audit/): the October 2026 audit: the report
  ([`2026-10-17-report.md`](audit/2026-10-17-report.md)), the working notes
  behind it, and the remediation plan.

## Ambiguity

[`ambiguity/README.md`](ambiguity/README.md) is the index: why the grammar
must stay provably unambiguous, and which of its five documents answers what.
