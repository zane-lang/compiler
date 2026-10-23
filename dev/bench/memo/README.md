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
- it calls back into its own cycle of calls at least twice.

A call equal to an earlier one, with arguments that read no local the body
assigns or takes the address of, and nothing through an address, counts
once. Every build picks from the tree alone, so a tiered build's two tiers
pick the same. `lib/codegen/emit.ml` (`memo`) emits a
gate, a lookup and two copies of each picked function.

Each function keeps a score. A lookup is charged the lookup's cost
measured against the weight of one of the function's calls, which is
estimated from the size of its body and of the functions it calls. A hit is
credited with the work it saved, counted from below: the cheapest path
through each call it skipped, with each loop run no times. The function
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

## Results

Estimated cycles under Callgrind, x86-64 container, 2026-10-23. `memoized`
is how many functions got a table. Every program printed the same output in
all six builds. The repository's own perf programs (`tests/perf/`) and every
langbench program but `concscan` (which crashes Valgrind in the base build
too) came out unchanged, except two of `tests/perf/`. One function in
`returns` is picked, and it moved by +0.01% plain and +0.02% optimized. One in
`stress` is picked, and that program got 0.24% faster plain and 1.07% faster
optimized.

```
program       build      memoized     base cycles     memo cycles    change  same output
binom         plain             1     142,675,627       1,033,330   -99.28%  True
binom         optimized         1     103,302,465         994,623   -99.04%  True
binom         tiered            1     103,461,546       1,163,390   -98.88%  True
fib           plain             1      11,021,620         989,147   -91.03%  True
fib           optimized         1       8,448,372         959,595   -88.64%  True
fib           tiered            1       8,606,468       1,125,610   -86.92%  True
heavyleaf     plain             1     174,287,622     174,138,830    -0.09%  True
heavyleaf     optimized         1      70,832,882      70,847,939    +0.02%  True
heavyleaf     tiered            1      70,991,859      71,024,158    +0.05%  True
leaves        plain             1      72,083,226      72,151,916    +0.10%  True
leaves        optimized         1      48,727,351      48,782,355    +0.11%  True
leaves        tiered            1      48,889,335      48,953,063    +0.13%  True
moves         plain             1     248,205,329       1,086,537   -99.56%  True
moves         optimized         1     207,164,532         982,072   -99.53%  True
moves         tiered            1     193,778,414       1,160,962   -99.40%  True
overlap       plain             1      52,883,203       8,783,979   -83.39%  True
overlap       optimized         1      39,855,685       5,706,755   -85.68%  True
overlap       tiered            1      40,017,940       6,488,670   -83.79%  True
phase         plain             1      15,546,264      10,769,429   -30.73%  True
phase         optimized         1       7,414,296       7,388,403    -0.35%  True
phase         tiered            1      10,801,724       7,564,727   -29.97%  True
random        plain             1      51,862,754      51,894,853    +0.06%  True
random        optimized         1      45,804,758      45,507,750    -0.65%  True
random        tiered            1      45,966,303      45,836,107    -0.28%  True
salted        plain             1      13,882,213      13,912,570    +0.22%  True
salted        optimized         1      11,392,539      11,413,668    +0.19%  True
salted        tiered            1      11,552,035      11,582,736    +0.27%  True
shallow       plain             1      24,377,971      24,411,941    +0.14%  True
shallow       optimized         1         953,976         979,065    +2.63%  True
shallow       tiered            1      14,315,028      13,749,823    -3.95%  True
shallowin     plain             1      24,377,627      24,411,957    +0.14%  True
shallowin     optimized         1      14,155,276      13,578,200    -4.08%  True
shallowin     tiered            1      14,314,031      13,748,716    -3.95%  True
split         plain             1      83,884,048      84,153,884    +0.32%  True
split         optimized         1      55,533,616      55,554,390    +0.04%  True
split         tiered            1      55,813,212      55,723,574    -0.16%  True
tree          plain             1      71,444,327      71,478,298    +0.05%  True
tree          optimized         1      51,428,563      51,505,631    +0.15%  True
tree          tiered            1      52,068,531      51,615,377    -0.87%  True
tri           plain             1       5,106,760         985,499   -80.70%  True
tri           optimized         1       3,590,198         957,717   -73.32%  True
tri           tiered            1       3,749,076       1,126,092   -69.96%  True
ttt           plain             1     434,215,801      85,245,922   -80.37%  True
ttt           optimized         1     125,116,379      30,710,614   -75.45%  True
ttt           tiered            1     127,136,330      32,482,223   -74.45%  True
tttpath       plain             1     436,962,646     437,544,314    +0.13%  True
tttpath       optimized         1     126,480,026     126,719,489    +0.19%  True
tttpath       tiered            1     131,172,601     131,466,411    +0.22%  True
corefib       plain             1      11,038,756       1,004,973   -90.90%  True
corefib       optimized         1       8,458,826         972,430   -88.50%  True
corefib       tiered            1       8,631,960       1,160,075   -86.56%  True
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
| plain | −86.9% | +0.52% | 0 | 134 |
| optimized | −36.6% | +1.23% | 1 | 96 |
| tiered | −35.8% | +2.06% | 6 | 104 |

The 1,000 programs of seeds 5041 to 6040, run through `compare`, printed
the same in every build. 13 programs have no table in the optimized build,
where LLVM removed every call of the function. Three of the tiered rows above +1% run about a
million cycles, and theirs is a fixed cost of 11,000 to 15,000 cycles:
the lookups made before the function stops, and last-level misses on the
code and the table that tier 1 adds. The other three grow with the input,
by 1.1–2.3%:

- `s22` runs fewer instructions with its table, but Callgrind's instruction
  cache, 32 KiB in eight ways, misses ten times as often in the C library's
  `printf`, which tier 1's code now shares sets with. With sixteen ways, or
  64 KiB, the same build is 1% faster than without the table.
- `s139` loses the same way, and to more mispredicted branches.
- `s155` keeps looking up `f1k1`, whose hits save calls of a few
  instructions each once LLVM has optimized them, at a cost of 56
  instructions a hit. A charge from the tree cannot see that the body
  folds: weighing folded nodes as nothing, or raising the lookup's cost to
  match, barely moved `s155` and lost `binom` and `overlap` their wins.

A program that spawns gets no tables, and neither does a library, which a
program that spawns may call: the tables are not shared safely between
threads.
