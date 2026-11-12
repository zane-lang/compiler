# LLVM facts

How much faster zanec's code gets from (a) a larger partial-unroll budget in
LLVM and (b) telling LLVM facts it is not told today: finer alias classes,
`nsw` on arithmetic, and attributes on Zane's own functions. Each idea sits
behind an environment switch read by `zanec` at compile time; with none set
the build is `main`'s.

**Measuring.** `measure.py LABEL` builds every program in `tests/perf/`
optimized and tiered with the switches in the environment, using
`tests/perf/run`'s own build-and-measure code (Callgrind, fixed caches,
estimated cycles = Ir + 10·L1 + 100·LL + 20·mispredicts), and writes
`results/LABEL.tsv` with cycles, instructions, mispredicts and `.text`
bytes (the executable's for optimized, the tier-1 library's for tiered).
`compare.py BASE LABEL…` prints the tables below. Counts measure work, not
time: Callgrind does not model store forwarding, unaligned-access penalties
or any out-of-order effect.

Run in a cloud container with the pixi environment (LLVM 21.1.8), from
`main` at 90ebb2b.

| switch | what it does |
| --- | --- |
| `ZANE_UNROLL_PARTIAL=n` | passes `-unroll-partial-threshold=n` to LLVM |
| `ZANE_UNROLL_THRESHOLD=n` | passes `-unroll-threshold=n` |
| `ZANE_UNROLL_RUNTIME_COUNT=n` | passes `-unroll-max-count=n` |
| `ZANE_NSW=1` | `nsw` on the program's integer add/mul/negate (**unsound**: an upper bound) |

## What remains

- Steps 1–5 as planned.
