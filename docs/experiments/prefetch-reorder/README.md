# Prefetching and reordered random access

Whether the compiler can keep a program from waiting on memory when it reads
or writes at addresses the hardware cannot predict, by computing addresses
early and fetching them before they are used. This is a C model of the code
shapes the compiler could emit, not a change to `zanec`: `model.c` holds each
kernel written plainly and in every reordered form, with Zane's index checks
and 32-bit handles, and `run.py` sweeps it. Round 5 moves to `zanec`:
`programs/` holds the same kernels in Zane and the timing of what the
compiler builds from them.

**Measuring.** `run.py LABEL` builds `model.c` with `clang -O2`, runs each
kernel pinned to one CPU at three data sizes (256 KiB, 32 MiB, 2 GiB) with
4 KiB pages and with transparent huge pages, and writes `results/LABEL.tsv`:
nanoseconds per operation, best of three. `run.py --show LABEL` prints each
variant's best parameter against the plain form. Every variant of a kernel
must return the same checksum. Times are wall clock: Callgrind counts a
prefetch as an instruction and models no overlap between misses, so it would
report every one of these as a small loss.

Each row is one run in a cloud container (Xeon at 2.1 GHz, 2 MiB of L2 per
core, a 260 MiB L3 shared with other tenants, clang 18.1.3). Read ratios
within a row; differences under about 15% between rows are not established.

## Round 1

| kernel | plain code | variants |
| --- | --- | --- |
| `gather` | `s += a[idx[i]]` | `naive`: prefetch, then access at once. `ahead`: prefetch the element `D` iterations on. `group`: prefetch `G` elements, then access them. `sorted`: visit indices bucketed by address |
| `heavy` | 64-byte elements, a branch on the loaded value | the same, and `earlyload`: load the branch field of `G` elements, then do the work, with no prefetch instruction |
| `scatter` | `a[idx[i]] += v` | `ahead`, `group`, prefetching for a write |
| `hash` | open-addressing lookups, half of them hits | `ahead`, `group` |
| `bsearch` | binary searches for a batch of keys | `bothways`: prefetch both next probes. `group`: `W` searches a step at a time. `eytzinger`: the array stored in breadth-first order |
| `tree` | lookups in a balanced tree, nodes at random places | `group`: `W` lookups a step at a time. `amac`: the same, a finished lookup's place taken at once by the next key |

Speed against the plain form, best parameter, at 2 GiB (`results/round1.tsv`
has every size and parameter):

| kernel | plain, 4 KiB pages | plain, huge pages | best variant, 4 KiB | best variant, huge |
| --- | ---: | ---: | --- | --- |
| `gather` | 22.3 ns | 8.3 ns | `sorted` ×1.62, `group` ×1.15 | `ahead` ×1.15 |
| `heavy` | 37.5 ns | 28.4 ns | `ahead` ×1.56 | `ahead` ×2.22 |
| `scatter` | 24.1 ns | 11.8 ns | `ahead` ×1.14 | `ahead` ×1.30 |
| `hash` | 101.3 ns | 75.2 ns | `ahead` ×2.77 | `ahead` ×2.11 |
| `bsearch` | 1769 ns | 2173 ns | `group` ×3.23 | `eytzinger` ×4.66, `group` ×3.56 |
| `tree` | 2228 ns | 1362 ns | `group` ×6.34 | `group` ×9.72 |

**What it shows.**

- Prefetching immediately before the access does nothing (`naive`: ×0.85 to
  ×1.19, mostly a small loss). The fetch has to be issued well ahead.
- A light loop gains little (`gather`, `scatter`: ×1.1 to ×1.3). The
  processor already has many of its misses in flight. Huge pages are worth
  more there than any prefetch: ×2.7 for `gather`, ×2.0 for `scatter`.
- A loop that branches on what it loaded, or does real work on it, gains
  ×1.6 to ×2.8 (`heavy`, `hash`).
- Chains gain most: ×3 for interleaved binary searches, ×6 to ×11 for
  interleaved tree lookups. A single chain has nothing to issue early;
  several independent ones do.
- The sliding form (`ahead`) beat the batched form (`group`) wherever both
  apply, by 10% to 45%. Loading early without a prefetch (`earlyload`) is
  behind both.
- Useful distances are 16 to 64 iterations and batches 16 to 128, larger
  than the 8 to 16 the fill buffers alone suggest.
- In cache (256 KiB) the cost is 3% to 12% on `gather` and nothing
  measurable elsewhere; `tree` and `bsearch` are faster even there (×2.0,
  ×1.3), since interleaving also overlaps their mispredicted branches.
- Changing the layout (`eytzinger`) matches or beats interleaving for binary
  search and is ×4 faster in cache too. Visiting in address order (`sorted`)
  wins only for the light loop with 4 KiB pages, and costs ×10 in cache.

## Round 2

`run.py round2 twohop nested chains heavy gather gatherx heavyx`. `gather`
and `heavy` were measured again with the new variants, so their rows repeat
round 1's on another run.

| kernel | plain code | variants |
| --- | --- | --- |
| `chains` | for each of many lists of 1 to 15 links at random places, walk it | `ahead`: prefetch the head of the list `D` on. `group`, `amac`: walk `W` lists a link at a time, as for `tree` |
| `nested` | a list of lists of 1 to 8 elements, handles in order, payloads at random places | `ahead`: prefetch the payload of the row `D` on |
| `twohop` | `s += a[b[idx[i]]]` | `ahead`: prefetch `b[idx[i+D]]`. `staged`: that at `2D`, and `a[b[idx[i+D]]]` |
| `gather`, `heavy` | as round 1 | `helper`: a second thread on another core loads up to `K` iterations ahead. `nta` (`heavy`): the non-temporal prefetch hint |
| `gatherx`, `heavyx` | as round 1 | plain against `ahead` at every power of two from 64 KiB to 256 MiB |

At 2 GiB, best parameter:

| kernel | plain, 4 KiB pages | plain, huge pages | best variant, 4 KiB | best variant, huge |
| --- | ---: | ---: | --- | --- |
| `chains` | 633 ns | 457 ns | `amac` ×4.00, `group` ×3.87, `ahead` ×1.00 | `amac` ×5.76, `group` ×5.18, `ahead` ×1.02 |
| `nested` | 28.6 ns | 21.4 ns | `ahead` ×1.27 | `ahead` ×1.40 |
| `twohop` | 43.8 ns | 20.0 ns | `ahead`, `staged` ×1.06 | `staged` ×1.57, `ahead` ×1.39 |
| `heavy` | 35.3 ns | 25.7 ns | `ahead` ×1.79, `nta` ×1.56, `helper` ×1.20 | `ahead` ×2.05, `nta` ×2.04, `helper` ×1.18 |
| `gather` | 20.7 ns | 9.5 ns | `sorted` ×1.34, `helper` ×1.03, `ahead` ×0.99 | `ahead` ×1.21, `helper` ×1.11 |

**What it shows.**

- Interleaving carries over to short chains: ×4 to ×7.5 from 32 MiB up.
  Prefetching only each chain's head does nothing, since the other links
  are the misses. Unlike `tree`, it costs in cache: ×0.74 to ×0.79 for
  `amac` and ×0.45 for `group` at 256 KiB. This one needs a gate.
- A second thread is not worth a core: at most ×1.2, against ×1.8 to ×2.05
  for a prefetch in the loop itself, and ×0.64 to ×0.88 in cache.
- The non-temporal hint is never ahead of the ordinary one and does nothing
  at 32 MiB (×1.0 against ×2.0).
- With 4 KiB pages the light loops (`gather`, `twohop`) gain nothing from
  prefetching: round 1's ×1.12 for `gather` did not repeat (×0.99). With
  huge pages they gain ×1.2 to ×1.6, and staging the second hop is worth
  another 13% at 2 GiB. The two multiply: `gather` goes from 20.7 ns to
  7.9 ns with both.
- `heavy` with `ahead` is never slower than plain at any size from 64 KiB
  up (×1.05 at the least), is ×1.4 or better from 2 MiB, the size of L2,
  and ×2 from 32 MiB. It needs no gate. `gather` stays within the noise
  below 64 MiB (×0.82 to ×1.29 on times under 5 ns) and gains ×1.1 to ×1.3
  above it.

## Round 3: both strategies in one loop

`run.py round3 combo`. `combo` is one loop with both kinds of miss: each
iteration loads a 64-byte record at a random place, does `heavy`'s work on
it, and looks a key from the record up in the tree. Half the data is
records and half is tree.

- `ahead`: prefetch the record `D` iterations on; the walks stay one at a
  time.
- `inter`: `W` walks a step at a time (`amac`); a record is loaded when its
  walk starts, with no prefetch.
- `both`, `both32`: `inter`, and the record prefetched `W` or 32 walks
  before it is needed.
- `staged`: `inter`, with the record's load made a step of its own: starting
  a walk only prefetches the record, and the next visit reads it.

Speed against the plain form, best parameter:

| data | plain | `ahead` | `inter` | `both` | `both32` | `staged` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 51.3 ns | ×1.05 | ×1.20 | ×1.26 | ×1.27 | ×1.15 |
| 32 MiB | 397.5 ns | ×0.90 | ×3.03 | ×5.29 | ×5.79 | ×5.00 |
| 32 MiB, huge pages | 306.6 ns | ×0.87 | ×2.46 | ×5.20 | ×5.37 | ×4.59 |
| 2 GiB | 1954 ns | ×0.93 | ×4.88 | ×6.46 | ×6.87 | ×6.62 |
| 2 GiB, huge pages | 1334 ns | ×0.93 | ×5.80 | ×8.44 | ×8.35 | ×8.26 |

**What it shows.** The two are worth more together than apart. Prefetching
the record alone does nothing here (×0.87 to ×1.05): the walk that follows
is far longer than the record's miss, so the loop still waits. Interleaving
alone leaves the record's miss in the way of every walk that starts. With
both, the gain over interleaving alone is ×1.3 to ×1.45 at 2 GiB and ×1.8
to ×2.1 at 32 MiB, and the loop is 5 to 8 times faster than the plain form.
The three ways of fetching the record early are within 10% of each other;
making it a step of the walk (`staged`) needs no distance to tune. In cache
the combined form is ×1.26 faster, not slower.

## Round 4: where an arena puts the nodes

Rounds 1 to 3 put every node at a random place, the worst case. A scope's
dynamic region hands out addresses in the order they are asked for, and
gives a freed block to the next request of its size, so a structure built
in one pass lies in the order it was built. `run.py round4 tree.rand
tree.pre tree.post tree.bfs tree.pre+10 tree.pre+50 chains.rand chains.seq
chains.arrival chains.seq+10 chains.seq+50` runs `tree` and `chains` again
with the nodes placed as a build would place them:

- `tree.pre`, `tree.post`, `tree.bfs`: built parent first, children first,
  and a level at a time.
- `chains.seq`: each list built whole before the next. `chains.arrival`:
  the lists grown a link at a time in turn, as a table of buckets fills.
- `+10`, `+50`: that share of the nodes then freed and allocated again in
  an unrelated order.
- `rand`: as before.

At 2 GiB, plain time and the better of `group` and `amac`:

| placement | plain, 4 KiB | interleaved, 4 KiB | plain, huge | interleaved, huge |
| --- | ---: | --- | ---: | --- |
| `tree.rand` | 1940 ns | 293 ns, ×6.63 | 1322 ns | 123 ns, ×10.74 |
| `tree.pre` | 1014 ns | 234 ns, ×4.33 | 831 ns | 183 ns, ×4.55 |
| `tree.post` | 961 ns | 199 ns, ×4.84 | 868 ns | 187 ns, ×4.65 |
| `tree.bfs` | 1348 ns | 177 ns, ×7.60 | 988 ns | 102 ns, ×9.68 |
| `tree.pre+10` | 1018 ns | 203 ns, ×5.01 | 920 ns | 191 ns, ×4.83 |
| `tree.pre+50` | 1553 ns | 254 ns, ×6.11 | 1216 ns | 168 ns, ×7.26 |
| `chains.rand` | 664 ns | 175 ns, ×3.80 | 458 ns | 74 ns, ×6.23 |
| `chains.arrival` | 696 ns | 159 ns, ×4.37 | 466 ns | 71 ns, ×6.54 |
| `chains.seq` | 31 ns | 22 ns, ×1.42 | 29 ns | 22 ns, ×1.33 |
| `chains.seq+10` | 119 ns | 45 ns, ×2.62 | 95 ns | 29 ns, ×3.28 |
| `chains.seq+50` | 387 ns | 95 ns, ×4.06 | 269 ns | 61 ns, ×4.45 |

**What it shows.**

- Build order does not rescue a tree. Depth-first order halves the plain
  lookup (the last few levels of a subtree share a page), and the upper
  levels still miss at every step: interleaving is ×4.3 to ×4.8 there, and
  ×6 to ×7 once half the nodes have been replaced.
- Lists built whole are the one case that is already fast: 31 ns against
  664 ns, since the walk is a forward scan the hardware follows.
  Interleaving still gains ×1.3 to ×1.4 with `amac`; `group` loses 16% to
  18%.
- That does not survive use. With a tenth of the links replaced the plain
  walk is 3 to 4 times slower and interleaving gains ×2.6 to ×3.3; with
  half replaced, ×4 to ×4.5. Lists grown in turn are as slow as random
  placement from the start.
- `amac` was never slower than plain in any placement at these sizes;
  `group` was. Refilling a finished place at once is the form to build.

## Round 5: the measured shapes in Zane, and a prefetch in `zanec`

`programs/` holds the model's `heavy`, `hash`, `tree`, `chains` and
`gather` written in Zane, and `programs/time.py`, which builds them with
`zanec --optimize` and times them. Each program builds its data as
`model.c` does and prints the same checksum for the same arguments, which
was checked against `model.c` at 256 KiB for all five. Zane has no clock,
so each program prints `ready` when its data is built, and `time.py` runs
it on a pseudo-terminal, where output is flushed per line, and times the
loop from that line to the checksum. Pages are 4 KiB: the runtime asks for
no huge pages and the machine's transparent huge pages are `madvise` only.
Same machine type as rounds 1 to 4 (Xeon at 2.1 GHz, 2 MiB of L2 per core,
260 MiB L3 shared with other tenants), pinned to the last CPU, 15 GiB of
memory.

Three of the programs need a loop that stops early. Zane has no `break`: a
search `return`s from inside its loop, from a verb of its own
([spec `control-flow.md`](https://github.com/zane-lang/spec/blob/cdbe5bb/spec/control-flow.md)
§3.5). A function with one is called, and a call in a loop's body keeps the
codegen's loop analyses off it, so `probe`, `find` and `walk` each take a
block they never run: a verb that takes a block is written out where it is
called, and its `return` then leaves only the walk (round 7 drops the
block: a loop now writes such a search out itself).
`@controlflow$exitFromCall` is no substitute: the compiler ends the run of
the block it is called in, so in a loop it skips to the next pass
([`spec-divergences.md`](../../spec-divergences.md) §6).

**Plain `zanec`** (`results/zane-baseline.tsv`, the compiler at `9536bf4`,
best of 3, one run of the sweep), against the plain C of rounds 1 and 2 at
2 GiB:

| program | 256 KiB | 32 MiB | 2 GiB | plain C, 2 GiB |
| --- | ---: | ---: | ---: | ---: |
| `heavy` | 7.5 ns | 18.5 ns | 38.2 ns | 35 to 38 ns |
| `hash` | 12.9 ns | 32.3 ns | 88.0 ns | 101 ns |
| `gather` | 0.9 ns | 7.0 ns | 30.5 ns | 21 to 22 ns |
| `tree` | 53 ns | 604 ns | 2049 ns | 1940 to 2228 ns |
| `chains` | 12.2 ns | 211 ns | 766 ns | 633 to 664 ns |

Zane's loops are where C's are: the index checks cost little next to the
misses.

**The prefetch.** `lib/codegen/lookahead.ml` (docs/optimizations.md,
"Reads through a loaded index prefetched ahead") prefetches, 32 iterations
ahead, a list element a loop reads at an index made from another list's
element, when the loop's body branches or loops. It applies to `heavy`
(`recs[idx[i]]`) and to `hash` (the probe's home slot, worked out from
`queries[i]`), and leaves `gather` (no branch), `tree` (its first read is
the root, the same each time) and the walk of `chains` alone. Its early
reads are each made only when the index is inside the list, so nothing it
reads early can stop a program.

Measured with `time.py --pair prefetch ZANE_PREFETCH`: the same compiler
builds each program with the prefetch and with `ZANE_PREFETCH=0`, and the
two builds' runs alternate, five each, so a neighbour slows both alike.
Best run, and the median run in brackets, of the prefetch over the build
without it (`results/zane-prefetch.tsv`, `zane-prefetch-off.tsv`):

| program | 256 KiB | 32 MiB | 2 GiB |
| --- | --- | --- | --- |
| `heavy` | ×0.86 (×1.03) | ×1.88 (×1.88) | ×1.72 (×1.76) |
| `hash` | ×1.08 (×1.07) | ×1.89 (×1.60) | ×2.55 (×2.50) |
| `gather`, the same binary twice | ×0.99 (×0.87) | ×0.99 (×1.00) | ×0.83 (×0.80) |
| `chains`, the walk the same twice | ×0.98 (×0.73) | ×0.86 (×0.93) | ×1.00 (×1.01) |

`gather`'s two builds are byte for byte the same program and `chains`'
differ only in the loop that builds the data, so their rows are the noise
of five runs here: as much as 20% at 2 GiB and 27% on the median at
256 KiB. `heavy`'s ×0.86 in cache was within it, and did not repeat: with
11 runs of each (`time.py --pair prefetch-small`, `TIME_SIZES=18,20,21,22,23`,
`results/zane-prefetch-small*.tsv`):

| program | 256 KiB | 1 MiB | 2 MiB | 4 MiB | 8 MiB |
| --- | --- | --- | --- | --- | --- |
| `heavy` | ×1.03 (×1.02) | ×1.17 (×1.12) | ×1.31 (×1.35) | ×1.36 (×1.37) | ×1.45 (×1.53) |
| `hash` | ×1.06 (×1.09) | ×1.13 (×1.20) | ×1.38 (×1.31) | ×1.20 (×1.45) | ×1.53 (×1.63) |

**What it shows.**

- The prefetch gives in `zanec` what it gave in the model: ×1.7 to ×1.9
  for `heavy` from 32 MiB (model ×1.56 to ×2.0 with 4 KiB pages) and
  ×1.9 to ×2.5 for `hash` (model ×2.77 at 2 GiB). It is not slower at any
  size measured, so it needs no gate, as the model said.
- The first version also prefetched the head of each chain in `chains`,
  through the walk's cursor's first value. Measured one build after the
  other rather than in turn, it was ×1.07 at 2 GiB, but ×0.75 at 32 MiB and
  ×0.66 at 256 KiB against the plain build's earlier run. Those runs were
  not paired, and a later pair shows the plain loop alone moving that much,
  so the loss is not established; the model had already found the head
  worth nothing (round 2, ×1.00), and the pass now leaves a walk alone: a
  local the body reassigns from an element it reads is a chain's cursor.
  It first did so for the hash probe's cursor too, through that cursor's
  own `let`, which lost `hash` its prefetch until the test skipped the
  local's own binding.
- The first version also prefetched `hist[h & 15]` in `heavy`, through the
  `let` of `h` before the hash steps that reassign it: a wrong address, and
  a list that is always in cache. A local is now taken at its `let`'s value
  only when the body reassigns it in a loop inside it, as a probe's cursor
  is, and nowhere else.
- Runs of one build sweep after another were not good enough here. With
  the data at 32 MiB in a 260 MiB L3 shared with other tenants, the same
  binary measured 211 ns, 281 ns and 311 ns per walk on three runs.
  Alternating the builds run by run, and reading the median beside the
  best, is what the numbers above rest on.
- No program in `tests/perf` gets a prefetch, so the Callgrind numbers CI
  holds are unchanged by it.

## Round 6: huge pages in the runtime

The request measured here is not on `main`: it stays on the
`prefetch-reorder-experiment` branch while it is measured further.

`zane_huge` (`runtime/region.c`) asks Linux for huge pages
(`madvise(MADV_HUGEPAGE)`) over a list's reservation when it is 2 MiB or
more, where `zane_alloc_growable` makes it. `ZANE_HUGE=0` in the program's
environment leaves it out. Only a list's block above 1 MiB is covered: the
1 MiB chunks that hold smaller blocks and boxes are too small for a 2 MiB
page. All five programs keep their data in such lists. Checked on a running
`gather` at 2 GiB: 2,160,640 kB of its 2,166,424 kB resident were huge
pages with the request, and 0 kB with `ZANE_HUGE=0`.

`time.py --pair-run huge ZANE_HUGE` builds each program once and times it
in turn with the request and with `ZANE_HUGE=0`, five runs each, on the
branch's compiler (prefetch on). `ZANE_PREFETCH=0 time.py --pair-run
huge-nopf ZANE_HUGE heavy hash` does the same for builds without the
prefetch. Same machine as round 5. Speed with huge pages over without,
best run and the median in brackets (`results/zane-huge*.tsv`):

| program | 256 KiB | 32 MiB | 2 GiB |
| --- | --- | --- | --- |
| `gather` | ×1.08 (×1.08) | ×1.16 (×1.14) | ×2.61 (×2.56) |
| `heavy` | ×1.03 (×1.03) | ×0.98 (×1.02) | ×1.63 (×2.44) |
| `heavy`, no prefetch | ×1.06 (×1.02) | ×1.03 (×1.08) | ×1.16 (×1.18) |
| `hash` | ×0.91 (×1.00) | ×1.01 (×1.02) | ×1.11 (×1.09) |
| `hash`, no prefetch | ×1.01 (×0.98) | ×1.15 (×1.41) | ×1.43 (×1.27) |
| `chains` | ×0.99 (×1.00) | ×1.15 (×1.22) | ×1.26 (×1.41) |
| `tree` | ×1.00 (×1.00) | ×1.81 (×1.06) | ×1.39 (×1.28) |

At 256 KiB no list reaches 2 MiB, so both runs are the same program and
the column is the noise of five runs.

`heavy` and `hash` at 2 GiB, each form's best time, the pairs with and
without the prefetch being separate sweeps:

| program | plain | huge pages | prefetch | both |
| --- | ---: | ---: | ---: | ---: |
| `heavy` | 39.4 ns | 34.0 ns, ×1.16 | 16.9 ns, ×2.33 | 10.4 ns, ×3.81 |
| `hash` | 96.6 ns | 67.4 ns, ×1.43 | 36.1 ns, ×2.68 | 32.4 ns, ×2.98 |

**What it shows.**

- The light loop gains what the model said: `gather` ×2.6 at 2 GiB (model
  ×2.7). Nothing else measured helps that loop.
- Every program is faster at 2 GiB, by ×1.1 to ×1.6, and none is slower at
  any size beyond the noise.
- For `heavy` the two multiply, as in the model: ×1.16 from huge pages
  alone, ×2.33 from the prefetch alone, ×3.81 from both. For `hash` they do
  not: the prefetch already hides most of what huge pages save (×1.11 on
  top of it, against ×1.43 without it).
- `tree` at 32 MiB is ×1.81 on the best run and ×1.06 on the median: not
  established.
- The times above are the loop's alone. Getting the pages has a cost that
  lands on building the data. Three whole runs of `gather` at 2 GiB each
  way, a single pass, took 4.09 s, 2.19 s and 1.81 s with the request and
  1.83 s, 1.80 s and 1.75 s without: the first run waited over 2 s for the
  system to make huge pages free, and a loop of 0.07 s against 0.18 s does
  not pay that back. A program that reads its data many times gains; one
  that builds a large list and reads it once may lose.

**Not measured.** A list that is reserved large and touched sparsely, where
a huge page takes 2 MiB of memory for one touched byte; a system with
transparent huge pages off, where the request does nothing, or set to
`always`, where it is already made; macOS and Windows, where this is not
the mechanism.

## Round 7: the prefetch on `main`, searches written as functions

`main` now writes out a small search a loop calls (a walk,
[`design/lowering.md`](../../design/lowering.md) L11), so `probe`, `find`
and `walk` are plain functions here, with no block. Every program prints
the same checksum as with the block at 2^18 and 2^22 bytes, and the
optimized build of `heavy` and of `hash` still has its two prefetches.

`time.py --pair main-natural ZANE_PREFETCH heavy hash`, on the compiler at
this round's commit over `main` at `e58b8a6`: each program built as it is
and with `ZANE_PREFETCH=0`, the two timed in turn, five runs each per size,
on the machine of round 5 (Xeon at 2.1 GHz, 4 cores, 4 KiB pages). Speed
with the prefetch over without, best run and the median in brackets
(`results/zane-main-natural*.tsv`):

| program | 256 KiB | 32 MiB | 2 GiB |
|---|---|---|---|
| `heavy` | ×1.04 (×1.04) | ×2.12 (×2.08) | ×1.96 (×1.79) |
| `hash` | ×1.14 (×1.14) | ×1.89 (×1.96) | ×2.68 (×2.50) |

These are round 5's gains, now on the search as it is naturally written.
Neither program is slower at any size. Every `tests/perf` program builds
the same plain and optimized IR as on `main`, and the same tiered
executable and tier 1 to the byte, so none of the Callgrind numbers CI
holds moves.

## Round 8: where interleaving starts to pay (the size gate)

The sweep the design asks for before the pass lands
([`design/interleaving.md`](../../design/interleaving.md) I5): `chains` and
`tree` in the model, plain (`base`) against interleaved (`amac`, the best
of W = 4 to 128), at every power of two from 64 KiB to 256 MiB, 4 KiB
pages. `run.py --sweep LABEL chains tree`, each point the best of 3 runs
of 2^21 operations, pinned to the last CPU. The whole sweep was run twice
(`results/sweep-gate-a.tsv`, `results/sweep-gate-b.tsv`) on a 4-core Xeon
at 2.3 GHz with 2 MiB of L2 per core (a different host from rounds 5 to 7,
which ran at 2.1 GHz). Speed of `amac` over `base`, run A / run B:

| bytes | `chains` | `tree` |
|---|---|---|
| 64 KiB | ×0.68 / ×0.69 | ×1.23 / ×1.21 |
| 128 KiB | ×0.89 / ×0.87 | ×1.38 / ×1.45 |
| 256 KiB | ×0.94 / ×0.97 | ×1.53 / ×1.50 |
| 512 KiB | ×1.99 / ×1.85 | ×1.75 / ×1.67 |
| 1 MiB | ×1.59 / ×1.74 | ×1.98 / ×1.70 |
| 2 MiB | ×4.64 / ×3.22 | ×2.20 / ×2.61 |
| 4 MiB | ×3.22 / ×3.97 | ×2.53 / ×4.73 |
| 8 MiB | ×9.77 / ×7.16 | ×4.80 / ×6.74 |
| 16 MiB | ×5.30 / ×5.47 | ×8.96 / ×8.89 |
| 32 MiB | ×5.92 / ×3.38 | ×5.35 / ×7.86 |
| 64 MiB | ×6.62 / ×4.81 | ×8.55 / ×11.14 |
| 128 MiB | ×7.66 / ×3.95 | ×11.17 / ×7.50 |
| 256 MiB | ×5.39 / ×6.97 | ×9.72 / ×9.79 |

Both runs put the crossing for the short chains (1 to 15 links) between
256 KiB and 512 KiB, below the L2's 2 MiB, not at it as I5 expected: the
chains' nodes are 16 bytes in random places, so a 512 KiB list already
misses the L1 and the L2's nearby lines on most links. `tree`, whose walk
is up to 64 steps and branches on every key it reads, gains at every size,
from ×1.2 at 64 KiB. So the gate is 512 KiB of walked lists for a walk
whose count is not a constant of 32 or more, and no size gate for one
whose count is; both runs agree on each, and the run-to-run spread above
2 MiB (×3.2 to ×9.8) is the host's, not the crossing's.

## Round 9: interleaving in `zanec`

The pass of [`design/interleaving.md`](../../design/interleaving.md) I9,
`lib/codegen/interleave.ml`, on the round 8 host (4-core Xeon at 2.3 GHz,
2 MiB of L2 per core, 4 KiB pages). `found` is new: `tree`'s lookups with
each id pushed onto a list in order rather than summed, a retire half that
runs in iteration order. Every build prints the same checksum as with
`ZANE_INTERLEAVE=0` at every size.

**Attempts on the way, 3 runs per size, best run.** The raw files of these
were deleted by mistake before they were committed, so only the summaries
printed at the time are left; they are kept here because they decided W
and the retirement of sums. Speed over `ZANE_INTERLEAVE=0`:

| version | `tree` 256 KiB | `tree` 32 MiB | `chains` 256 KiB | `chains` 32 MiB |
|---|---|---|---|---|
| in order, W = 8 | ×0.96 | ×2.27 | ×0.95 | ×1.83 |
| in order, W = 16 | ×0.99 | ×2.40 | ×0.85 | ×1.57 |
| in order, W = 32 | ×0.87 | ×4.35 | ×0.93 | ×1.96 |
| in order, W = 64 | ×0.74 | ×3.97 | ×1.02 | ×1.44 |
| sums in any order, W = 32 | ×1.13 | ×5.38 | ×1.03 | ×2.63 |

Retiring every iteration in order, the slots being the ring, let a slot
whose walk finished early sit idle until the ones before it retired, which
cost `chains` most (its chains are 1 to 15 links). Sums retired as each
walk ends, as I1 allows, freed the slots and recovered `tree` in cache.
`chains` at 256 KiB runs plain behind the size gate in every row.

**The pass as built,** `time.py --pair interleave ZANE_INTERLEAVE tree
chains found`, each program built with and without `ZANE_INTERLEAVE=0`
and the two timed in turn, 5 runs each per size
(`results/zane-interleave*.tsv`). Speed interleaved over plain, best run
and the median in brackets:

| program | 256 KiB | 32 MiB | 2 GiB |
|---|---|---|---|
| `tree` | ×1.11 (×1.13) | ×5.10 (×6.17) | ×4.53 (×3.74) |
| `chains` | ×1.01 (×1.02) | ×3.27 (×3.27) | ×4.68 (×4.45) |
| `found` | ×0.83 (×0.82) | ×3.43 (×3.61) | ×5.35 (×4.50) |

`found` lost 17% in cache, where its walk, a constant 64 trips, had taken
no size gate. In-order retirement costs a check and a wait per iteration
that a sum's does not, so the exemption for long walks was narrowed to
loops that retire in any order. Measured again after that, 5 runs, `found`
at 256 KiB runs plain: ×0.99, median ×0.95 (`results/zane-interleave-gated*.tsv`).
`chains` at 256 KiB is below the gate and runs plain. The gains at 32 MiB
and 2 GiB are short of the model's `amac` (×5 to ×11 for `tree`, ×3 to
×7 for `chains` in round 8): the statements before the walk are not their
own stages (I9), and in-order loops hold slots for the slow walks.

## Where this points

Worth building, in the order the measurements rank them:

1. Interleaving a loop over independent chains (tree lookups, chains,
   binary searches): ×3 to ×10, gated on the data's size where the chain is
   short. Every miss in the iteration should be a step, the ones before the
   chain included (round 3).
2. A prefetch `D` = 32 iterations ahead in a loop whose body branches on or
   works on what it loads (`heavy`, `hash`): ×1.6 to ×2.8, no gate.
3. Huge pages for large backing stores: ×2 to ×2.7 on the light loops by
   itself, and what lets a prefetch help them at all.

Not worth building: prefetching right before the access, batching in place
of a sliding distance, loading early without a prefetch, the non-temporal
hint, a helper thread, and prefetching a chain's head alone.

**Not yet tried.** Interleaving in `zanec` (designed in
[`design/interleaving.md`](../../design/interleaving.md), not built); huge pages
for the 1 MiB chunks that hold boxes; nodes with several children to a
cache line; interleaved batches on several cores; a body between `gather` and
`heavy` in weight, to find where a prefetch starts to pay; a processor other
than this one.
