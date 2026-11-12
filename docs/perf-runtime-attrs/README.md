# Runtime declarations' attributes: measurements

What the runtime's declarations tell LLVM (`lib/codegen/runtime_facts.ml`;
[`design/lowering.md`](../design/lowering.md) §9, "What LLVM is told", and
[`optimizations.md`](../optimizations.md)): `main`'s attributes
(`zane_out_of_range` and `zane_too_deep` `noreturn cold nounwind`,
`zane_text_equal` reads only), kept now in an optimized or tiered build
too, whose linked runtime bodies used to replace the declarations and drop
them, and `captures(address)` on the handle of `zane_list_push`,
`zane_list_reserve` and `zane_list_room`. The idea came from
[`experiments/llvm-facts`](https://github.com/zane-lang/compiler/tree/experiment/llvm-facts/docs/experiments/llvm-facts),
"What remains" item 3.

Measured with [`perf-unroll/`](../perf-unroll/README.md)'s `perf.py`,
`langbench.py` and `compare.py`: estimated cycles, instructions, mispredicted
branches, I1 misses and `.text` of every `tests/perf` program optimized,
tiered and plain, and of the 10 langbench programs this compiler builds,
optimized and tiered, at 1/50 of langbench's size. `before.tsv` is `main` at
b8de490, `after.tsv` this change. Counts measure work, not time (see
`perf-unroll/`).

## tests/perf (rows moving at least 0.3%)

```
program     build        cycles    instr    mispr  I1 miss    .text          text B
returns     optimized     -1.4%    -1.7%    -0.0%    +0.0%    -0.2%   27632>27568
returns     tiered        -1.4%    -1.5%    -1.5%    -0.1%    -0.6%   10802>10738
```

Every other row moves by 0.11% or less (`depths` tiered), plain builds by
none.

In `returns`' `grow`, a node's list of children is a handle in a stack slot
that the first push passes to `zane_list_push`. Without the attribute that
call captures the slot, so after the recursive call before each push LLVM
must reload the count and the room and check them. `captures(address)` tells
it the slot stays the function's own: the list is still empty at the first
push, which goes straight to the runtime, and the loop's first round loses
its check (`grow` is 286 lines of optimized IR before, 267 after).

`main`'s own attributes kept through the link move nothing alone
(`only-relink.tsv`: this change without `captures(address)`): the calls they
describe are cold or rare.

## Langbench (the 10 of 16 programs the current compiler builds)

No program moves by 0.3% (`lb-before.tsv`, `lb-after.tsv`). Under Callgrind
`concscan`, the one that spawns threads, sometimes stops on Valgrind's own
assertion (`vgCallgrind_post_signal`), in either build: `lb-after.tsv` has
no `concscan` optimized row for that reason, and runs of the larger set
(`lb-all-attrs.tsv`) measured it unchanged.

## Measured and left out

Every attribute below holds of the runtime's C, and none gained anything, so
none is given; each would have been one more rule the runtime's C must keep.
`all-attrs.tsv` and `lb-all-attrs.tsv` are all of them together;
`only-*.tsv` turn on one group alone, over `nounwind` on every function.

- `nounwind` on every function (`only-nounwind.tsv`).
- `noalias nonnull align 8` on the blocks `zane_alloc`, `zane_alloc_held`
  and `zane_box` return (`only-ret.tsv`): no hot loop calls an allocator
  without inlining its body.
- `readonly`, `writeonly` and `captures(none)` on the pointers of
  `zane_print`, the `zane_text_*` and `zane_parse_*` functions,
  `zane_arguments`, `zane_list_new`, the removals, `zane_pool_root` and
  `zane_link`, and `captures(address)` on `zane_region_at` and
  `zane_leaves` (`only-param.tsv` with the push's: its row is the push's
  alone).
- Memory effects, `willreturn`, `nosync` and `nofree` on `zane_text_expect`,
  `zane_list_new`, the removals, `zane_pool_root`, `zane_link` and
  `zane_handle_made`; `noreturn cold` on `zane_no_object` and `cold` on
  `zane_hold` (`only-fn.tsv`).

With all of them, `texts` tiered rose 1.3% at the same instruction count:
tier 1's `texts$main` was byte for byte the same, but its library's sections
started 0x380 bytes earlier, and Callgrind's address-indexed predictor for
indirect branches (tier 1 calls the runtime through tier 0's table) gave 40 k
more mispredicts. `nounwind` alone did the same.

Not given because the C does not keep them, or would not after a likely
change: `allocsize` (a list's block grows in place past the size it was
made at), `allocalign` (no Zane type is aligned past 8, and a block over a
chunk asked for at more than 64 would not be), `allockind`/`alloc-family`
(a region's drain returns blocks whose pointers never reached it), and any
memory effect or `willreturn` on a function that can stop the program.
