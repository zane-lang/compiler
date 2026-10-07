# Cross-package optimization: implementation and measurements

Tested on 2026-10-07. Optimized builds now retain reachable stamped
dependency bodies for both the CGT evaluator and LLVM. LLVM receives them
with `available_externally` linkage, so it can inline them while residual
calls still link against the dependency object. Unoptimized builds keep
declarations only. The implementation is C12 in
[`separate-compilation.md`](separate-compilation.md) and O10 in
[`optimization.md`](optimization.md).

## Runtime results

These compare the same Zane programs before and after this change, rather
than against another language's timings on another machine. Each value is
a median of three runs at the full sizes in the pinned langbench metadata.
Before and after runs alternated; the final timing pass ran without another
benchmark job. Every run matched langbench's expected output. Small-size
checks also passed for every program. Both versions linked the same separately
compiled, optimized `core` object.

| Workload | Argument | Before | After | Speedup |
|---|---:|---:|---:|---:|
| trialdiv | 10000000 | 4.554 s | 1.525 s | 2.99× |
| binarytrees | 16 | 13.487 s | 13.208 s | 1.02× |
| mandelbrot | 3000 | 4.893 s | 0.644 s | 7.59× |
| fannkuch | 10 | 2.476 s | 1.300 s | 1.90× |
| entities | 3000000 | 2.489 s | 1.571 s | 1.58× |
| listgrowth | 2000000 | 1.344 s | 0.852 s | 1.58× |
| ntree | 10 | 4.856 s | 4.471 s | 1.09× |
| treecopy | 18 | 1.354 s | 1.375 s | 0.99× |

The binarytrees row above uses the original recursive value types at the
pinned spec commit. The reference-node correction is measured separately
below, so the compiler and representation changes can be distinguished.

The arithmetic-heavy Mandelbrot workload benefits most. Trial division,
Fannkuch, entity scanning and list growth also improve. Binary trees and
deep copying remain essentially unchanged: removing package call overhead
does not remove their allocation, copying and traversal work. The small
difference in tree copying is within the observed timing variation.

The fixed-bound prime sieve also produces the correct output, but remains
partly evaluated at runtime. Its execution is too short for useful timing
at the process level in this environment, so it has no speedup claim here.
Its single measured build took approximately 0.52 s before and 1.06 s after;
that is a build-time cost, not a runtime win. The other single measured
builds were approximately 0.4–0.7 s in both versions. These compile timings
are observations from one build each, not statistically established results.

## Binary-tree representation correction

The benchmark now uses owning reference nodes, matching the pointer-based
trees in its C++ and Rust implementations. `Tree` is a reference variant,
`Pair` is a reference struct, and the parent constructor takes ownership of
its two children. Tree checking continues to borrow its argument.
The optimized CGT now uses `take` for each child in the constructor, replacing
the original `copy` operations on completed subtrees. `treecopy` retains its
deliberate value-copy workload.

The corrected source is spec commit
[`a79a5ea6c8f379d831ca3d4822290e9d562f1a94`](https://github.com/zane-lang/spec/commit/a79a5ea6c8f379d831ca3d4822290e9d562f1a94).
On the same host and toolchain as above, a separate three-round alternating
timing pass at depth 16 produced these medians:

| Representation and compiler | Runtime |
|---|---:|
| Original values, changed compiler | 13.138 s |
| Owning references, baseline compiler | 2.998 s |
| Owning references, changed compiler | 2.902 s |
| C++ `unique_ptr`, Clang 19.1.1 `-std=c++20 -O2` | 0.317 s |

Changing the representation improves the changed compiler's runtime by
4.53×. Cross-package optimization alone improves the reference version by
about 1.03×, a small difference relative to the run variation. Zane still
takes about 9.15× as long as this C++ implementation; allocation and
scope-escape relocation remain possible optimization targets. Removing
subtree copies does not eliminate all tree-construction overhead.

Every variant matched the expected output at depths 0, 6 and 10, and every
timed run matched at depth 16. Both Zane compiler versions linked the exact
same separately compiled core object. Raw samples are in
[`binarytrees-reference-results.json`](binarytrees-reference-results.json).
The spec's pinned multi-language results remain historical results from the
old value-based source; its README, explanations and generated page identify
that distinction rather than combining timings from different runs.

## Environment and source pins

- CPU reported by the Linux container: AMD EPYC 9V74, 9 visible CPUs.
- OCaml 5.3.0; LLVM and Clang 19.1.1; `--optimize` uses LLVM `default<O2>`.
- Baseline compiler: `fe056e2f11e5ed34c9e659dc2e31556b241bdb61`.
- Changed compiler: `f8d5bc71c05c414874e5a0e8e1ad642bd950d287`.
- Spec and langbench: `baa2afaeb77a4a9b97ac58e6a39d20e1aa4b4f3d`.
- Core: `97beb743aa7e0cfec7b7b5afeb0df53fc97f9791`.
- The same core object used the stamp `v0.0%0123456789abcdef%` in both builds.

The raw runtime samples are in
[`cross-package-optimization-results.json`](cross-package-optimization-results.json).

## Reproduction

Build the baseline compiler and the changed compiler with the same toolchain.
Check out the spec and core at the pins above. First build core once with the
baseline compiler, then link that exact object into both callers. For example,
with `spec/` and `core/` in the current directory and `zanec` selecting one
of the two compiler builds:

```sh
zanec --kind library --optimize --object core.o \
  --package 'v0.0%0123456789abcdef%core=core/lib/core'

zanec --build mandelbrot --optimize --link core.o \
  --package mandelbrot=spec/langbench/bin/mandelbrot \
  --package bench=spec/langbench/lib/bench \
  --package 'v0.0%0123456789abcdef%core=core/lib/core' \
  --import 'mandelbrot:core=v0.0%0123456789abcdef%core' \
  --import mandelbrot:bench=bench \
  --import 'bench:core=v0.0%0123456789abcdef%core'

./mandelbrot 3000
```

Repeat for each directory under `langbench/bin/`, replacing the root package
name, its import mappings and argument with those in `langbench/tests.py`.
Compare output at both its small check size and its full size before timing.

## Validation and remaining limits

- Passed `dune runtest tests/parser tests/semantics tests/codegen tests/runtime tests/objects tests/unit`.
- Passed all 42 parser acceptance tests (`python3 -m unittest tests.parser.syntax_test -v`).
- Passed the five new cross-package regression tests, including optimized
  ELF, Windows COFF and ARM64 Mach-O object generation. Windows and macOS
  objects were inspected, rather than executed on those operating systems.
- The new tests link optimized and unoptimized callers against the same
  unoptimized dependency; preserve output order from a folded library call;
  exercise mutation, abort handlers, recursion, package constants and named
  lambdas; and cover transitive imports and two versions with different layouts.
- LLVM text shows the runtime arithmetic wrappers being inlined. Symbol
  inspection shows no duplicate ordinary dependency definitions in the
  caller's object and verifies that residual recursion still uses the library.
- File-size and whitespace checks pass. The file-size check reports the
  pre-existing warning for `lib/cgt/lower.ml`; that file is unchanged.

Importing bodies does not force LLVM to inline every function. Evaluator
budgets, constant materialization and alias tracking keep their existing
limits. Counts of loops across the whole optimized CGT now include imported
bodies, so raw before/after loop counts have different inventories and
should not be treated as a folding score. Dependency source must still match
its linked object, under the compiler and commit pins the package system
already requires. No PR was opened for this branch.
