# LLVM facts

How much faster zanec's code gets from (a) a larger partial-unroll budget in
LLVM and (b) telling LLVM facts it is not told today: finer alias classes,
`nsw` on arithmetic, and attributes on Zane's own functions. Each idea sits
behind an environment switch read by `zanec` at compile time; with none set
the build is `main`'s.

**Measuring.** `measure.py LABEL` builds every program in `tests/perf/`
optimized and tiered with the switches in the environment, using
`tests/perf/run`'s own build-and-measure code (Callgrind, fixed caches,
estimated cycles = Ir + 10·L1 + 100·LL + 20·mispredicts), and writes
`results/LABEL.tsv` with cycles, instructions, mispredicts and `.text`
bytes (the executable's for optimized, the tier-1 library's for tiered).
`compare.py BASE LABEL…` prints the tables below. Counts measure work, not
time: Callgrind does not model store forwarding, unaligned-access penalties
or any out-of-order effect.

Run in a cloud container with the pixi environment (LLVM 21.1.8), from
`main` at 90ebb2b.

| switch | what it does |
| --- | --- |
| `ZANE_UNROLL_PARTIAL=n` | passes `-unroll-partial-threshold=n` to LLVM |
| `ZANE_UNROLL_THRESHOLD=n` | passes `-unroll-threshold=n` |
| `ZANE_UNROLL_RUNTIME_COUNT=n` | passes `-unroll-max-count=n` |
| `ZANE_TBAA_FINE=1` | struct-path TBAA tags on member accesses (step 2) |
| `ZANE_TBAA_TYPED=1` | one alias class per scalar type (**unsound**: an upper bound) |
| `ZANE_NSW=1` | `nsw` on the program's integer add/mul/negate (**unsound**: an upper bound) |

## Step 1: unroll budgets

**Design.** `Passes.llvm_options` appends `-unroll-partial-threshold=n`
(`ZANE_UNROLL_PARTIAL`) and `-unroll-threshold=n` (`ZANE_UNROLL_THRESHOLD`,
the budget for *full* unrolling of a loop with a known trip count) when set.
The options are part of the tier-1 cache key already, so a tiered build
picks them up. Unrolling never changes what a program means, so no fact is
claimed here.

**Results.** `ZANE_UNROLL_PARTIAL=n ZANE_UNROLL_THRESHOLD=m measure.py LABEL`;
`upN` is the partial budget, `utM` the full one. Estimated cycles against
`base`; every row not shown moved less than 0.2% in every column. `.text`
is the whole executable's (runtime included) for optimized and tier 1's
library for tiered. Every build printed its golden output.

| program | build | up100 | up150 | up200 | up300 | up500 | ut250 | up150ut250 | up300ut250 | .text up300ut250 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| borrows | optimized | -11.9% | -11.9% | -11.9% | -11.9% | -11.9% | +0.0% | -11.9% | -11.9% | +6.8% |
| division | optimized | +0.0% | -3.8% | -3.8% | -4.5% | -4.6% | +0.0% | -3.8% | -4.5% | +1.3% |
| entities | optimized | -3.4% | -4.0% | -5.0% | -6.0% | -6.0% | +0.0% | -4.0% | -6.0% | +23.5% |
| floats | optimized | +0.2% | +0.5% | +0.5% | +0.6% | +0.6% | +0.0% | +0.5% | +0.6% | +22.6% |
| kept | tiered | -5.1% | -6.2% | -6.7% | -6.9% | -6.8% | +0.0% | -6.1% | -6.8% | +36.1% |
| particles | optimized | -3.6% | -3.5% | -3.4% | -4.6% | -4.6% | +0.0% | -3.4% | -4.6% | +19.1% |
| paths | optimized | -0.3% | -0.3% | -0.3% | -0.3% | -0.3% | -42.5% | -42.8% | -42.8% | +6.1% |
| paths | tiered | -0.0% | -0.0% | -0.0% | -0.0% | -0.0% | -41.3% | -41.3% | -41.3% | +5.0% |
| removal | optimized | +1.1% | +1.1% | +0.9% | +0.9% | -1.3% | +0.0% | +1.1% | +0.9% | +11.3% |
| removal | tiered | +1.1% | +1.1% | +0.9% | +0.9% | -1.0% | +0.0% | +1.1% | +0.9% | +20.6% |
| repeats | optimized | -3.0% | -3.4% | -3.4% | -3.8% | -3.9% | +0.0% | -3.3% | -3.9% | +21.3% |
| repeats | tiered | -2.9% | -3.3% | -3.2% | -3.8% | -3.7% | +0.0% | -3.2% | -3.7% | +117.7% |
| returns | optimized | -0.0% | -0.0% | -0.0% | -0.0% | -0.0% | -10.0% | -10.0% | -10.0% | +6.3% |
| returns | tiered | +0.0% | +0.0% | +0.0% | +0.0% | +0.0% | -8.2% | -8.2% | -8.2% | +4.3% |
| stress | optimized | -0.1% | -0.4% | +0.0% | +0.1% | -0.4% | +0.0% | -0.4% | +0.1% | +5.5% |

The full-unroll budget sweep (`ut150` … `ut1000`, in `results/`) is a step
function: `ut150` is byte-for-byte `base` (150 is `-O2`'s own default), `ut200`
takes returns' −10%, `ut250` adds paths' −42%, and nothing more moves up to
1000, while every optimized executable's `.text` grows about 2% from 200 on —
the C runtime, which is optimized in the same module, unrolling more.

**Why paths wins 42%.** Its breadth-first search visits each cell's four
neighbours with `d!to(Int(4))` and four `branch(d == k, …)` blocks. Under
`-O2` the loop stays rolled and the four tests become one `switch i64 %d`
in the loop body; LLVM's estimate of the unrolled cost lies between 200 and
250 (`ut200` leaves it, `ut250` takes it). At 250 it is
unrolled, each copy knows `d`, and the switch disappears. Instructions fall
24% and mispredicted branches 1.10 M → 0.31 M: most of the gain (15.7 M of
21.8 M estimated cycles) is mispredicts. Callgrind's predictor is a table of
2-bit counters with no history, so it cannot learn the 1-2-3-4 period of the
switch; a real core's history-based predictor learns much of it, so on
hardware the win is likely nearer the 24% instruction drop than 42%.
`returns` is the same shape (`k!to(Int(4))`), mispredicts 1.12 M → 0.68 M.

**Why borrows wins 12% (−28% instructions).** `scan`'s `j!to(n)` loop sums
`ys[j]` where `xs[j] < wall`; with partial/runtime unrolling allowed past
the default budget it is unrolled (not checked in the assembly: inferred from
the −28% instructions with the same branch count per element), sharing the
index arithmetic and bounds checks of the copies. Mispredicts rise 10% (one branch per element either
way, now at more addresses), which costs back part of the instruction win.
`entities`, `particles`, `repeats` and tiered `kept` are loops of the same
kind; their gain grows with the budget up to 300.

**Why removal loses 1%.** The extra instructions are all in `zane_main`
(+2.4 M, memmove unchanged at 131 M). Partial unrolling unrolls the cold
`d!to(Int(20)) { entities!remove(Int(1)) }` loop (memmove call sites 2 → 10);
the bigger function then runs out of registers in the hot `u` loop over the
entities, which is not unrolled at all, and the items pointer is reloaded
from the stack on each iteration (`mov (%rsp),%r9`, one load per element;
the loop's 64-byte line costs 53.7 M → 57.5 M instructions). A cold loop's
unrolling costing a hot loop a register is the general risk of a bigger
budget. At 500 a different unrolling wins it back (−1.3%).

`floats` +0.5%: −0.2% instructions but mispredicts +20% (66 k → 80 k) after
its loops unroll, and its `.text` +10–23%.

**Tests.** `just test-compiler` passes with no switch and with
`ZANE_UNROLL_PARTIAL=300 ZANE_UNROLL_THRESHOLD=250` (about 2 minutes each).

**Reading.** Two separate effects. (1) Full unrolling of 4-trip loops whose
body branches on the counter is the large one, and it is all-or-nothing at
a budget between 150 and 250. A targeted fact — `llvm.loop.unroll.full` on a
counted loop whose trip count is a small constant (Zane's `to`/`repeat` with
a literal) — would take it without growing every other loop, the way PR 356
marks short early-exit loops. (2) A bigger partial budget is worth 3–12% on
five programs for 6–24% more `.text` (up to +118% on tier 1 of repeats), and
it costs removal 1%. 150 takes most of it; 300 adds about 1% more on entities,
particles and division.

## Step 2: finer alias classes (TBAA)

**Design.** Two switches in `lib/codegen/emit.ml`.

- `ZANE_TBAA_FINE=1` (meant to be sound): a scalar read or written at an
  address made by `Offset` through struct members only (`Deref`, `Store`,
  `Assign` with a path, and the member-wise stores of `place`) gets a
  struct-path tag: the outermost struct type (one type node per structural
  `Ty`, named by `Ty.to_string`, listing each scalar, handle or struct
  member at its offset from the data layout), the scalar type and the
  offset. Every scalar is still the one "zane scalar" type node, so the
  snapshot rule in `Emit.tags` is kept. Why it is true for every program:
  two struct-path tags say "no alias" only for different members, or for
  struct types neither of which holds the other at that offset. Storage
  that can hold two struct types is a sum's room or a block freed and
  reused. A path through a sum's room never gets a struct-path tag (it
  falls back to "zane scalar", which LLVM takes to overlap any scalar
  member), whole aggregates are loaded and stored untagged, and freeing
  goes through a runtime call or untagged pool-cache stores, so every
  change of what a place holds is ordered against accesses of both types.
- `ZANE_TBAA_TYPED=1` (**unsound**, an upper bound): each scalar type is
  its own type node, a child of "zane scalar", so an `I64` access and an
  `F64` access never alias while a "zane scalar" access (the elements a
  removal moves) still overlaps both. It breaks the snapshot rule.

**Results.** `measure.py` with each switch, against `base2` (the same build,
no switch). Only `particles`' optimized executable changed at all, by
−9,367 instructions (−0.04%); every other build's instruction count moved
by +600 to +1,100, the same for every program, which is the extra
environment variable at process start (the C library's and `ld.so`'s
counts depend on the environment's size), and `.text` did not change by a
byte in any build. Typed and typed + fine are the same: nothing above
+0.3%, that on `kept`, whose 454 k instructions make the startup noise
0.14% by itself. Every build printed its golden output.

| program | build | fine | typed (upper bound) | typed + fine |
| --- | --- | ---: | ---: | ---: |
| every program | both | ±0.0% | ±0.0% | ±0.0% |
| kept | optimized | +0.1% | +0.1% | +0.2% (startup noise) |

**Tests.** `just test-compiler` passes with `ZANE_TBAA_FINE=1` and with
both switches on (the typed classes' unsoundness is not exercised by the
suite).

**Why nothing moves.** The alias questions that matter in these loops are
already answered. A list's header and its elements are in separate classes
(`docs/optimizations.md`, "List headers and scalars in separate alias
classes"); two members of
one element are at constant offsets from one base, which BasicAA resolves
without tags; and the same member of two elements of one list (`e[i].x`
against `e[j].x`) has one tag under any scheme, since nothing distinguishes
them. Loops reading two lists of the same element type (borrows' `xs` and
`ys`, both `F64`) only load, so aliasing does not constrain them. What does
stop LLVM in the hot loops are runtime calls (`zane_list_push`,
`zane_alloc_held`, `zane_free`, declared with no memory effects at all),
which no TBAA tag affects; step 4 looks at those.

## What remains

- Steps 1–5 as planned.
