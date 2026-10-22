# Runtime call caching (`--memoize`), measured

An experiment for [zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262).
`--memoize` remembers calls while the program runs, for the functions
`lib/cgt/memo.ml` picks. A function is picked when it reaches no state and no
capability, takes and returns only scalars, and calls back into its own cycle
of calls at least twice. In an optimized build it must also still be called
after `-O2` has run without the cache. `lib/codegen/emit.ml` (`memo`) emits a
gate, a lookup and two copies of each picked function. A function stops
looking after its lookups have cost 128 calls more than its hits saved.

A loop that calls a picked function from outside its recursion runs in two
versions, chosen once before the loop. If every dispatcher it calls has
stopped looking, the loop runs as written, calling the plain copies, so
nothing in it checks a dispatcher. Otherwise a copy that calls through the
dispatchers runs, and before each round it checks whether they have all
stopped. If they have, it hands the rounds that are left to the first
version.

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
(`tests/perf/`) and every langbench program but `concscan` (which crashes
Valgrind in the base build too) came out unchanged: none of their functions
is picked, apart from one in `stress`, which got 0.25% faster plain and
1.07% faster optimized.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,672,108       1,028,577   -99.28%  True
binom         optimized         1     103,293,776         987,847   -99.04%  True
fib           plain             1      11,018,940         983,382   -91.08%  True
fib           optimized         1       8,439,712         951,546   -88.73%  True
overlap       plain             1      52,880,221       8,336,026   -84.24%  True
overlap       optimized         1      39,850,164       5,433,113   -86.37%  True
phase         plain             1      15,542,691      10,766,545   -30.73%  True
phase         optimized         1       7,405,833       7,386,661    -0.26%  True
random        plain             1      51,860,217      51,876,654    +0.03%  True
random        optimized         1      45,798,971      45,492,551    -0.67%  True
salted        plain             1      13,879,512      13,898,611    +0.14%  True
salted        optimized         1      11,384,297      11,399,659    +0.13%  True
shallow       plain             1      24,374,915      24,392,274    +0.07%  True
shallow       optimized         0         945,800         945,800    +0.00%  True
shallowin     plain             1      24,375,012      24,392,005    +0.07%  True
shallowin     optimized         1      14,146,895      13,562,228    -4.13%  True
split         plain             1      84,360,585      83,897,578    -0.55%  True
split         optimized         1      55,525,393      55,540,473    +0.03%  True
tree          plain             1      71,440,582      71,696,924    +0.36%  True
tree          optimized         1      51,420,427      51,729,369    +0.60%  True
tri           plain             1       5,104,270         980,088   -80.80%  True
tri           optimized         1       3,581,938         952,219   -73.42%  True
corefib       plain             1      11,039,266         999,371   -90.95%  True
corefib       optimized         1       8,452,792         964,616   -88.59%  True
```

Every row with no repeats is within +0.6%. That is the cost of the lookups
made before the function gives up, plus code placement, which Callgrind's
simple branch predictor is sensitive to. On hardware, `shallowin` (the worst
case: 300,000 calls from a loop, each doing little) measured a median of
4.58 ms against 4.45 ms plain and 3.74 ms against 4.09 ms optimized, over
150 runs. Both are runs dominated by process startup. `shallow` optimized has
no table at all, because without the cache LLVM folds the whole loop.

A program that spawns gets no tables: they are not yet safe to share
between threads.
