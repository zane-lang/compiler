# Runtime call caching (`--memoize`), measured

An experiment for [zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262).
`--memoize` remembers calls while the program runs, for the functions
`lib/cgt/memo.ml` picks. A function is picked when:

- it reaches no state and no capability;
- every argument and its result is a fixed-size value (scalars, and
  structs, enums, variants and arrays of them, holding no handle or
  address), with at most 64 bytes of arguments and 64 of result;
- it calls back into its own cycle of calls at least twice.

In an optimized build it must also still be called after `-O2` has run
without the cache. `lib/codegen/emit.ml` (`memo`) emits a gate, a lookup and
two copies of each picked function.

Each function keeps a score. A lookup is charged the lookup's cost
measured against the weight of one of the function's calls, which is
estimated from the size of its body and of the functions it calls. A hit is
credited with the calls it saved. The function stops looking for good once
its lookups have cost 128 calls more than its hits saved. Because the charge
is relative, a function with heavy calls can look up for longer before its
hits start to pay, as a search does before its first transposition.

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
| `fib`, `corefib`, `binom`, `tri` | repeat their scalar arguments often: the case a cache is for |
| `ttt` | a tic-tac-toe minimax with the board, an `Array<I32, 9>`, as the argument; different move orders reach the same positions |
| `moves` | a three-way recursion keyed on a variant, one of whose cases has no payload |
| `overlap` | hits by accident: trees grown from consecutive seeds share subtrees |
| `phase` | a Fibonacci warm-up, then 20,000 small trees whose second argument never repeats |
| `salted`, `random`, `tree` | never repeat an argument |
| `tttpath` | `ttt` also given the path to each position, so no key repeats |
| `split` | repeat a few leaves |
| `shallow`, `shallowin` | worst case: a two-level recursion called 300,000 times from a loop, every argument new |

## Results

Estimated cycles under Callgrind, x86-64 container, 2026-10-22. `memoized`
is how many functions got a table. Every program printed the same output in
all four builds. The repository's own perf programs (`tests/perf/`) and every
langbench program but `concscan` (which crashes Valgrind in the base build
too) came out unchanged, except two of `tests/perf/`. One function in
`returns` is picked, and it moved by +0.01% plain and +0.02% optimized. One in
`stress` is picked, and that program got 0.24% faster plain and 1.07% faster
optimized.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,672,188       1,029,762   -99.28%  True
binom         optimized         1     103,293,764         988,544   -99.04%  True
fib           plain             1      11,018,856         981,854   -91.09%  True
fib           optimized         1       8,439,712         951,602   -88.72%  True
moves         plain             1     248,198,991       1,086,336   -99.56%  True
moves         optimized         1     207,158,258         974,243   -99.53%  True
overlap       plain             1      52,880,207       8,542,110   -83.85%  True
overlap       optimized         1      39,850,162       5,529,346   -86.12%  True
phase         plain             1      15,542,805      10,783,045   -30.62%  True
phase         optimized         1       7,405,735       7,391,902    -0.19%  True
random        plain             1      51,860,237      51,889,005    +0.06%  True
random        optimized         1      45,799,001      45,501,235    -0.65%  True
salted        plain             1      13,879,506      13,911,461    +0.23%  True
salted        optimized         1      11,384,291      11,407,903    +0.21%  True
shallow       plain             1      24,374,915      24,407,152    +0.13%  True
shallow       optimized         0         945,812         945,812    +0.00%  True
shallowin     plain             1      24,375,000      24,407,691    +0.13%  True
shallowin     optimized         1      14,147,108      13,571,992    -4.07%  True
split         plain             1      84,360,679      83,908,392    -0.54%  True
split         optimized         1      55,525,395      55,548,748    +0.04%  True
tree          plain             1      71,440,576      71,712,638    +0.38%  True
tree          optimized         1      51,420,436      51,498,974    +0.15%  True
tri           plain             1       5,104,186         980,140   -80.80%  True
tri           optimized         1       3,581,938         952,710   -73.40%  True
ttt           plain             1     434,210,512      84,773,319   -80.48%  True
ttt           optimized         1     125,110,680      30,377,128   -75.72%  True
tttpath       plain             1     436,960,090     437,529,829    +0.13%  True
tttpath       optimized         1     126,474,497     126,708,302    +0.18%  True
corefib       plain             1      11,039,546       1,001,137   -90.93%  True
corefib       optimized         1       8,453,211         965,191   -88.58%  True
```

Every row with no repeats is within +0.4%. That is the cost of the lookups
made before the function gives up, plus code placement, which Callgrind's
simple branch predictor is sensitive to. On hardware, `shallowin` (the worst
case: 300,000 calls from a loop, each doing little) measured a median of
4.58 ms against 4.45 ms plain and 3.74 ms against 4.09 ms optimized, over
150 runs, both dominated by process startup. `shallow` optimized has no table
at all, because without the cache LLVM folds the whole loop.

A program that spawns gets no tables: they are not yet safe to share
between threads.
