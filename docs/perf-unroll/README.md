# Unroll thresholds: measurements

`-unroll-threshold=250` and `-unroll-partial-threshold=150` in
`Passes.llvm_options` (the decision and the loops it wins on are in
[`design/lowering.md`](../design/lowering.md) §9, "The passes", and
[`optimizations.md`](../optimizations.md)). The choice came from
[`experiments/llvm-facts`](https://github.com/zane-lang/compiler/tree/experiment/llvm-facts/docs/experiments/llvm-facts)
(step 1 and step 5), which swept the budgets.

`perf.py ZANEC LABEL` measures every `tests/perf` program optimized, tiered
and plain with `tests/perf/run`'s own build and Callgrind code and writes
`LABEL.tsv`: estimated cycles, instructions, mispredicted branches,
instruction-cache (I1) misses and `.text` bytes (the executable's, or tier 1's
library for tiered). `langbench.py ZANEC LABEL LANGBENCH CORE` does the same
for the spec repository's langbench programs, optimized and tiered, at 1/50
of langbench's size (sizes under 1000 as they are). `compare.py BEFORE AFTER`
prints the tables; `compile_time.py` times `--optimize` and `--tier-up`
builds (median of five, the two compilers alternating). `before*.tsv` is
`main` at 90ebb2b, `after*.tsv` this change. Counts measure work, not time:
Callgrind does not model store forwarding or any out-of-order effect, and its
predictor has no history, so a mispredict win overstates what hardware gains.

## tests/perf, optimized and tiered (rows moving at least 0.3%)

```
program     build        cycles    instr    mispr  I1 miss    .text          text B
borrows     optimized    -11.9%   -27.9%    +9.7%    +0.3%    +5.2%   24496>25776
depths      optimized     -0.3%    -0.1%    -0.0%    -0.1%    +3.8%   20016>20784
division    optimized     -3.8%    +0.0%   -43.1%    +0.1%    +0.7%  171248>172528
entities    optimized     -4.0%    -6.4%    -0.4%    +1.8%   +14.6%   25904>29680
floats      optimized     +0.5%    -0.2%   +20.2%    +1.3%   +12.5%   20976>23600
kept        optimized     -0.2%    -0.5%    -0.0%    +0.2%    +5.9%   19568>20720
kept        tiered        -6.2%    -9.4%    +0.0%    +1.0%   +16.7%    6907>8059
particles   optimized     -3.5%    -5.3%    -0.0%    +1.1%   +12.3%   25520>28656
paths       optimized    -42.8%   -24.6%   -72.1%    +0.2%    +4.6%   26352>27568
paths       tiered       -41.3%   -20.9%   -72.7%    +0.3%    +5.0%   10299>10811
removal     optimized     +1.1%    +1.1%    +0.0%    +0.3%    +6.1%   23216>24624
removal     tiered        +1.1%    +1.1%    +0.0%    +0.5%    +9.8%    7163>7867
repeats     optimized     -3.4%    -4.1%    -0.1%    +0.7%   +11.3%   19824>22064
repeats     tiered        -3.3%    -3.9%    +0.0%    +0.6%   +55.7%    6354>9894
returns     optimized    -10.0%    -4.4%   -39.8%    +0.4%    +4.8%   26480>27760
returns     tiered        -8.2%    -3.0%   -39.1%    +0.2%    +4.3%   10354>10802
stress      optimized     -0.4%    -0.4%    -1.3%    +4.8%    +2.7%  405952>416768
```

Plain builds (`--build plain`) are byte-identical in every column: the options
are given to LLVM only for optimized builds and tier 1.

## Langbench (the 10 of 16 programs the current compiler builds)

```
program     build        cycles    instr    mispr  I1 miss    .text          text B
binarytrees optimized     -0.0%    -0.0%    -0.0%    -0.2%    +2.0%   38960>39728
binarytrees tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   22408>22408
entities    optimized     -8.6%   -25.8%    +0.2%    +0.1%    +3.0%   27312>28144
entities    tiered        +0.0%    -0.0%    +0.3%    +0.2%    +4.4%   10171>10619
fannkuch    optimized     -0.0%    -0.0%    -0.0%    +0.2%    +2.6%   29232>30000
fannkuch    tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   12411>12411
listgrowth  optimized     +0.0%    +0.0%    +0.2%    +0.1%    +2.8%   27440>28208
listgrowth  tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   10811>10811
mandelbrot  optimized     +0.5%    +0.1%    +4.0%    +1.2%    +9.7%   27056>29680
mandelbrot  tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   10692>10692
nbody       optimized     +6.8%   +10.4%   -92.0%    +1.2%   +15.7%   30896>35760
nbody       tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   13371>13371
primes      optimized     -0.0%    +0.0%    -0.0%    +0.2%   +11.3%    5120>5696
primes      tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%    5867>5867
startup     optimized     -0.0%    +0.0%    -0.0%    +0.2%   +11.3%    5120>5696
startup     tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%    3371>3371
treecopy    optimized     +0.0%    +0.0%    +0.0%    -0.2%    +2.3%   34032>34800
treecopy    tiered        +0.0%    +0.0%    +0.0%    +0.0%    +0.0%   17288>17288
```

`trialdiv`, `ntree`, `spectralnorm`, `allocfree`, `gameloop` and `particles`
do not build: the spec's langbench is ahead of this compiler's syntax and
`core` (parse errors, "is a reference type"). Tier 1 of the langbench programs
is unchanged because it holds nothing a loop budget touches. These programs are
30–130 lines each, with `core` and the runtime making up most of the `.text`.
The largest program available that runs is `tests/perf/stress` (837 lines),
in the first table: −0.4% cycles, `.text` +2.7%, I1 misses +4.8% (5755 → 6031).

## Compile time (seconds, median of 5, container noise ±5–10%)

```
```
