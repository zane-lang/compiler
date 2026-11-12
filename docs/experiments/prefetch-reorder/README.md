# Prefetching and reordered random access

Whether the compiler can keep a program from waiting on memory when it reads
or writes at addresses the hardware cannot predict, by computing addresses
early and fetching them before they are used. This is a C model of the code
shapes the compiler could emit, not a change to `zanec`: `model.c` holds each
kernel written plainly and in every reordered form, with Zane's index checks
and 32-bit handles, and `run.py` sweeps it.

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

**Not yet tried.** Any of this in `zanec`; nodes with several children to a
cache line; interleaved batches on several cores; a body between `gather` and
`heavy` in weight, to find where a prefetch starts to pay; a processor other
than this one.
