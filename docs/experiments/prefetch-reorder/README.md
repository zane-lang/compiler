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

## Round 10: whether to ask for huge pages by default, and from what size

Measured on the `prefetch-reorder-experiment` branch, whose compiler has
round 5's prefetch but not rounds 7 to 9, with round 6's request built in.
What it concludes is what this round brings to `main`: `zane_huge` in
`runtime/region.c`, asking for a list's block of 32 MiB or more.

**What the 2 MiB test tests.** `zane_huge` compares its 2 MiB with the
list's *reservation*, and `zane_alloc_growable` reserves 64 times the
block's span (`ZANE_HEADROOM`), so the reservation is at least 64 MiB for
any block it makes. The test is always true: every list whose block passes 1
MiB asks for huge pages, as it did in round 6. Huge pages also come only
where a 2 MiB-aligned range is wholly inside the part of the reservation
made usable (`mprotect` splits the mapping), and the block starts at a 1 MiB
boundary, so a 3 MiB block holds one huge page, not one and a half. Two
things follow for round 6. Its 256 KiB column was not the same program both
ways: the indices or keys every program reads in its loop (2^23 of them, 64
MiB, in `gather`, `heavy` and `hash`; 2^21, 16 MiB, in `chains` and `tree`)
are in huge pages at every size. And its loops' data lists are built by
`zane_list_room` at their full size at once, while a list a loop does not
fill that way doubles its room in place as it grows (`sparse` below).

For the threshold, this round adds `ZANE_HUGE_MIN=N` (bytes, read once from
the program's environment): the request is made when the list's *block*
reaches N bytes, when it is made or as it grows in place (`zane_extend`),
and a kept reservation taken again by a block under N is told
`MADV_NOHUGEPAGE`. While this round measured, unset, `zane_huge` did what
round 6 built; on `main` it stays, over a default of 32 MiB, for measuring.

**Machine.** A different cloud machine from rounds 5 and 6: a Firecracker
VM, 4 vCPUs of a Xeon at 2.3 GHz, 504 MiB of L3 reported, 16 GiB of memory
with the session's processes held to 13.35 GiB by a cgroup, no swap, Linux
6.18. Transparent huge pages `enabled` `[madvise]`, `defrag` `[madvise]`,
khugepaged `defrag` 1, `max_ptes_none` 511. The VM gives free memory back to
its host (`virtio_balloon`, `page_reporting_order=11`), which turns out to
matter. When this round started 7 GiB of the memory was page cache from
setting up the toolchain. Same compiler as round 6, prefetch on.

**1. The loop.** `TIME_SIZES=21,...,31 TIME_RUNS=7 time.py --pair-run huge7
ZANE_HUGE`: each program built once and timed with huge pages and with
`ZANE_HUGE=0` in turn, seven runs each, at every power of two from 2 MiB to
2 GiB. Speed with huge pages over without, best run and median in brackets
(`results/zane-huge7*.tsv`):

| size | `gather` | `heavy` | `hash` | `chains` | `tree` |
| --- | --- | --- | --- | --- | --- |
| 2 MiB | ×1.12 (×1.11) | ×1.09 (×1.11) | ×1.07 (×1.06) | ×1.24 (×1.22) | ×1.12 (×1.08) |
| 4 MiB | ×1.03 (×1.06) | ×1.08 (×1.06) | ×1.04 (×1.03) | ×1.15 (×1.14) | ×1.09 (×1.09) |
| 8 MiB | ×0.93 (×1.06) | ×1.05 (×1.04) | ×1.04 (×1.04) | ×1.10 (×1.11) | ×1.10 (×1.02) |
| 16 MiB | ×1.15 (×1.21) | ×1.04 (×1.02) | ×1.04 (×1.04) | ×1.22 (×1.21) | ×0.97 (×1.27) |
| 32 MiB | ×1.33 (×1.19) | ×0.96 (×1.00) | ×1.03 (×1.01) | ×1.30 (×1.31) | ×1.33 (×1.08) |
| 64 MiB | ×1.40 (×1.14) | ×1.18 (×1.19) | ×0.98 (×0.96) | ×1.39 (×1.24) | ×1.39 (×1.17) |
| 128 MiB | ×1.69 (×1.64) | ×1.16 (×1.11) | ×0.97 (×1.04) | ×1.47 (×1.48) | ×1.21 (×1.17) |
| 256 MiB | ×1.75 (×1.58) | ×1.34 (×1.34) | ×1.04 (×1.01) | ×1.14 (×1.17) | ×1.51 (×1.29) |
| 512 MiB | ×1.87 (×1.76) | ×1.62 (×1.59) | ×1.05 (×0.96) | ×1.24 (×1.28) | ×1.31 (×1.11) |
| 1 GiB | ×2.14 (×2.05) | ×1.85 (×1.92) | ×1.02 (×1.28) | ×1.21 (×1.23) | ×1.18 (×1.31) |
| 2 GiB | ×2.14 (×1.65) | ×1.45 (×1.88) | ×1.06 (×1.18) | ×1.28 (×1.16) | ×1.44 (×1.46) |

There is no size in the range below which nothing is gained. From 2 MiB to
16 MiB the gain is ×0.93 to ×1.24 on the best run and ×1.02 to ×1.27 on the
median, small but not noise (`chains` ×1.22 and `gather` ×1.11 at 2 MiB). It
grows from 32 MiB: `gather` ×1.3 at 32 MiB and ×2.1 at 1 GiB, `heavy` ×1.2
at 64 MiB and ×1.9 at 1 GiB, `chains` and `tree` ×1.2 to ×1.5 from 32 MiB.
`hash` gains ×1.0 to ×1.07 at every size (round 6: ×1.11 at 2 GiB): the
prefetch hides what huge pages would save. Nothing is slower beyond noise;
the cells under ×1.0 have medians of ×0.96 to ×1.06 or best runs above ×1.

**2. The whole run.** `whole.py` (new) times a run from before the process
is made to after it has exited, and splits it at `ready` into building the
data and the loop. One pass (`WHOLE_PASSES=1`), the two ways in turn with
the one that goes first alternating, and `/proc/vmstat`'s compaction and
huge-page counters read around each run. On the machine as the loop sweep
left it (`whole.py settled`, seven runs each way, every size;
`results/whole-settled.tsv`), medians:

| program | size | whole run, with / without | building, with − without | loop, with / without | passes to pay |
| --- | --- | ---: | ---: | ---: | ---: |
| `gather` | 2 MiB | 0.041 / 0.053 s | -12 ms | 13 / 12 ms | 0 |
| `gather` | 16 MiB | 0.079 / 0.110 s | -16 ms | 43 / 52 ms | 0 |
| `gather` | 128 MiB | 0.122 / 0.195 s | -40 ms | 50 / 80 ms | 0 |
| `gather` | 512 MiB | 0.452 / 0.522 s | +25 ms | 66 / 137 ms | 0.4 |
| `gather` | 1 GiB | 0.906 / 0.944 s | +107 ms | 81 / 190 ms | 1.0 |
| `gather` | 2 GiB | 1.453 / 1.507 s | +106 ms | 79 / 183 ms | 1.0 |
| `heavy` | 2 MiB | 0.086 / 0.105 s | -13 ms | 55 / 58 ms | 0 |
| `heavy` | 16 MiB | 0.102 / 0.124 s | -16 ms | 66 / 70 ms | 0 |
| `heavy` | 128 MiB | 0.165 / 0.230 s | -49 ms | 75 / 90 ms | 0 |
| `heavy` | 512 MiB | 0.358 / 0.533 s | -128 ms | 95 / 128 ms | 0 |
| `heavy` | 1 GiB | 0.812 / 0.957 s | -9 ms | 111 / 186 ms | 0 |
| `heavy` | 2 GiB | 1.679 / 1.600 s | +270 ms | 120 / 213 ms | 2.9 |
| `hash` | 2 MiB | 0.178 / 0.191 s | -8 ms | 112 / 116 ms | 0 |
| `hash` | 16 MiB | 0.201 / 0.223 s | -14 ms | 132 / 137 ms | 0 |
| `hash` | 128 MiB | 0.441 / 0.549 s | -68 ms | 234 / 264 ms | 0 |
| `hash` | 512 MiB | 1.131 / 1.279 s | -88 ms | 267 / 304 ms | 0 |
| `hash` | 1 GiB | 1.951 / 2.203 s | -168 ms | 257 / 296 ms | 0 |
| `hash` | 2 GiB | 4.172 / 4.311 s | +109 ms | 288 / 344 ms | 1.9 |
| `chains` | 2 MiB | 0.088 / 0.104 s | -2 ms | 72 / 86 ms | 0 |
| `chains` | 16 MiB | 0.418 / 0.471 s | -8 ms | 376 / 420 ms | 0 |
| `chains` | 128 MiB | 1.260 / 1.253 s | -52 ms | 1006 / 947 ms | 0 |
| `chains` | 512 MiB | 2.990 / 3.200 s | -242 ms | 1246 / 1284 ms | 0 |
| `chains` | 1 GiB | 5.578 / 5.880 s | +202 ms | 1332 / 1642 ms | 0.7 |
| `chains` | 2 GiB | 10.663 / 12.661 s | -964 ms | 1256 / 1967 ms | 0 |
| `tree` | 2 MiB | 0.171 / 0.195 s | -4 ms | 153 / 174 ms | 0 |
| `tree` | 16 MiB | 0.550 / 0.691 s | -8 ms | 498 / 622 ms | 0 |
| `tree` | 128 MiB | 2.522 / 3.333 s | -61 ms | 1850 / 2597 ms | 0 |
| `tree` | 512 MiB | 5.560 / 6.570 s | -143 ms | 2494 / 3029 ms | 0 |
| `tree` | 1 GiB | 7.853 / 9.654 s | -709 ms | 2319 / 3541 ms | 0 |
| `tree` | 2 GiB | 15.895 / 17.648 s | -1193 ms | 3380 / 3628 ms | 0 |

"Passes to pay" is the building's extra time over the loop's gain per pass,
from the medians; 0 where building is no slower. Under 512 MiB building is
faster with huge pages for every program, and from 512 MiB in 9 of 15 cases,
up to 0.27 s slower in the other 6, on the median. A 2 GiB list takes 2,000
page faults instead of 540,000, and the faults are what building spends its
system time on. Not one of the 385 runs with huge pages stalled in
compaction (`compact_stall` 0).

But at 512 MiB and up the runs with huge pages are bimodal: system time 0.2
to 0.4 s or 1.0 to 1.8 s for `gather`, with no compaction in either. The
slow ones are, in every case at 1 and 2 GiB, the runs that came straight
after a run without huge pages; whole.py makes no pause. In
`results/order.txt`, `gather` at 2 GiB builds in 0.8 s with huge pages
straight after another run with huge pages, in 0.95 to 1.26 s straight after
one without, and in 2.5 to 3.0 s after the machine sat idle for 10 s,
whatever ran before. Run after a 10 s pause each time, the two ways in turn
(`cold.py gather 31 10 8`, `results/cold.tsv`, eight runs each), both pay
it: whole runs of 4.18 s with huge pages (2.92 to 4.75) against 5.08 s
without (3.16 to 6.13), the build 4.06 s against 4.73 s. The large cost
after a pause fits memory the VM gave back to its host coming back, which a
program touching that much fresh memory pays either way, and huge pages do
not make it worse. Why a run with huge pages is slower straight after one
without is not established. Round 6's first run of 4.09 s against 1.83 s may
be the pause, with the run without huge pages going second, on memory still
warm.

To make huge pages cost something to get, `whole.py` can run each run on
fragmented memory (`WHOLE_FRAGMENT`, `programs/fragment.c`): before each
run, with huge pages and without, the page cache is dropped, a process
touches 12 GiB in 4 KiB pages and gives back 63 in 64 of them, then holds
huge pages until fewer than 16 free 2 MiB blocks are left. About 7 GiB is
then free, all in pieces of 128 KiB or less. Three runs each way at four
sizes (`results/whole-fragmented.tsv`):

| program | size | whole run, with / without | building, with − without | loop, with / without | passes to pay |
| --- | --- | ---: | ---: | ---: | ---: |
| `gather` | 8 MiB | 0.086 / 0.149 s | -22 ms | 42 / 73 ms | 0 |
| `gather` | 64 MiB | 0.128 / 0.234 s | -39 ms | 64 / 123 ms | 0 |
| `gather` | 512 MiB | 0.329 / 0.512 s | -106 ms | 78 / 132 ms | 0 |
| `gather` | 2 GiB | 0.899 / 1.754 s | -586 ms | 69 / 238 ms | 0 |
| `heavy` | 8 MiB | 0.112 / 0.145 s | -16 ms | 68 / 80 ms | 0 |
| `heavy` | 64 MiB | 0.163 / 0.201 s | -21 ms | 89 / 100 ms | 0 |
| `heavy` | 512 MiB | 0.351 / 0.537 s | -125 ms | 87 / 124 ms | 0 |
| `heavy` | 2 GiB | 0.992 / 1.608 s | -464 ms | 106 / 182 ms | 0 |
| `hash` | 8 MiB | 0.294 / 0.298 s | +42 ms | 159 / 182 ms | 1.8 |
| `hash` | 64 MiB | 0.297 / 0.514 s | -57 ms | 152 / 304 ms | 0 |
| `hash` | 512 MiB | 1.079 / 1.208 s | -118 ms | 264 / 301 ms | 0 |
| `hash` | 2 GiB | 3.333 / 4.272 s | -853 ms | 267 / 391 ms | 0 |
| `chains` | 8 MiB | 0.385 / 0.850 s | -10 ms | 347 / 805 ms | 0 |
| `chains` | 64 MiB | 1.019 / 1.466 s | +28 ms | 748 / 1209 ms | 0.1 |
| `chains` | 512 MiB | 2.937 / 3.623 s | -462 ms | 1141 / 1430 ms | 0 |
| `chains` | 2 GiB | 7.410 / 11.035 s | -3063 ms | 1253 / 1469 ms | 0 |
| `tree` | 8 MiB | 0.491 / 1.144 s | -22 ms | 448 / 1078 ms | 0 |
| `tree` | 64 MiB | 1.473 / 2.795 s | -97 ms | 1189 / 2377 ms | 0 |
| `tree` | 512 MiB | 4.563 / 6.468 s | -957 ms | 2188 / 2947 ms | 0 |
| `tree` | 2 GiB | 12.509 / 17.769 s | -3760 ms | 3134 / 3898 ms | 0 |

Every run with huge pages compacted: 700 to 1,150 compactions at 2 GiB, 3 to
43 at 8 to 64 MiB, at 0.3 to 0.7 s of system time for 2 GiB. Nearly all
succeeded. The first run at 2 GiB of each program had 140 fail and 45 pages
fall back to 4 KiB, and one `chains` run at 64 MiB had all 122 fail and 40
fall back. Even so, building was faster with huge pages than without except
for `hash` at 8 MiB (+42 ms, 3 runs) and `chains` at 64 MiB (+28 ms), and
the whole runs at 2 GiB were 0.6 to 5.3 s shorter on the median. Without
huge pages the loop was slower here than on the settled machine (`tree` at 8
MiB 1.08 s against 0.45 s with them), which is not explained.

**3. Break-even.** On the medians, a program pays nothing at any size:
building is faster or at most 0.27 s slower, and one pass of the loop gains
that back, except for `heavy` (2.9 passes at 2 GiB) and `hash` (1.9). The
worst case is the slowest of the seven builds with huge pages against the
median without, on the settled machine. That needs up to 5.5 passes at 512
MiB to 2 GiB for `gather`, `heavy` and `tree`, 4 to 9 for `hash`, and 4 to
10 for `chains` at 512 MiB and 1 GiB. A pass here is the program's 2^23 or
2^21 operations, not a read of every element. Under 512 MiB the slowest
build with huge pages was at most 0.2 s over the median without (`tree` at
256 MiB), and for `gather`, `heavy` and `hash` 10 ms or less. What cost time
was not compaction. It was the runs that came after a run without huge pages
or after a pause.

**4. The sparse case.** A list's block can only be touched from its start:
Zane fills a list by pushing. So the most a huge page can waste is the part
of the last 2 MiB page past the last element, at most 2 MiB a list, and it
is wasted only where a list has room it has not used. `sparse` (new) builds
64 lists of the same number of 8-byte elements, by doubling, and `sparse.py`
reads `/proc/PID/smaps_rollup` once it prints `ready`. Memory each list
holds beyond what it holds without huge pages, the share that is of the
whole, and the huge pages held, by the size of one list
(`results/sparse-lists*.tsv`):

| one list | Rss without, 64 lists | as built | `ZANE_HUGE_MIN` 8 MiB | `ZANE_HUGE_MIN` 32 MiB |
| ---: | ---: | ---: | ---: | ---: |
| 1.00 MiB | 67 MiB | +0.50 MiB (+47%), 64 MiB huge | 0, 0 MiB huge | 0, 0 MiB huge |
| 1.01 MiB | 68 MiB | +0.49 MiB (+47%), 64 MiB huge | – | – |
| 1.50 MiB | 99 MiB | +0.25 MiB (+16%), 64 MiB huge | 0, 0 MiB huge | 0, 0 MiB huge |
| 2.01 MiB | 132 MiB | 0, 64 MiB huge | – | – |
| 3.00 MiB | 195 MiB | +1.00 MiB (+33%), 128 MiB huge | 0, 0 MiB huge | 0, 0 MiB huge |
| 4.01 MiB | 260 MiB | +0.49 MiB (+12%), 128 MiB huge | – | – |
| 6.00 MiB | 387 MiB | +1.50 MiB (+25%), 256 MiB huge | +1.50 MiB (+25%), 130 MiB huge | 0, 0 MiB huge |
| 8.01 MiB | 516 MiB | +0.49 MiB (+6%), 320 MiB huge | – | – |
| 12.00 MiB | 771 MiB | +1.50 MiB (+12%), 576 MiB huge | +1.50 MiB (+12%), 448 MiB huge | 0, 0 MiB huge |
| 16.01 MiB | 1028 MiB | +0.49 MiB (+3%), 768 MiB huge | +0.49 MiB (+3%), 640 MiB huge | 0, 4 MiB huge |
| 32.01 MiB | 2052 MiB | +0.49 MiB (+2%), 1728 MiB huge | +0.49 MiB (+2%), 1600 MiB huge | +0.49 MiB (+2%), 960 MiB huge |

As built, a list of 1 MiB holds 1.5 MiB (+47%), of 3 MiB 4 MiB (+33%), of 6
MiB 7.5 MiB (+25%), and one just past a power of two nothing more: its room
has just doubled, and the new half is not yet touched. The waste is always
less than 2 MiB a list, so over the list's size it falls as the list grows:
+12% at 12 MiB, +2% at 32 MiB. The request at a threshold removes it below
the threshold. At 8 MiB the waste starts with 6 MiB lists, whose room is 8
MiB. At 32 MiB lists up to 16 MiB hold nothing more, and a 32 MiB list holds
+0.49 MiB, as without the threshold. Under a threshold the part of a list
filled before its block reached N stays in 4 KiB pages (960 MiB of 2 GiB in
huge pages at 32 MiB, against 1,728 MiB).

**5. The threshold.** `ZANE_HUGE_MIN=33554432 time.py --pair-run min32m
ZANE_HUGE` at 2 MiB to 128 MiB, seven runs each. With it, `AnonHugePages` of
`gather` at 2 MiB is 48 MiB (the index list), against 64 MiB without it and
0 with `ZANE_HUGE=0` (`results/zane-min32m*.tsv`):

| size | `gather` | `heavy` | `hash` | `chains` | `tree` |
| --- | --- | --- | --- | --- | --- |
| 2 MiB | ×0.99 (×0.89) | ×1.02 (×1.04) | ×0.99 (×1.00) | ×1.00 (×1.01) | ×0.99 (×1.00) |
| 4 MiB | ×0.97 (×1.03) | ×1.02 (×1.02) | ×0.94 (×1.00) | ×1.00 (×1.10) | ×1.00 (×1.01) |
| 8 MiB | ×1.01 (×0.98) | ×1.00 (×1.02) | ×0.99 (×1.00) | ×1.01 (×0.99) | ×1.01 (×1.01) |
| 16 MiB | ×1.00 (×1.00) | ×1.01 (×1.02) | ×1.02 (×1.04) | ×1.02 (×0.71) | ×0.99 (×0.95) |
| 32 MiB | ×1.21 (×1.20) | ×1.06 (×1.01) | ×1.03 (×1.03) | ×0.96 (×1.02) | ×0.95 (×1.01) |
| 64 MiB | ×1.20 (×1.21) | ×1.04 (×1.04) | ×1.02 (×1.03) | ×1.40 (×1.23) | ×1.04 (×1.05) |
| 128 MiB | ×1.48 (×1.57) | ×1.10 (×1.14) | ×0.95 (×0.95) | ×0.89 (×1.06) | ×1.29 (×1.15) |

As predicted, the gain at 2 to 16 MiB is gone: ×0.94 to ×1.02 on the best
run, and medians of ×0.71 to ×1.10, the spread of seven runs. With it goes
the guess that it came from the index lists, which are still in huge pages
here. It came from the small data list itself. From 32 MiB `gather` gains
×1.2 to ×1.5 as without the threshold. `chains` and `tree` gain less than
without it at 32 to 128 MiB (×0.89 to ×1.40, against ×1.2 to ×1.5). Their 16
MiB key and head lists are now under the threshold, and the seven runs'
spread is as large as the difference.

**What it shows.**

- Every program measured is faster with huge pages at every size from 2 MiB
  except `hash`, which gains ×1.0 to ×1.07: by ×1.02 to ×1.27 on the median
  under 32 MiB, and by ×1.2 to ×2.1 from 128 MiB. None is slower beyond
  noise. The whole run is shorter on the median at 53 of 55 size and program
  pairs (`heavy` at 2 GiB +79 ms, `chains` at 128 MiB +7 ms), by up to 2 s
  at 2 GiB.
- Getting the pages cost little that was found here. Compaction ran only on
  deliberately fragmented memory, and cost less than the faults it saved. A
  run after a pause pays seconds at 2 GiB, and a run without huge pages pays
  the same. A run with them straight after one without can build up to 0.5 s
  slower at 2 GiB, for a reason not established, which 1 to 10 passes pay
  back.
- The cost is memory: under 2 MiB a list, which is up to +47% for lists of 1
  to 2 MiB and +25% to +33% for lists of 3 to 6 MiB. A threshold on the
  block's size bounds it at 2 MiB over the threshold, and gives up exactly
  the gain below it.
- Round 6's 2 MiB test does nothing, because it tests the reservation, 64
  times the block.

**Not measured.** A machine that is not a VM giving memory back to its host;
memory nearly full, where the request must reclaim (the cgroup leaves about
2 GiB of room past the largest program here); `defrag` set to `always`,
`defer` or `never`; khugepaged over a long run, which with `max_ptes_none`
511 can turn a 2 MiB range with one touched page into a whole huge page (a
list's touched part is its start, so this may add nothing to the waste
above, but it was not watched); many threads making lists at once; the 1 MiB
chunks that hold boxes; macOS and Windows.

**Recommendation.** Ask by default, for a list's block of 32 MiB or more,
checked when the block is made and as it grows in place, with `ZANE_HUGE=0`
kept as the way out. Fix the test so that it is on the block, not the
reservation. From 32 MiB the loop's gain rises to ×1.2 to ×2.1 at 128 MiB
and up for every program but `hash`, and the whole run was shorter on the
median at 53 of 55 sizes and programs. The memory it can cost is under 2 MiB
a list, at most 6% of a list that size. Under 32 MiB the gain is ×1.02 to
×1.27, and a program holding many lists of 1 to 6 MiB could pay 25% to 47%
more memory for it. A runtime that makes every program's memory larger by up
to half, for a tenth of speed, is worse than one that leaves it alone. 8 MiB
is the other defensible choice: it keeps the ×1.02 to ×1.27 of 8 to 16 MiB
for a bound of 25%. Below 8 MiB do not ask. Nothing here argues for keeping
it opt-in, but the evidence is one VM with `madvise` defrag, so the default
should be checked on a machine that is not a VM before it ships.

**On `main`.** The runtime now asks by default for a list's block of 32 MiB
or more, made or grown in place (`zane_huge` in `runtime/region.c`), and
round 6's test on the reservation is not brought over. A list's block never
shrinks on `main`, so a kept reservation a list takes again needs nothing
undone; one an unbounded pool takes, whose pages it touches only here and
there, is told `MADV_NOHUGEPAGE`. No program in `tests/perf` makes either
request. `ZANE_HUGE=0` still leaves the request out, and `ZANE_HUGE_MIN=N`
moves the threshold, for measuring. Checked on running programs: `gather`
with 16 MiB of data holds 64 MiB of huge pages (its 64 MiB index list, not
the data) and with 2 GiB 2,112 MiB; 64 `sparse` lists of 1 and 12 MiB hold
none and the same Rss as with `ZANE_HUGE=0`; 64 of 32 MiB hold 960 MiB of
huge pages and 32 MiB more.

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
   Round 10 finds getting them costs little time: building is up to
   0.27 s slower on the median at 2 GiB, and compacts on fragmented
   memory, and the loop pays that back within three passes. It asks for
   them by default for a list's block of 32 MiB or more.

Not worth building: prefetching right before the access, batching in place
of a sliding distance, loading early without a prefetch, the non-temporal
hint, a helper thread, and prefetching a chain's head alone.

**Not yet tried.** Statements before a walk as their own stages, and
calls and leaves in interleaved loops (the gaps of
[`design/interleaving.md`](../../design/interleaving.md) I9); huge pages
for the 1 MiB chunks that hold boxes; nodes with several children to a
cache line; interleaved batches on several cores; a body between `gather` and
`heavy` in weight, to find where a prefetch starts to pay; a processor other
than this one.
