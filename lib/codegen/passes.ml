(* The LLVM pass pipelines a module goes through (docs/optimizations.md):
   [unoptimized] for a plain build and tier 0, [optimized] for an optimized
   build and tier 1 (docs/design/tiers.md T2).

   `elif` branches on `~this and condition`, where `this` is what the `if`
   before it branched on, so each way into it already decides that half.
   Jump threading sends the `if`'s body straight past the `elif` and the
   other way to the condition alone, which makes the two the one chain C's
   `else if` is. It has to see the branches as they were written: the CFG
   simplifier turns a cheap `if` body into selects, and then both bodies'
   work runs every time round a loop. *)

(* The passes an unoptimized build runs (docs/design/optimization.md O12):
   inlining the functions [Wrappers.mark] picks, which takes the call out of
   each of `core`'s one-line wrappers over an intrinsic, then putting the
   wrappers' scalars back in registers, folding what that makes constant and
   merging the blocks left behind, with no branch made a select yet, then
   jump threading and merging again. Each takes time in proportion to the
   instructions it reads. Jump threading before the first merge copies
   blocks the merge would have joined. Scalar replacement of aggregates and
   instruction combining are left out: on a value array of thousands of
   elements they take longer than the whole `-O2` pipeline. *)
let unoptimized =
  "always-inline,function(mem2reg,instsimplify,simplifycfg<no-speculate-blocks>,jump-threading,simplifycfg)"

(* An optimized build's passes: LLVM's `-O2` with two added
   (gen/o2_pipeline.sh). Jump threading runs at the end of the first
   function simplification, once each function's locals are in registers
   and before the inliner's passes make a branch a select. Inductive range
   check elimination (IRCE) runs where `-O2` has just rotated each loop and
   hoisted what it reads: it splits a loop that checks a list index into a
   main loop whose checks it has proved pass and the checked iterations
   around it, and the passes after it would turn the checks into exit tests
   it no longer recognizes. *)
let optimized = O2_pipeline.optimized

(* [optimized] with runtime loop unrolling off, for tier 1
   (docs/design/tiers.md T2). *)
let tier1 = O2_pipeline.tier1

(* The options LLVM is started with for [optimized] and [tier1], the same
   for both, since LLVM reads them once for the whole process. IRCE splits a
   loop only when its header runs at least this many times for each entry
   to it, since the split costs each entry more than a short loop saves:
   more than LLVM guesses for a loop it knows nothing of, and fewer than
   codegen says the long copy of a loop it emits twice goes round
   (Emit.versioned). *)
let llvm_options = [ "-irce-min-runtime-iterations=64" ]

(* [unoptimized], [optimized] when *optimize*, or [tier1] for *tier1*. *)
let pipeline ~optimize ~tier1:is_tier1 = if is_tier1 then tier1 else if optimize then optimized else unoptimized
