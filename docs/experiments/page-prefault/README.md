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
- **List spans** (`zane_alloc_growable` and its growth in place,
  `zane_extend`): every other program's. A span commits its list's current
  room, rounded up to a chunk, and each doubling in place commits the new
  tail (growth: 1.3 GB over 20 lists of 64 MiB); the list touches it as it
  fills, so a span's faults are its touched pages, 2 MiB at a time once
  huge pages apply.
- **Frames**: one 1 MiB step per program, part of the floor.
- Cold chunk reuse and pools: none in these programs.

**What it means.** The ceiling for any prefault scheme is the share column:
up to about 8% on allocation-heavy programs in this VM, under 1% on
`stress`. Synchronous bulk population can win about a third of that (2–3%),
and only where the populated pages are all touched: a fresh chunk always is
(a region fills it before taking the next), a span only up to its list's
length.

## Step 2: populate on commit, synchronously

**Design.** `ZANE_PREFAULT` (`runtime/region.c`, `zane_prefault`), read
once: `chunks` populates a dynamic chunk with one `MADV_POPULATE_WRITE`
where it is made usable, fresh (`zane_chunks_new`) or cold (`zane_map`'s
recommit); `spans` a list span's committed room (`zane_alloc_growable`) and
each tail it grows by (`zane_extend`); `all` both. Unset, nothing changes
but one `pthread_once` check per commit. Left lazy: the frame range, whose
1 MiB steps a program touches 4 KiB at a time (populating one would cost
the floor 256 pages a context), and the experimental unbounded pools
(`zane_alloc_unbounded`), which commit 2 GiB. Linux only; elsewhere, and
on a kernel before 5.14, the switch does nothing. `just test-compiler`
passes with it unset and with `ZANE_PREFAULT=all`.

**Measuring.** The kernel counts each page `MADV_POPULATE_WRITE` fills as a
minor fault, and the program's later touch as none (checked with a 64 MiB
mapping: 16,384 faults in the populate, 0 in the touch after), so the
fault count no longer shows traps saved. `compare.py N [PROGRAMS [MODES]]`
runs each setting N rounds, interleaved, and reports median and best wall
and CPU time.

**Results.** `compare.py 15`, all four settings (`step2.tsv`), median wall:

| program | off | chunks | spans | all | RSS off → spans |
| --- | --- | --- | --- | --- | --- |
| growth ×20 | 0.173 s | 0.174 s | 0.139 s | 0.172 s | 66.6 → 68.7 MB |
| tokens ×20 | 0.095 s | 0.095 s | 0.094 s | 0.094 s | 89 → 105 MB |
| bits ×20 | 0.218 s | 0.215 s | 0.225 s | 0.224 s | 96 → 201 MB |
| nodes ×20 | 0.112 s | 0.112 s | 0.113 s | 0.113 s | 14.8 → 19.7 MB |
| stress ×10 | 1.589 s | 1.570 s | 1.661 s | 1.643 s | 20.9 → 24.3 MB |
| paths ×5 | 0.094 s | 0.094 s | 0.094 s | 0.094 s | 34 → 41 MB |
| returns ×1.25 | 0.111 s | 0.109 s | 0.108 s | 0.111 s | — |
| handover ×20 | 0.136 s | 0.136 s | 0.163 s | 0.164 s | — |
| spans ×20 | 0.056 s | 0.055 s | 0.058 s | 0.059 s | — |

`spans` loses: it fills room the list never reaches (a list's room is up
to twice its length, bits' RSS doubles), and on handover and spans, which
reuse kept spans, it adds a populate per round that the reuse had made
unnecessary (+19%, +4%). growth's 20% is not reproduced by `all`, and its
times move by 30% between runs of one setting: noise. Dropped.

`chunks` against off, 60 rounds (`step2-chunks.tsv`):

| program | wall median | wall best | RSS |
| --- | --- | --- | --- |
| returns ×1.25 | 0.1100 → 0.1056 s (−4%) | 0.0887 → 0.0869 s | 24.2 → 25.0 MB |
| stress ×10 | 1.4088 → 1.4009 s (−0.6%) | 1.2849 → 1.2575 s | 21.0 → 22.7 MB |
| tokens ×20 (no chunks) | 0.0903 → 0.0891 s | 0.0846 → 0.0862 s | same |
| copies ×1.15 | 0.0099 → 0.0107 s | 0.0092 → 0.0089 s | same |

tokens takes no fresh chunk, so its ±1–2% is this machine's noise; copies
runs 10 ms, too short to read. returns, whose extra faults are all fresh
chunks, gains about 4%, matching step 1's estimate (a third of an 8% fault
share). The cost is a chunk's untouched pages made resident: a region's
last chunk is only partly filled (stress +1.7 MB).

## What remains

- `chunks` is a small, real gain (up to ~4%) only on programs that take
  many fresh chunks, at up to a chunk of RSS per region's last chunk. It
  could go in by default with the populate limited to the chunk's first
  part, or left as it is.
- On returns the other two thirds of the fault share (~5% of its time)
  are the kernel getting and zeroing pages, which only a helper thread
  keeping a populated spare chunk could take off the program's thread
  (step 3 of the plan, not started at the user's request).
