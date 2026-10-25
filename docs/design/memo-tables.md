# Memo table layouts, measured

The layouts a remembered function's table ([`memoization.md`](memoization.md)
M2) was measured in before it became a direct-mapped table of at most
256 KiB. They are recorded because the reasoning that recommends each of them
is sound until it is measured, so each gets proposed again.

## How they were measured

Every layout ran the 21 programs of [`dev/bench/memo/`](../../dev/bench/memo/README.md)
(all but `corefib`), optimized, in two ways:

- **Estimated cycles** under Callgrind, by `dev/bench/memo/run`. Its model
  has a 32 KiB first-level and an 8 MiB last-level cache and nothing
  between, and it counts no time in the kernel.
- **Wall clock** on an x86-64 container (Xeon, 2.8 GHz, 32 KiB L1d and
  1 MiB L2 a core, 33 MiB L3): the least of 40 runs pinned to one core, the
  layouts' runs interleaved in a random order. A run includes about 2.5 ms
  of process start, and differences under about 0.3 ms are noise.

The two agree on which layout wins each program. Callgrind puts the
estimate for a big table too low, since it counts neither the second-level
cache nor the kernel's first write to each page, and on the 2–15 ms runs
here those writes are most of a big table's cost.

Three programs decide between layouts; the others moved by less than the
noise in every layout:

- **`ttt`** asks for more positions than a 64 KiB table holds, and asks for
  them again, so it gains from every entry added.
- **`loopleaf`** asks for the same 64 arguments over and over. With 2048
  entries a few of them share an entry and evict each other on every round,
  so they never hit.
- **`overlap`** grows 4000 trees whose neighbours share subtrees. It makes
  68,286 lookups of 36,036 distinct arguments, and every layout missed
  within 0.4% of 36,036 times: each miss is an argument's first call. No
  layout can raise its hits, and its calls are cheap, so it measures what a
  lookup costs.

## The layouts

Percentages are estimated cycles against the table each layout was tried
against: 64 KiB, direct-mapped, each entry a tag (the hash with its low bit
set), the arguments, the result and the work.

### A seeded hash

Hashing from a seed other than 0 moved `loopleaf`'s 64 arguments off the
62 entries seed 0 gives them, and it ran 60% faster, but the random programs
of `dev/bench/memo/random-seeds` ran a median of 0.10% slower. A seed only
moves which arguments share an entry.

### Two-way: two neighbouring entries a set

A lookup probes the first entry of its set and the second only when the
first misses; a miss writes an empty entry, else one at random. `loopleaf`
−59%, the shared-table stress program −20%, but `overlap` +17%, `ttt` +6%
and the random programs a median of +0.5%: a miss probes twice, and
choosing which entry to write takes about ten instructions more. Comparing
both entries' keys without a branch made `ttt` +12% to +18% and `overlap`
+33% to +37%, since every word of both keys is read; writing the entry whose
work was less was measured only so, and did no better than writing one at
random (`loopleaf` −51% against −50%). With the branch, the entry written
was chosen three ways:

| written on a miss | `loopleaf` | `overlap` | `ttt` |
|---|---|---|---|
| at random, an empty one first | −59% | +17% | +6% |
| always the first, moving it to the second | −52% | +23% | +7% |
| the first while empty, else the second | −59% | +13% | +67% |

The last keeps whatever filled the first entry, so `ttt`, whose positions
change as the search moves on, keeps positions it never asks for again.

### Without the tag

An entry of the arguments, the result and a meta word whose work tells an
empty entry, 0, from a written one. A shorter entry fits more of them in
64 KiB: `ttt`'s fell from 72 to 64 bytes, a cache line each, and the table
from 512 entries to 1024, which made it 44% faster. `overlap`'s doubled
from 1024 entries to 2048, which doubled its first-level misses: +4.9%.
Every layout below has no tag.

### A cellar: a primary part and an overflow

A miss whose entry holds a result hit since it was written keeps it and
writes the overflow entry another part of the hash picks, marking the
primary entry so a lookup that misses it probes the overflow. A primary
entry hit is marked used; keeping it clears the mark, so it stays only
while it keeps being hit. Its split of the 64 KiB:

| split | `loopleaf` | `overlap` | `ttt` |
|---|---|---|---|
| ¾ primary, ¼ overflow | −52.6% | +44.1% | −37.4% |
| ½ and ¼, both powers of two | −53.1% | +40.7% | −20.8% |
| ½ and ½ | −53.1% | +43.6% | −44.0% |
| 64 KiB and 64 KiB more | −53.4% | +48.9% | −66.8% |

An entry has to start out marked: two arguments that share an entry and
alternate each overwrote the other before it was ever hit, and ¾ and ¼ made
`loopleaf` 7.5% slower. With the mark, a simulation of `overlap`'s calls
under ½ and ½ makes 16,209 hits in the primary part and 15,826 in the
overflow, the 32,035 it makes without a cellar. What it pays for is the
cellar's own work: in the simulation 49,840 of its lookups probe the
overflow, since a primary entry's mark that a result went to the overflow
stays, and under ¾ and ¼ its mispredicted branches rose from 9.6 thousand
to 49 thousand and its instructions from 4.87 to 6.36 million. Clearing
that mark when a miss overwrites the primary entry saved 160 thousand
instructions under 64 KiB and 64 KiB more but made the branch on it
unpredictable: 71 thousand mispredictions, `overlap` +52.8%.

### Bigger tables

| size | `ttt` | `loopleaf` | `linear` | `overlap` |
|---|---|---|---|---|
| 64 KiB | −43.9% | −1.6% | −5.1% | +4.9% |
| 256 KiB | −77.1% | −31.8% | −9.8% | +14.0% |
| 1 MiB | −83.6% | −62.0% | −13.4% | +35.0% |

A bigger table has fewer arguments to an entry, so it also helps
`loopleaf`. Callgrind ranks 1 MiB first; the wall clock does not, below,
because 1 MiB is 256 pages that each cost the kernel a first write:
`overlap`, `linear` and `ttt` took 797, 633 and 795 page faults a run at
1 MiB and 319, 312 and 317 at 64 KiB.

### A table that grows

A table that starts small and doubles when an evicted argument is asked for
again. An entry overwritten keeps eleven bits of its arguments' hash in its
meta word, and a miss whose own bits match them counts a hit a bigger table
would have made. A table that grew dropped its entries.

Starting at 4 KiB, doubling once a quarter of its entries' worth of such
misses was counted, up to 1 MiB on the heap behind a pointer: `ttt` −61.8%,
but `loopleaf` +33.0%, `linear` +31.1% and `overlap` +23.2%, since each
growth emptied the table and the counts grew with it. Starting at 64 KiB,
growing sixteenfold once a sixty-fourth was counted, with all 1 MiB reserved
as zeroed memory and growth only widening the index: `ttt` −82.1%,
`loopleaf` −50.1%, `linear` −5.6%, but `overlap` +47.3%. Keeping the counts
costs about 13 instructions a lookup, measured on `overlap` with no growth
(4.18 against 5.06 million), and `overlap`'s evicted arguments do come back
now and then, so the table grows for it too.

### One table for every function

Considered and not built. Its entries would need room for the widest
function's, so `fib` would use three of seventeen words, or a table for each
width; each entry would need its function's identity, unique across a
program and the libraries it links; and a function that churns through
arguments would evict every other function's.

## Wall clock

The least of 40 runs, in ms; the other 17 programs differ by less than
0.6 ms between the remembering layouts.

| program | none | 64 KiB, tagged | two-way | 64 KiB | 256 KiB | 1 MiB | ½ + ½ | 64 + 64 | growing |
|---|---|---|---|---|---|---|---|---|---|
| `ttt` | 13.53 | 7.77 | 8.73 | 5.35 | **3.73** | 4.14 | 5.67 | 4.30 | 4.12 |
| `loopleaf` | 21.80 | 3.87 | 2.82 | 4.00 | 3.52 | 2.99 | **2.76** | 2.80 | 3.01 |
| `overlap` | 5.21 | 3.07 | 3.13 | **2.91** | 3.36 | 4.28 | 3.41 | 3.57 | 4.48 |
| `linear` | 8.55 | 2.77 | 2.83 | 2.83 | 2.74 | 3.21 | **2.56** | 2.84 | 3.40 |
| all 21 | 187.1 | 134.6 | 135.0 | 132.4 | 132.5 | 137.2 | 132.1 | **130.3** | 132.0 |

The four programs above took 13.35 ms at 256 KiB and 13.51 at 64 + 64; the
sum of all 21 carries about 0.2 ms of noise a program. 256 KiB was chosen
over the 64 + 64 cellar as the faster on those four and the simpler to share
between threads: an entry is written by one miss and read by one guarded
lookup ([`memoization.md`](memoization.md) M1), where a cellar's miss can
write an overflow entry and a primary entry's marks, and its hits write a
mark too.
