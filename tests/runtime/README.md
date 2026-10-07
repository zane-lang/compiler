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
