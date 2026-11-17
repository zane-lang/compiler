# Page prefault

Whether the runtime should fault fresh pages in ahead of use: first by
populating them in bulk, synchronously, where the runtime takes fresh
memory (step 2), and later, only if a gap remains, by a helper thread that
keeps a populated spare chunk ready (not started). Step 1 measures what is
left to gain.

Measured with `measure.py`, which builds each `tests/perf` program with
`--optimize` into `_build/page-prefault/` and runs it, reporting the run's
minor faults (`getrusage` of the child, the same on every run) and the best
wall time of N runs. `--scale S` multiplies the program's `arguments`
(`--scale 0` runs it at size 1: the startup floor), `--env K=V` passes a
switch, `--reuse` skips the build. Compiler at 727e1bd, the pixi
environment's clang 21, Linux 6.18 in a cloud VM (Intel Xeon @ 2.30 GHz, 4
cores), transparent huge pages on `madvise`. Wall times are from a shared
container: a few percent of noise.

## Step 1: what the remaining faults are and cost

**One fault's cost.** `faultcost.c` touches 256 fresh 1 MiB chunks a byte
per page, and again after one `MADV_POPULATE_WRITE` per chunk:

| way | ns per 4 KiB page (3 runs) |
| --- | --- |
| first-touch fault | 1423, 1742, 1247 |
| `MADV_POPULATE_WRITE` | 958, 1161, 882 |

So in this VM a fault costs about 1.4 µs, and populating in bulk saves about
a third of it: most of the cost is getting and zeroing the page, which bulk
population still pays. Only taking the population off the program's thread
(a helper) could remove the rest.

**Fault counts.** At the perf sizes (`baseline.tsv`) nearly every program
takes its startup floor of about 90 faults (`floor.tsv`), and runs in a few
ms. The programs whose faults grow with their size, run larger
(`baseline-big.tsv`):

| program | scale | faults | floor | wall | faults' share at 1.4 µs |
| --- | --- | --- | --- | --- | --- |
| growth | ×20 | 5,834 | 90 | 0.109 s | 7% |
| tokens | ×20 | 4,992 | 92 | 0.088 s | 8% |
| bits | ×20 | 4,523 | 88 | 0.202 s | 3% |
| nodes | ×20 | 3,227 | 90 | 0.109 s | 4% |
| paths | ×5 | 5,076 | 88 | 0.082 s | 8.5% |
| returns | ×1.25 | 5,650 | 128 | 0.098 s | 8% |
| copies | ×1.15 | 1,118 | 86 | 0.010 s | 15% |
| stress | ×10 | 10,481 | 4,637 | 1.402 s | 0.6% |
| handover | ×20 | 875 | 481 | 0.132 s | ~0 |
| spans | ×20 | 722 | 406 | 0.043 s | ~0 |

`handover` and `spans` do not grow: the kept spans and warm spare chunks
already serve their refills. Huge pages already do most of the work for
large lists: with `ZANE_HUGE=0`, growth ×20 takes 312,614 faults and 0.467 s
instead of 5,834 and 0.109 s, tokens 21,349.

**Where they come from.** `stats.patch` (applied only for this count, not
committed) counts the bytes each `zane_commit_range` caller commits, printed
at exit under `ZANE_FAULT_STATS=1`:

- **Fresh chunks** (`zane_chunks_new`): `returns` 22 chunks, `copies` 4,
  `stress` 2. `returns`' extra faults, 5,522, are its 22 MiB at 4 KiB a
  page, every page touched.
- **List spans** (`zane_alloc_growable` and its growth in place): every
  other program's. A span commits its whole reservation at once (growth:
  1.3 GB over 20 spans) and is touched as the list fills, so its faults are
  its touched pages, 2 MiB at a time once huge pages apply.
- **Frames**: one 1 MiB step per program, part of the floor.
- Cold chunk reuse and pools: none in these programs.

**What it means.** The ceiling for any prefault scheme is the share column:
up to about 8% on allocation-heavy programs in this VM, under 1% on
`stress`. Synchronous bulk population can win about a third of that (2–3%),
and only where the populated pages are all touched: a fresh chunk always is
(a region fills it before taking the next), a span only up to its list's
length.

## What remains

- Step 2: populate a fresh chunk with `MADV_POPULATE_WRITE` when
  `zane_chunks_new` makes one, and a span's next stretch when its list
  grows into it, behind a switch; measure faults and wall time on the
  programs above.
- A helper thread keeping a populated spare chunk (step 3 of the plan):
  only if step 2 leaves a measurable gap.
