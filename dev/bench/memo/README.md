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
count says or else eight times, a switch's dearest case, and nothing for
naming a local, a constant or a verb's expansion. Every build picks from the
tree alone, so a tiered build's two tiers pick the same. `lib/codegen/emit.ml` (`memo`)
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

Estimated cycles under Callgrind, x86-64 container, 2026-10-25, with tables
of at most 256 KiB. `memoized` is how many functions got a table. Every
program printed the same output in all six builds. Of the repository's own
perf programs (`tests/perf/`), six get a table. `depths`, written for a
recursion that calls itself once, got 97.6% faster plain, 96.1% optimized
and 96.3% tiered, and `repeats`, written for a heavy call in a loop, 93.3%,
92.8% and 92.3%. `floats` moved by +0.20% plain, +0.39% optimized and
+0.43% tiered, `leaves` by +0.09% to +0.11%, and `returns` by −0.90% plain
and +0.02% to +0.03% otherwise. `stress`, whose sixteen sections each get
one, got 0.32% faster plain, 0.33% optimized and 0.55% tiered. Of langbench,
`mandelbrot` alone gets a table, for a call whose arguments never repeat:
at its check size it costs a fixed 283,000 to 455,000 cycles, +0.85% plain,
+1.58% optimized and +1.69% tiered, the lookups it makes before it stops
each reading a line of the table no other has.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,700,741       1,053,547   -99.26%  True
binom         optimized         1     103,321,406       1,011,264   -99.02%  True
binom         tiered            1     103,475,972       1,171,059   -98.87%  True
euclid        plain             1      12,268,716      12,285,013    +0.13%  True
euclid        optimized         1       7,827,614       7,537,304    -3.71%  True
euclid        tiered            1       7,700,185       7,696,288    -0.05%  True
fib           plain             1      11,047,066       1,011,681   -90.84%  True
fib           optimized         1       8,467,552         980,045   -88.43%  True
fib           tiered            1       8,621,866       1,140,599   -86.77%  True
heavyleaf     plain             1     174,969,012     174,171,877    -0.46%  True
heavyleaf     optimized         1      70,854,482      70,869,999    +0.02%  True
heavyleaf     tiered            1      71,012,144      71,043,319    +0.04%  True
leaves        plain             1      72,109,047      72,174,267    +0.09%  True
leaves        optimized         1      48,748,953      48,799,656    +0.10%  True
leaves        tiered            1      48,904,262      48,960,167    +0.11%  True
linear        plain             1     166,884,304       3,801,704   -97.72%  True
linear        optimized         1      69,861,654       2,590,954   -96.29%  True
linear        tiered            1      76,917,329       2,730,707   -96.45%  True
loopcold      plain             1     106,082,931     106,233,458    +0.14%  True
loopcold      optimized         1      49,533,950      49,623,543    +0.18%  True
loopcold      tiered            1      49,687,821      49,784,226    +0.19%  True
loopleaf      plain             1     106,263,589       6,954,582   -93.46%  True
loopleaf      optimized         1      49,554,338       3,446,159   -93.05%  True
loopleaf      tiered            1      49,708,341       3,701,534   -92.55%  True
looplight     plain             0      14,002,519      14,002,519    +0.00%  True
looplight     optimized         0       7,173,520       7,173,520    +0.00%  True
looplight     tiered            0       7,327,141       7,327,141    +0.00%  True
moves         plain             1     248,230,173       1,084,869   -99.56%  True
moves         optimized         1     207,186,100       1,001,303   -99.52%  True
moves         tiered            1     193,793,386       1,167,889   -99.40%  True
overlap       plain             1      52,908,831       9,347,093   -82.33%  True
overlap       optimized         1      42,517,566       6,488,171   -84.74%  True
overlap       tiered            1      42,593,684       6,890,498   -83.82%  True
phase         plain             1      15,971,342      10,792,210   -32.43%  True
phase         optimized         1       7,434,161       7,406,928    -0.37%  True
phase         tiered            1      10,814,978       7,572,956   -29.98%  True
random        plain             1      51,888,434      51,917,229    +0.06%  True
random        optimized         1      45,505,933      45,525,482    +0.04%  True
random        tiered            1      45,661,136      45,844,765    +0.40%  True
salted        plain             1      13,908,368      13,935,491    +0.20%  True
salted        optimized         1      11,411,520      11,431,073    +0.17%  True
salted        tiered            1      11,566,166      11,591,357    +0.22%  True
shallow       plain             1      24,403,850      24,435,086    +0.13%  True
shallow       optimized         1         973,886         996,297    +2.30%  True
shallow       tiered            1      14,329,164      13,755,596    -4.00%  True
shallowin     plain             1      24,403,768      24,434,624    +0.13%  True
shallowin     optimized         1      14,174,279      13,594,733    -4.09%  True
shallowin     tiered            1      14,327,869      13,755,852    -3.99%  True
split         plain             1      84,390,178      83,936,200    -0.54%  True
split         optimized         1      57,472,977      55,572,141    -3.31%  True
split         tiered            1      55,706,898      55,732,527    +0.05%  True
tree          plain             1      71,469,761      71,979,978    +0.71%  True
tree          optimized         1      51,448,518      51,464,139    +0.03%  True
tree          tiered            1      51,602,388      51,863,008    +0.51%  True
tri           plain             1       5,132,727       1,011,676   -80.29%  True
tri           optimized         1       3,609,619         979,838   -72.85%  True
tri           tiered            1       3,764,353       1,138,761   -69.75%  True
ttt           plain             1     438,566,337      17,155,793   -96.09%  True
ttt           optimized         1     123,937,166       7,060,204   -94.30%  True
ttt           tiered            1     126,509,474       7,425,469   -94.13%  True
tttpath       plain             1     441,315,382     442,028,512    +0.16%  True
tttpath       optimized         1     126,609,773     126,991,544    +0.30%  True
tttpath       tiered            1     129,521,571     129,954,070    +0.33%  True
corefib       plain             1      11,072,983       1,036,286   -90.64%  True
corefib       optimized         1       8,485,302         998,142   -88.24%  True
corefib       tiered            1       8,652,816       1,171,825   -86.46%  True
```

Every row with no repeats is within +0.71%, but `shallow` optimized. That
is the cost of the lookups made before the function gives up, plus code
placement, which Callgrind's simple branch predictor is sensitive to.
`shallow` optimized costs 22,000 cycles more, whatever its input: without a
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
| plain | −86.1% | +0.34% | 0 | 133 |
| optimized | −37.3% | +0.95% | 0 | 96 |
| tiered | −35.9% | +1.79% | 5 | 104 |

The median is over the programs with a table in that build: all 150 plain
and tiered, 137 optimized, where LLVM removed every call of the function in
the other 13. The 300 programs of seeds 1 to 300, run through `compare`,
printed the same in every build that finished in `compare`'s 30 seconds;
seven builds without tables, of six programs, ran longer. The five rows
above +1%, all tiered, run about 1.1 million cycles, and theirs is a fixed
cost of 13,000 to 20,000 cycles: the lookups made before the function stops, and last-level misses
on the code and the table that tier 1 adds.

A program that spawns, and a library, which a program that spawns may call,
share each table between threads
([`docs/design/memoization.md`](../../../docs/design/memoization.md) M1).
