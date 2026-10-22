# Runtime call caching (`--memoize`), measured

An experiment for [zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262).
`--memoize` remembers calls while the program runs, for the functions
`lib/cgt/memo.ml` picks. A function is picked when it reaches no state and no
capability, takes and returns only scalars, and calls back into its own cycle
of calls at least twice. In an optimized build it must also still be called
after `-O2` has run without the cache. `lib/codegen/emit.ml` (`memo`) emits a
gate, a lookup and two copies of each picked function. A function stops
looking after its lookups have cost 128 calls more than its hits saved.

    dev/bench/memo/run ZANEC OUTDIR programs/*        # these programs
    EXTRA="--package bench=… --package core=… --package math=…" \
      dev/bench/memo/run ZANEC OUTDIR LANGBENCH/bin/*  # langbench, with the size in an `arguments` file

`run` builds each program plain and optimized, without and with
`--memoize`, and reports Callgrind's estimated cycles, using
`tests/perf/run`'s formula and caches.

## Programs

| program | what its calls do |
|---|---|
| `fib`, `corefib`, `binom`, `tri` | repeat their arguments often: the case a cache is for |
| `overlap` | hits by accident: trees grown from consecutive seeds share subtrees |
| `phase` | a Fibonacci warm-up, then 20,000 small trees whose second argument never repeats |
| `salted`, `random`, `tree` | never repeat an argument |
| `split` | repeat a few leaves |
| `shallow`, `shallowin` | worst case: a two-level recursion called 300,000 times from a loop, every argument new |

## Results

Estimated cycles under Callgrind, x86-64 container, 2026-10-22. `memoized`
is how many functions got a table. The repository's own perf programs
(`tests/perf/`) and every langbench program came out unchanged: none of their
functions is picked, apart from one in `stress`, which got 0.3-0.6% faster.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,674,142       1,030,611   -99.28%  True
binom         optimized         1     103,295,903         989,964   -99.04%  True
fib           plain             1      11,021,069         985,511   -91.06%  True
fib           optimized         1       8,441,732         953,626   -88.70%  True
overlap       plain             1      52,882,237       8,236,142   -84.43%  True
overlap       optimized         1      39,851,735       5,422,699   -86.39%  True
phase         plain             1      15,544,641      10,847,301   -30.22%  True
phase         optimized         1       7,407,580       7,887,981    +6.49%  True
random        plain             1      51,862,162      52,377,597    +0.99%  True
random        optimized         1      45,800,746      45,106,530    -1.52%  True
salted        plain             1      13,881,535      13,900,644    +0.14%  True
salted        optimized         1      11,385,940      11,401,262    +0.13%  True
shallow       plain             1      24,376,671      25,592,716    +4.99%  True
shallow       optimized         0         947,301         947,301    +0.00%  True
split         plain             1      84,362,559      83,908,770    -0.54%  True
split         optimized         1      55,527,154      55,396,275    -0.24%  True
tree          plain             1      71,443,009      71,590,368    +0.21%  True
tree          optimized         1      51,422,063      55,823,851    +8.56%  True
tri           plain             1       5,106,399         982,173   -80.77%  True
tri           optimized         1       3,583,988         954,269   -73.37%  True
shallowin     plain             1      24,377,145      25,593,070    +4.99%  True
shallowin     optimized         1      14,148,418      15,062,981    +6.46%  True
corefib       plain             1      11,040,926       1,000,977   -90.93%  True
corefib       optimized         1       8,454,495         966,319   -88.57%  True
```

Notes on the misses:

- With no repeats, a function costs a fixed few dozen thousand cycles, for
  the lookups before it gives up, and then runs as its plain copy, whose
  code is the original function's.
- `tree` optimized (+8.5%) is code placement, not work. Its instruction
  count is unchanged, and the cycles are mispredicts in Callgrind's simple
  branch predictor. A build that has the code but never looks up shows the
  same +8.1%. On hardware it is no slower: a median of 110.8 ms against
  113.5 ms for the base, 25 runs at size 60,000. `random` optimized (-1.5%)
  is the same effect going the other way.
- `shallow`/`shallowin` is what is left: every call from outside the
  recursion goes through a gate, one load and one compare. When each call
  does little, that shows: +5% plain and +6.5% optimized under Callgrind. On
  hardware the optimized build is level (5.32 ms against 5.33 ms) and the
  plain one is slower (6.74 ms against 5.88 ms). `shallow` optimized has no
  table at all, because without the cache LLVM folds the whole loop.
- `phase` optimized (+6.5%, of which +0.8% is placement) is the one real
  loss from lookups. After the warm-up, each small tree still hits often
  enough to keep its table, but `-O2` makes those subtrees so cheap that
  the hits save less than the lookups cost. In the plain build the same
  program is 30% faster. `random` plain (+1.0%, of which +0.3% is
  placement) is the lookups made before it gave up.
