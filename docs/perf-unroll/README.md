# Unroll thresholds: measurements

`-unroll-threshold=250` and `-unroll-partial-threshold=100` in
`Passes.llvm_options` (the decision and the loops it wins on are in
[`design/lowering.md`](../design/lowering.md) §9, "The passes", and
[`optimizations.md`](../optimizations.md)). The choice came from
[`experiments/llvm-facts`](https://github.com/zane-lang/compiler/tree/experiment/llvm-facts/docs/experiments/llvm-facts)
(step 1 and step 5), which swept the budgets, and from the langbench `nbody`
loss at a partial budget of 150 ([`nbody.md`](nbody.md)).

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
borrows     optimized    -11.9%   -27.9%    +9.7%    +0.3%    +4.7%   24496>25648
depths      optimized     -0.3%    -0.2%    -0.2%    -0.1%    +3.2%   20016>20656
entities    optimized     -3.4%    -5.4%    -0.4%    +0.8%    +8.6%   25904>28144
floats      optimized     +0.2%    -0.1%    +8.5%    +0.4%    +7.3%   20976>22512
kept        optimized     -0.3%    -0.7%    -0.2%    +0.2%    +5.2%   19568>20592
kept        tiered        -5.2%    -7.9%    -0.1%    +0.4%    +8.3%    6907>7483
particles   optimized     -3.6%    -5.6%    +0.2%    +0.8%   +10.5%   25520>28208
paths       optimized    -42.8%   -24.6%   -72.1%    +0.2%    +4.1%   26352>27440
paths       tiered       -41.4%   -20.9%   -72.7%    +0.5%    +5.0%   10299>10811
removal     optimized     +1.1%    +1.1%    +0.0%    +0.4%    +5.5%   23216>24496
removal     tiered        +1.1%    +1.1%    +0.0%    +0.6%    +9.8%    7163>7867
repeats     optimized     -3.1%    -3.7%    -0.2%    +0.5%    +6.8%   19824>21168
repeats     tiered        -2.9%    -3.5%    -0.0%    +0.3%   +25.2%    6354>7958
returns     optimized    -10.0%    -4.4%   -39.8%    +0.3%    +4.4%   26480>27632
returns     tiered        -8.2%    -3.0%   -39.1%    +0.3%    +4.3%   10354>10802
```

Plain builds: `.text` is identical for every program, and the cycle counts
differ by at most the ±0.2% of branch-mispredict wobble, so the options are
given to LLVM only for optimized builds and tier 1.

## Langbench (the 10 of 16 programs the current compiler builds)

```
program     build        cycles    instr    mispr  I1 miss    .text          text B
binarytrees optimized     -0.0%    -0.0%    -0.0%    -0.1%    +1.6%   38960>39600
binarytrees tiered        +0.0%    -0.0%    -0.0%    +0.0%    +0.0%   22408>22408
entities    optimized     -8.6%   -25.8%    +0.0%    +0.1%    +2.6%   27312>28016
entities    tiered        -0.0%    -0.0%    -0.1%    -0.0%    +1.9%   10171>10363
fannkuch    optimized     -0.0%    -0.0%    -0.0%    +0.0%    +2.2%   29232>29872
fannkuch    tiered        -0.0%    -0.0%    -0.0%    -0.1%    +0.0%   12411>12411
listgrowth  optimized     -0.0%    -0.0%    -0.1%    +0.2%    +2.3%   27440>28080
listgrowth  tiered        -0.0%    -0.0%    -0.0%    +0.1%    +0.0%   10811>10811
mandelbrot  optimized     +0.1%    -0.1%    +1.6%    +0.5%    +5.4%   27056>28528
mandelbrot  tiered        -0.0%    -0.0%    -0.1%    +0.0%    +0.0%   10692>10692
nbody       optimized     +3.0%    +6.4%   -92.0%    +0.8%   +13.7%   30896>35120
nbody       tiered        -0.0%    -0.0%    -0.0%    +0.0%    +0.0%   13371>13371
primes      optimized     -0.1%    -0.2%    -0.2%    +0.2%   +11.3%    5120>5696
primes      tiered        -0.1%    -0.1%    -0.2%    +0.0%    +0.0%    5867>5867
startup     optimized     -0.1%    -0.2%    -0.2%    +0.2%   +11.3%    5120>5696
startup     tiered        -0.2%    -0.2%    -0.3%    -0.1%    +0.0%    3371>3371
treecopy    optimized     +0.0%    -0.0%    -0.0%    -0.2%    +1.9%   34032>34672
treecopy    tiered        -0.0%    -0.0%    -0.0%    -0.1%    +0.0%   17288>17288
```

`trialdiv`, `ntree`, `spectralnorm`, `allocfree`, `gameloop` and `particles`
do not build: the spec's langbench is ahead of this compiler's syntax and
`core` (parse errors, "is a reference type"). Tier 1 of the langbench programs
is unchanged because it holds nothing a loop budget touches. These programs are
30–130 lines each, with `core` and the runtime making up most of the `.text`.
The largest program available that runs is `tests/perf/stress` (837 lines),
in the first table: -0.1% cycles, `.text` +1.5%, I1 misses +2.6%.
`nbody`'s +3.0% is its pair loop running one to four times being unrolled
four times ([`nbody.md`](nbody.md)).

## Other settings (cycles against main; rows in `t250`, `after150`, `mc2`, `rt0` .tsv and their `lb-` twins)

| setting | paths | returns | borrows | kept (tier) | entities | particles | repeats | division | removal | floats | langbench nbody |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| full 250 only | -42.5% | -10.0% | +0.0% | +0.1% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% |
| **full 250 + partial 100 (this change)** | -42.8% | -10.0% | -11.9% | -5.2% | -3.4% | -3.6% | -3.1% | -0.0% | +1.1% | +0.2% | +3.0% |
| + partial 150 (first proposal) | -42.8% | -10.0% | -11.9% | -6.2% | -4.0% | -3.5% | -3.4% | -3.8% | +1.1% | +0.5% | +6.8% |
| 250/150, `-unroll-max-count=2` | -42.5% | -10.0% | +0.0% | +0.1% | -4.8% | -2.3% | -0.0% | -3.8% | +1.3% | +0.2% | +3.6% |
| 250/150, `-unroll-runtime=false` | -41.9% | -10.0% | +19.4% | -6.1% | +0.0% | +2.3% | -3.4% | +0.0% | +1.1% | +0.0% | +0.6% |

Compile time is unchanged by the budgets (below, measured at partial 150;
100 does less unrolling).

## Compile time (seconds, median of 5, container noise ±5–10%)

```
program                 build        main      new     change
stress                  --optimize   13.89s   13.93s   +0.3%
stress                  --tier-up     0.19s    0.21s  +10.6%   (noise: 0.02 s)
longChain               --optimize    1.71s    1.68s   -1.6%
longChain               --tier-up     1.61s    1.64s   +1.7%
wideSum                 --optimize    0.33s    0.33s   +1.2%
wideSum                 --tier-up     0.18s    0.21s  +12.8%   (noise: 0.03 s)
binarytrees (langbench) --optimize    0.64s    0.68s   +5.9%
binarytrees (langbench) --tier-up     0.07s    0.06s  -15.3%   (noise)
```
