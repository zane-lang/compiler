# Why langbench `nbody` loses with the partial budget

`nbody` +6.8% cycles at 150 (+10.4% instructions, mispredicts -92%) comes from
`-unroll-partial-threshold=150` alone; `-unroll-threshold=250` alone moves
it under 0.3% (`t250.tsv`). Everything is inlined into `zane_main`. The loop
`j!to(n)` in `advance` runs `n - i` times, 1 to 4 for five bodies, ten times
a step. With the budget it is runtime-unrolled four times, with a prologue
that runs the first `(n-i) mod 4` iterations and a guard before the 4-wide
copy: the 4-wide copy runs at most once and the prologue does the work, so
each pair pays the dispatch and the larger body's reloads (sqrt/div count
is the same, 1 M; branches 2.48 M -> 3.28 M, instructions +6.3 M = 63 a
step) and saves nothing. Mispredicts fall (the exit test of a 4-3-2-1
pattern is replaced by the prologue's switch) and recoup part of it.
Rows: `*.tsv` here. Variants were built with a local `ZANE_LLVM_EXTRA`
override of `Passes.llvm_options` (not committed).
