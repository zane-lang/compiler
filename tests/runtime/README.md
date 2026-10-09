# Runtime tests

`dune runtest tests/runtime` builds each C fixture against all runtime parts
and compares its output with `golden/`. The build uses Clang, `-O2`, and
warnings as errors.

`scalar_lists.c` covers issue [#191](https://github.com/zane-lang/compiler/issues/191):
cleanup, copying, and promotion must skip empty nested layouts, whether
represented by null or by a table with zero positions. List backing blocks
and scalar box payloads must still be copied, promoted, and returned, and
an overwrite must preserve a box's address while updating its payload.
The existing `blocks.c` fixture covers nonempty layouts, including lists
of owned strings and recursively boxed values.

`numbers.c` holds `zane_parse_i64` and `zane_parse_f64` to the cases
`tests/unit/` holds the compile-time evaluator's reads to, so a number reads
the same whether the program or the compiler reads it, and checks that
`zane_arguments` copies each argument into a string of its own and that the
list returns every block when its scope drains.

`writeback.c` holds a write-back to the atomicity a snapshot load relies on:
a second thread reads each naturally aligned word of a subject at an address
aligned to 4 and not 8 while the main thread writes back all-zero and
all-one copies that sit at odd addresses, and no word it reads may mix the
two. A write-back that stored such a subject a byte at a time failed it on
every run. It then writes back every size from 1 to 19 bytes at each offset
from 0 to 7 and checks the bytes arrived.

`work.c` covers the walks that copy, move, overwrite and end a value
once they hold more jobs than a walk keeps in itself
(`ZANE_LOCAL_JOBS` in `zane_internal.h`) and move to a heap buffer: a
list of twenty strings copied, ended and promoted, an overwrite whose
arrivals outgrow the inline jobs, and a countdown a hundred thousand
boxes deep copied and ended. Dropping the inline jobs when the walk
moves to the heap leaves blocks unreturned, which this fixture alone
catches.

On Linux the scalar-list fixture caps its address space at 128 MiB. Its
two-million-element lists and copies fit, while the old per-element work
queue grows to 192 MiB and fails. Other platforms run the same ownership
checks without that platform-specific budget. AddressSanitizer builds are
detected through GCC's or Clang's sanitizer macros and skip only the
address-space budget, since ASan reserves a large shadow address space.
They still run every ownership check against the same golden output.
Ordinary and UndefinedBehaviorSanitizer builds retain the budget on Linux.

## Performance experiment

At `960f8d8fef10a791ed71a1607a931ff67938910b`, a separate C harness pushed
two million `I64` values, summed them through indexed runtime reads, and
timed scope cleanup. Five fresh-process runs of the same harness before
and after the empty-layout traversal fix, on Ubuntu x86_64 with GCC 13.3.0
and `-O2`, gave median cleanup times of **71.4 ms → 0.77 ms**.
Both sums remained `2000001000000`. This measures the actual runtime,
not a compiled Zane program; the results are specific to that environment.
The runnable harness is included in issue #191. The fix removes the empty
element jobs from cleanup, copying, and promotion. Indexed-read overhead
is a separate problem and was unchanged in this experiment.

## Inline work jobs

Issue [#203](https://github.com/zane-lang/compiler/issues/203) found that
binarytrees and ntree spend much of their time in `zane_move`, and that
each move allocated a heap buffer for its work before doing anything. A
walk now keeps its first four jobs in itself. Built with
`zanec --optimize` from the langbench programs at spec
`c34dc70`, core `97beb743`, on a 4-core x86_64 container, one warmup and
seven alternating fresh-process runs per build gave these medians (ranges
in brackets):

| Program | Before, s | After, s | Change |
| --- | ---: | ---: | ---: |
| binarytrees 16 | 5.305 [5.069–5.937] | 3.733 [3.503–4.740] | −29.6% |
| ntree 10 | 8.325 [7.215–9.207] | 6.292 [5.523–6.777] | −24.4% |
| treecopy 18 | 2.518 [2.386–3.045] | 2.654 [2.352–3.331] | — |
| listgrowth 2000000 | 1.686 [1.619–1.976] | 1.661 [1.558–1.851] | — |
| entities 3000000 | 2.440 [2.297–2.801] | 2.396 [2.207–2.602] | — |
| fannkuch 10 | 1.981 [1.729–2.228] | 1.770 [1.750–2.010] | — |

Only binarytrees and ntree have separated ranges; a dash marks a change
whose ranges overlap. Every program printed
its expected output at its check and benchmark sizes with both builds.
The container's absolute times do not compare with the pinned langbench
run.

## Bulk drains

Issue [#211](https://github.com/zane-lang/compiler/issues/211) found that a
drain spent much of binarytrees and treecopy walking its values to return
their blocks one at a time, just before it released their chunks anyway. A
drain now releases its region in bulk and walks nothing; a program run with
`ZANE_CHECK` set walks and checks every drain as before. `texts.c` checks
both ways for a block moved into a deeper owner: an unchecked drain leaves
it, dead, in the outer region it is in, and a checked one returns it. The
other fixtures run unchecked; `zane_blocks()` counts the blocks out in the
open regions, so a check after a drain still sees the region's go. The same
change looks up the innermost scope first when it finds a slot's region,
keeps a context's spare chunks with the context instead of under the global
lock, and drops the global atomic block count.

Built with `zanec --optimize` from the langbench programs at spec `c34dc70`,
core `97beb743`, on a 4-core x86_64 container, one warmup and five
alternating fresh-process runs per build gave these medians (ranges in
brackets):

| Program | Before, s | After, s | Change |
| --- | ---: | ---: | ---: |
| binarytrees 16 | 2.769 [2.654–2.838] | 1.515 [1.439–1.976] | −45.3% |
| ntree 10 | 4.660 [4.374–5.028] | 3.667 [3.290–3.891] | −21.3% |
| treecopy 18 | 1.943 [1.867–2.002] | 0.876 [0.676–0.932] | −54.9% |
| listgrowth 2000000 | 1.473 [1.353–1.549] | 1.377 [1.369–1.444] | — |
| entities 3000000 | 0.600 [0.531–0.612] | 0.591 [0.576–0.598] | — |
| fannkuch 10 | 0.261 [0.253–0.299] | 0.254 [0.244–0.298] | — |

A dash marks a change whose ranges overlap. Peak memory was the same in
both builds: 15 MB for binarytrees, 88 MB for ntree, 45 MB for treecopy and
126 MB for listgrowth. Every program printed the same output with both
builds.
