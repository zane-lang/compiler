# Experiments

Measurements and prototypes that informed the compiler's design. Each
directory is one experiment: what was tried, how it was measured, and what
came of it. Most prototypes ran behind environment switches that have since
been removed or made the default, so a script here reproduces its numbers only
on the commit its README names. The design documents in
[`../design/`](../design/) and the entries in
[`../optimizations.md`](../optimizations.md) are where the outcome lives;
these directories keep the evidence.

CI's nesting and file-size checks skip this directory.

## Layout

Every experiment follows the same shape, so a reader knows where to look:

| Path | Holds |
|---|---|
| `README.md` | The record: the question, the setup, each step's measurements, the outcome |
| `FINDINGS.md`, other `*.md` | Summaries or side studies that the README links to |
| scripts (`*.py`, `*.sh`, `run`) | Build, measure and compare; kept at the top so their usage lines stay short |
| `programs/` | The Zane (and Goose or C) programs measured, one package per directory |
| `results/` | Raw outputs the README quotes: `.txt`, `.tsv`, `.json` |

A new experiment copies that shape. Its directory name says what was measured,
not when; the README's first lines say which commit it ran on and whether its
switches still exist.

## Index

| Experiment | Question | Outcome |
|---|---|---|
| [`cross-package-optimization/`](cross-package-optimization/README.md) | What optimized builds gain from a dependency's bodies | Kept: C12 in [`separate-compilation.md`](../design/separate-compilation.md), O10 in [`optimization.md`](../design/optimization.md) |
| [`goose-comparison/`](goose-comparison/README.md) | Zane against Goose on allocation-heavy work | Finished; [`FINDINGS.md`](goose-comparison/FINDINGS.md) summarizes the memory model it ended with |
| [`langarena-vs-goose/`](langarena-vs-goose/README.md) | How far below C LangArena's Zane port can go | Open-ended log; per-step results in `results/`, Goose runs in [`goose-progress.md`](langarena-vs-goose/goose-progress.md) |
| [`lent-conversions/`](lent-conversions/README.md) | What lent conversions (lowering L11) gain a per-byte string loop | Kept |
| [`llvm-facts/`](llvm-facts/README.md) | A larger unroll budget, and facts LLVM is not told | Unroll budgets became defaults (see `unroll-thresholds/`); the rest removed |
| [`memo-gates/`](memo-gates/README.md) | Cheaper memo gates once a function stops looking | Both switches removed; memoization M3 records why |
| [`prefetch-reorder/`](prefetch-reorder/README.md) | Prefetching and reordering random memory access | C model, then `zanec`; interleaving ([`interleaving.md`](../design/interleaving.md)) |
| [`runtime-attrs/`](runtime-attrs/README.md) | The attributes the runtime's declarations give LLVM | Kept: `lib/codegen/runtime_facts.ml` |
| [`subject-regions/`](subject-regions/README.md) | Whether a context's regions can go without a lock | Kept: subject regions are the only design |
| [`tight-layouts/`](tight-layouts/README.md) | Whether dropping tail padding pays | The `niche` layout is the only one; switches removed |
| [`unroll-thresholds/`](unroll-thresholds/README.md) | The unroll budgets `Passes.llvm_options` sets | Kept: `-unroll-threshold=250`, `-unroll-partial-threshold=100` |

## Elsewhere

Some measurements live next to what they measured instead:

- [`../ambiguity/experiments.md`](../ambiguity/experiments.md): grammar changes
  measured for ambiguity, and ambiguities found and resolved.
- [`../memory-semantics-findings.md`](../memory-semantics-findings.md): the
  memory model probed with the programs in `tests/memory-probes/`.
- [`../design/memo-tables.md`](../design/memo-tables.md): the memo table
  layouts measured against the one memoization uses.
- [`../../dev/bench/`](../../dev/bench/): benchmark programs and harnesses that
  are still maintained and run against the current compiler.
