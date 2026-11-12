# Runtime declarations' attributes: measurements

The attributes each runtime function is declared with
(`lib/codegen/runtime_facts.ml`; what each claims and why is in
[`design/lowering.md`](../design/lowering.md) §9, "What LLVM is told", and
[`optimizations.md`](../optimizations.md)). The idea came from
[`experiments/llvm-facts`](https://github.com/zane-lang/compiler/tree/experiment/llvm-facts/docs/experiments/llvm-facts),
"What remains" item 3.

Measured with [`perf-unroll/`](../perf-unroll/README.md)'s `perf.py`,
`langbench.py` and `compare.py`: estimated cycles, instructions, mispredicted
branches, I1 misses and `.text` of every `tests/perf` program optimized,
tiered and plain, and of the 10 langbench programs this compiler builds,
optimized and tiered, at 1/50 of langbench's size. `before.tsv` is `main` at
b8de490, `after.tsv` this change; `only-*.tsv` turn on one group of
attributes alone over `nounwind` on every function: `ret` the allocators'
results, `param` the parameters', `fn` the function attributes past
`nounwind` (memory effects, `willreturn`, `nosync`, `nofree`, `noreturn` and
`cold` on `zane_no_object`, `cold` on `zane_hold`; `zane_out_of_range` and
`zane_too_deep` keep `main`'s `noreturn cold` in every group), and `nounwind`
that alone. Counts measure work, not time (see `perf-unroll/`).

## tests/perf (rows moving at least 0.3%)

```
program     build        cycles    instr    mispr  I1 miss    .text          text B
returns     optimized     -1.4%    -1.7%    -0.0%    +0.0%    -0.2%   27632>27568
returns     tiered        -1.4%    -1.5%    -1.5%    +0.0%    -0.6%   10802>10738
texts       tiered        +1.3%    +0.0%   +14.4%    -0.2%    +0.0%    7931>7931
```

Every plain build is within 0.1%: a plain build runs no passes that use the
attributes.

**`returns`** is the parameters' group alone (`only-param.tsv` gives the same
row; `only-ret`, `only-fn` and `only-nounwind` leave `returns` as it was, and
move nothing else past layout: `texts` tiered as below, and `depths` tiered
−0.3% in mispredicts alone under `only-fn`). In `grow`, a
node's list of children is a handle in a stack slot that the first push
passes to `zane_list_push`. Without an attribute that call captures the
slot, so after the recursive call before each push LLVM must reload the
count and the room and check them. `captures(address)` on the handle tells
it the slot stays the function's own: the list is still empty at the first
push, which goes straight to the runtime, and the loop's first round loses
its check (`grow` is 286 lines of optimized IR before, 267 after).

**`texts` tiered** is layout, not work: instructions differ by 69 of 54
million, tier 1's `texts$main` is byte for byte the same, and its library's
sections start 0x380 bytes earlier, so Callgrind's address-indexed
predictor for indirect branches (tier 1 calls the runtime through tier 0's
table) aliases differently: 277 k mispredicts become 317 k, 40 k of them
indirect. `nounwind` alone gives the same row (`only-nounwind.tsv`), as the
experiment's step 4 found. CI's 1% gate counts it, so the pull request needs
`perf-accepted`.

The allocators' `noalias nonnull align 8` results and the function
attributes move nothing measurable: no hot loop here calls an allocator or
one of those functions without inlining its body.

## Langbench (the 10 of 16 programs the current compiler builds)

No program moves by 0.3% in estimated cycles or instructions
(`lb-before.tsv`, `lb-after.tsv`). `concscan`, the one that spawns threads,
wobbles in mispredicts and I1 misses at the same instruction count. Under
Callgrind `concscan` sometimes stops on Valgrind's own assertion
(`vgCallgrind_post_signal`), in either build; a rerun measures it.
