# Compiler switches in the Zane-vs-Goose builds

Which experimental `ZANE_*` switches of the compiler (branch
`experiment/zane-vs-goose`) the LangArena builds use, as of step 30
(`results/step30-goose.md`, geomean Zane / Goose-clang 0.973). The measurements
behind each are in `goose-progress.md`, or in the compiler's
`docs/experiments/` where noted.

## On (set for every build)

```
ZANE_LOOP_REGS=1 ZANE_ASSIGN_MOVES=1 ZANE_VERSION_CALLS=1 ZANE_LENT_OWNERS=1
ZANE_FRAME_SHADOW=1 ZANE_MERGE_CHECKS=1 ZANE_ENDLESS=1 ZANE_SIZED_TBAA=1
ZANE_FRAME_SCOPES=1 ZANE_ARM_CHECKS=1 ZANE_STRIP=1 ZANE_RANGE_CHECKS=1
ZANE_REHOME=1 ZANE_LIST_SPANS=16384 ZANE_IDLE_SEARCH=1 ZANE_DIV_CACHE=1
ZANE_CONST_ARRAYS=1 ZANE_LITERAL_LOCALS=1 ZANE_BIASED_BASE=1 ZANE_UNROLL_SMALL=8
ZANE_LOOP_INLINE=128 ZANE_LEAF_PEEL=1 ZANE_SHADOW_REFILL=1 ZANE_NO_COPY_IDIOM=1
```

`ZANE_LOOP_INLINE=128` is from after step 27: a call in a loop to a small
loop-free leaf of the program, judged after LLVM's passes, inlined
(Maze::Generator's `adjacentOpen`, CacheSimulation's `front`).
`ZANE_LEAF_PEEL=1` too: a recursion's base case made at each self-call
with no call, as Goose's compiler emits Binarytrees' `build`.
`ZANE_SHADOW_REFILL=1` after step 28: frame shadow fills again after a
`memset`/`memcpy` of a constant length, or a list growth call, only the
slots it may write, not every slot (Brainfuck::Array 1.89 → 1.70 s).
`ZANE_NO_COPY_IDIOM=1` after step 29: an element-by-element copy loop
stays a loop rather than a `memmove` call (Fannkuchredux 1.63 → 1.43 s).

The last three are from step 27's round:

- `ZANE_LITERAL_LOCALS`: a local string literal places no frame
  (TextRaytracer's `String` LUT as fast as an `Array`).
- `ZANE_BIASED_BASE`: an element's address from a base biased one element
  down, so the 1-based index's `- 1` is off the address chain.
- `ZANE_UNROLL_SMALL=8`: a loop of a constant count from 2 to 8 unrolled
  whole (HuffDecode's bit loop, as Goose's `for j in 8`).

## On by default (turned off only with `=0`)

`ZANE_HOIST_HANDLES`, `ZANE_INTERLEAVE`, `ZANE_LIGHT_SCOPES`,
`ZANE_LOOP_PUSHES`, `ZANE_ONE_BOX`, `ZANE_PREFETCH`, `ZANE_PARTIAL_INLINE`,
`ZANE_ASSIGN_LET`. All on in every build here.

## Off: measured, no help or slower

| Switch | Result |
| --- | --- |
| `ZANE_PEEL_RECURSION` | Superseded by `ZANE_LEAF_PEEL` after step 28 (it inlines a whole level; Sort::Quick 1.80 → 1.93). Step 24: Binarytrees::Arena 0.584 → 0.608, Sort::Quick slower. After step 26: geomean 0.998 over all 50 (3 rounds), the extremes all within noise on re-runs, Arena included. |
| `ZANE_DIV_HOIST` | After step 28: a loop-invariant divisor's multiplier looked up once in the loop's preheader. ArithEncode the same; Brainfuck::Array +16%, Json::Generate +14%, CSV::Parse +6% (the LICM/unswitch run it adds over every function). |
| `ZANE_INSIDE_FIRST` | After step 29: an index check made as `offset <u count` taken to the element, so IRCE reads a counter's check against an `Array<T, n>`. NeuralNet 822 M → 905 M instructions (`feed`'s loop no longer unrolled in full by the folded check's trip count). |
| `ZANE_SHADOW_SPLIT` | After step 30: a vector load or store of the frame split per element, so Frame_shadow takes a list header's count and room. HuffDecode 1,912 → 1,897 M instructions, time the same (the escaped frame keeps every store). |
| `ZANE_LOOP_INLINE_LOOPS=128` | After step 28: `ZANE_LOOP_INLINE` also takes callees with a loop or a runtime push. ArithEncode −4%, NGram −7%, Binarytrees::Obj −8%, Maze::AStar +7%. |
| `ZANE_LOOP_RANGES` | Slower: the range test cost more than the checks it removed (compiler `docs/experiments/goose-comparison`). |
| `ZANE_BUMP_REGIONS` | No gain: the frontier's load and store were the chain, not the free list (goose-comparison). |
| `ZANE_ELEM_TBAA` | After step 27: list elements' scalars tagged and scoped by the list's stride. Tags right, changes nothing measurable (all 50, 3 rounds: geomean 1.008). |
| `ZANE_LLVM_OPTS=-inline-threshold=600` | After step 27: a wash on all 50 with large swings both ways (Graph::BFS +15%, GameOfLife +20%, Json::ParseDom −23%). |
| `ZANE_CHUNK_BOXES` | About 5% slower on binarytrees than image boxes, same memory; for platforms where the image window cannot be placed (goose-comparison). |

## Off: no record of a LangArena build with them

`ZANE_POOLED_VARIANTS`, `ZANE_POOL_REGISTERS`, `ZANE_POOL_UNCHECKED`,
`ZANE_PACKED_NODES`: a recursive variant kept as packed nodes in one pool,
as Goose's are. Nothing in this repo, its history or the logs of this
experiment shows a LangArena build with them set, though an unlogged
earlier try cannot be ruled out.

They were measured in the compiler's own goose-comparison experiment
(`docs/experiments/goose-comparison/README.md`, "Pooled variants") on
its binarytrees port: 0.112 → 0.091 s, and 0.081 s with partial
inlining. That log lists the prototype's limits (among them: no reading
a pooled subtree out as a value, no other pooled type in a node, no
function value that returns a pooled variant), so whether LangArena's
port fits them is not known yet. Worth trying on Binarytrees::Obj (1.29×
at step 27): check the limits first, keep the switches only if all 50
checks pass and a full run does not regress.

## Debug and tooling switches (not optimizations)

`ZANE_*_DEBUG`, `ZANE_DUMP_PRE`, `ZANE_DUMP_OPT`, `ZANE_DUMP_BEFORE`,
`ZANE_DUMP_AFTER`, `ZANE_LLVM_OPTS`, `ZANE_FRAME_SHADOW_ONLY`,
`ZANE_FRAME_SHADOW_SLOTS`, `ZANE_SHADOW_AGAIN`, `ZANE_INTERLEAVE_REPORT`.
