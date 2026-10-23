# Runtime call caching, measured

Measurements for [zane-lang/compiler#262](https://github.com/zane-lang/compiler/issues/262).
Every build remembers calls while the program runs, for the functions
`lib/cgt/memo.ml` picks, unless it is built with `--no-memoize`. A function
is picked when:

- its result depends only on its arguments: it reaches neither the console
  nor the runtime, and reads only package constants, which never change;
- every argument and its result is a fixed-size value (scalars, and
  structs, enums, variants and arrays of them, holding no handle or
  address), with at most eight words of arguments and eight of result (a
  word for each scalar of a value of scalars only, else for each eight
  bytes);
- it calls back into its own cycle of calls, or it calls no function of its
  own cycle, a loop in another function calls it, and one call runs at
  least twice the operations of a lookup.

A call's operations estimate what an optimized build runs: computations,
memory accesses, branches and calls, a loop's body as often as a constant
count says or else eight times, and nothing for naming a local, a constant
or a verb's expansion. Every build picks from the tree alone, so
a tiered build's two tiers pick the same. `lib/codegen/emit.ml` (`memo`)
emits a gate, a lookup and two copies of each picked function.

Each function keeps a score. A lookup is charged the lookup's cost
measured against the weight of one of the function's calls, which is
estimated from the size of its body and of the functions it calls. A hit is
credited with the work it saved, counted from below: the cheapest path
through each call it skipped, with a loop run as often as a constant count
says and any other loop run no times. The function
stops looking for good once its lookups have cost 128 calls more than its
hits saved. Because the charge is relative, a function with heavy calls can
look up for longer before its hits start to pay, as a search does before its
first transposition.

A loop that calls a picked function from outside its recursion runs in two
versions, chosen once before the loop. If every dispatcher it calls has
stopped looking, the loop runs as written, calling the plain copies, so
nothing in it checks a dispatcher. Otherwise a copy that calls through the
dispatchers runs, and before each round it checks whether they have all
stopped. If they have, it hands the rounds that are left to the first
version.

    dev/bench/memo/run ZANEC OUTDIR dev/bench/memo/programs/*   # these programs, but corefib
    EXTRA="--package bench=… --package core=… --package math=…" \
      dev/bench/memo/run ZANEC OUTDIR dev/bench/memo/programs/corefib
    EXTRA="--package bench=… --package core=… --package math=…" \
      dev/bench/memo/run ZANEC OUTDIR LANGBENCH/bin/*  # langbench, with the size in an `arguments` file

`run` builds each program plain, optimized and tiered (as `zane run` builds
it, with tier 1 loaded before `main`), with `--no-memoize` and without it,
and reports Callgrind's estimated cycles, using `tests/perf/run`'s formula
and caches. `ONLY=plain,tiered` limits it to those builds.

    dev/bench/memo/generate SEED DIR      # a random program, the same for each seed
    dev/bench/memo/compare ZANEC FIRST LAST

`generate` writes a random program of one to three cycles of recursive
functions over the fixed-size types, with arguments narrowed so that they
repeat. `compare` generates the programs for a range of seeds, runs each in
all six builds and lists every seed whose builds printed differently.
`random-seeds` lists the 150 seeds whose programs the spread below was
measured on; `run` takes the directories `generate` writes for them.

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
| `leaves` | repeat only on the last level, whose calls do least: half the calls hit, and each hit saves less than a lookup costs |
| `heavyleaf` | repeat only on the last two levels, whose calls run a loop of twenty rounds that the credit for a hit leaves out |
| `shallow`, `shallowin` | worst case: a two-level recursion called 300,000 times from a loop, every argument new |
| `linear` | a recursion that calls itself once, called from a loop that asks for the same 500 depths over and over |
| `euclid` | a recursion that calls itself once, on arguments that never repeat |
| `loopleaf` | no recursion: a call of 200 rounds in a loop that asks for the same 64 arguments over and over |
| `loopcold` | the same call, every argument new |
| `looplight` | a call in a loop whose arguments repeat but which does less than a lookup: it gets no table |

## Results

Estimated cycles under Callgrind, x86-64 container, 2026-10-23. `memoized`
is how many functions got a table. Every program printed the same output in
all six builds. Of the repository's own perf programs (`tests/perf/`), five
get a table. `repeats`, written for a heavy call in a loop, got 90.2% faster
plain, 89.6% optimized and 89.1% tiered. `floats` moved by +0.17% plain,
+0.29% optimized and +0.32% tiered, `leaves` by +0.10% to +0.13%, and
`returns` by +0.01% to +0.02%. `stress`, whose sixteen sections each get
one, got 0.31% faster plain, 0.34% optimized and 0.52% tiered. Of langbench, `mandelbrot` alone gets a
table, for a call whose arguments never repeat: at its check size it costs a
fixed 170,000 cycles, +0.64% plain, +0.93% optimized and +1.00% tiered.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,678,159       1,035,892   -99.27%  True
binom         optimized         1     103,305,590         997,728   -99.03%  True
binom         tiered            1     103,465,152       1,166,988   -98.87%  True
euclid        plain             1      12,245,816      12,393,812    +1.21%  True
euclid        optimized         1       7,526,310       7,521,854    -0.06%  True
euclid        tiered            1       7,688,997       7,688,233    -0.01%  True
fib           plain             1      11,024,286         989,458   -91.02%  True
fib           optimized         1       8,451,376         962,599   -88.61%  True
fib           tiered            1       8,609,861       1,129,297   -86.88%  True
heavyleaf     plain             1     174,290,707     174,141,725    -0.09%  True
heavyleaf     optimized         1      70,835,206      70,850,257    +0.02%  True
heavyleaf     tiered            1      70,995,015      71,027,095    +0.05%  True
leaves        plain             1      72,086,367      72,154,947    +0.10%  True
leaves        optimized         1      48,730,199      48,785,213    +0.11%  True
leaves        tiered            1      48,892,158      48,955,863    +0.13%  True
linear        plain             1     166,861,342       4,207,095   -97.48%  True
linear        optimized         1      69,822,471       2,853,324   -95.91%  True
linear        tiered            1      76,926,546       3,246,364   -95.78%  True
loopcold      plain             1     106,059,898     106,210,221    +0.14%  True
loopcold      optimized         1      49,515,168      49,585,568    +0.14%  True
loopcold      tiered            1      49,676,980      49,774,126    +0.20%  True
loopleaf      plain             1     106,240,832      10,285,002   -90.32%  True
loopleaf      optimized         1      49,535,452       5,039,449   -89.83%  True
loopleaf      tiered            1      49,697,448       5,308,553   -89.32%  True
looplight     plain             0      13,980,136      13,980,136    +0.00%  True
looplight     optimized         0       7,154,923       7,154,923    +0.00%  True
looplight     tiered            0       7,316,883       7,316,883    +0.00%  True
moves         plain             1     248,207,911       1,088,325   -99.56%  True
moves         optimized         1     207,167,697         985,167   -99.52%  True
moves         tiered            1     193,782,040       1,164,493   -99.40%  True
overlap       plain             1      52,886,291       8,786,217   -83.39%  True
overlap       optimized         1      39,858,823       5,710,833   -85.67%  True
overlap       tiered            1      40,021,416       6,491,121   -83.78%  True
phase         plain             1      15,548,978      10,772,123   -30.72%  True
phase         optimized         1       7,417,557       7,391,654    -0.35%  True
phase         tiered            1      10,805,295       7,568,061   -29.96%  True
random        plain             1      51,865,891      51,898,000    +0.06%  True
random        optimized         1      45,807,852      45,510,794    -0.65%  True
random        tiered            1      45,969,553      45,839,035    -0.28%  True
salted        plain             1      13,885,334      13,915,591    +0.22%  True
salted        optimized         1      11,395,403      11,416,526    +0.19%  True
salted        tiered            1      11,554,928      11,585,666    +0.27%  True
shallow       plain             1      24,381,085      24,415,025    +0.14%  True
shallow       optimized         1         957,150         982,199    +2.62%  True
shallow       tiered            1      14,318,536      13,752,738    -3.95%  True
shallowin     plain             1      24,380,546      24,414,846    +0.14%  True
shallowin     optimized         1      14,157,434      13,580,274    -4.08%  True
shallowin     tiered            1      14,316,803      13,751,141    -3.95%  True
split         plain             1      83,886,786      84,156,632    +0.32%  True
split         optimized         1      55,536,781      55,557,475    +0.04%  True
split         tiered            1      55,816,952      55,726,936    -0.16%  True
tree          plain             1      71,446,811      71,480,802    +0.05%  True
tree          optimized         1      51,431,883      51,508,851    +0.15%  True
tree          tiered            1      52,072,534      51,619,083    -0.87%  True
tri           plain             1       5,109,466         988,225   -80.66%  True
tri           optimized         1       3,593,182         960,681   -73.26%  True
tri           tiered            1       3,752,673       1,129,697   -69.90%  True
ttt           plain             1     434,215,992      85,242,568   -80.37%  True
ttt           optimized         1     125,119,343      30,714,508   -75.45%  True
ttt           tiered            1     127,139,885      32,486,764   -74.45%  True
tttpath       plain             1     436,965,510     437,547,098    +0.13%  True
tttpath       optimized         1     126,483,120     126,722,583    +0.19%  True
tttpath       tiered            1     131,176,262     131,469,865    +0.22%  True
corefib       plain             1      11,039,651       1,005,932   -90.89%  True
corefib       optimized         1       8,459,455         973,079   -88.50%  True
corefib       tiered            1       8,632,256       1,160,130   -86.56%  True
```

Every row with no repeats is within +0.32%, but `shallow` optimized. That
is the cost of the lookups made before the function gives up, plus code
placement, which Callgrind's simple branch predictor is sensitive to.
`shallow` optimized costs 25,000 cycles more, whatever its input: without a
table LLVM folds its whole loop, and with one it makes the lookups before
the function stops. On hardware, `shallowin` (the worst case: 300,000 calls
from a loop, each doing little) measured a median of 4.58 ms against
4.45 ms plain and 3.74 ms against 4.09 ms optimized, over 150 runs, both
dominated by process startup.

### Random programs

The change in estimated cycles over the 150 programs of `random-seeds`,
each of which has at least one table in the plain build:

| build | median | worst | above +1% | more than 10% faster |
|---|---|---|---|---|
| plain | −87.3% | +0.39% | 0 | 134 |
| optimized | −36.6% | +1.23% | 1 | 96 |
| tiered | −35.8% | +1.75% | 6 | 104 |

The median is over the programs with a table in that build: all 150 plain
and tiered, 137 optimized, where LLVM removed every call of the function in
the other 13. The 300 programs of seeds 1 to 300, run through `compare`,
printed the same in every build. Five of the rows above +1% run about a
million cycles, and theirs is a fixed cost of 11,000 to 15,000 cycles: the
lookups made before the function stops, and last-level misses on the code
and the table that tier 1 adds. The other two grow with the input, by
1.4–1.8%:

- `s22` runs fewer instructions with its table, but Callgrind's instruction
  cache, 32 KiB in eight ways, misses ten times as often in the C library's
  `printf`, which tier 1's code now shares sets with. With sixteen ways, or
  64 KiB, the same build is 1% faster than without the table.
- `s139` loses the same way, and to more mispredicted branches.

A program that spawns gets no tables, and neither does a library, which a
program that spawns may call: the tables are not shared safely between
threads.
