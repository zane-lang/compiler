(* The LLVM pass pipelines a module goes through (docs/optimizations.md):
   [unoptimized] for a plain build and tier 0, [optimized] for an optimized
   build, and [tier1] for tier 1 (docs/design/tiers.md T2).

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
   (lib/llvm/config/discover.ml). Jump threading runs at the end of the
   first function simplification, once each function's locals are in registers
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

(* A packed value's stride is rarely a power of two (lowering.md L5), and
   a loop whose index a loop-invariant condition picks multiplies it by
   the stride on every element rather than stepping a pointer by it.
   Non-trivial unswitching, which `-O3` runs and `-O2` does not, copies
   such a loop once for each way the condition goes, each with an index
   LLVM steps. It runs for AArch64 alone: there the multiplying loop is
   up to 28% slower, while on x86-64 it costs less than the copies do
   (docs/experiments/tight-layouts, steps 6, 11 and 12). *)
let unswitch triple =
  match String.split_on_char '-' triple with
  | arch :: _ -> String.starts_with ~prefix:"aarch64" arch || String.starts_with ~prefix:"arm64" arch
  | [] -> false

let nontrivial triple pipeline =
  let off = "simple-loop-unswitch<no-nontrivial;trivial>" and on = "simple-loop-unswitch<nontrivial;trivial>" in
  if not (unswitch triple) then pipeline
  else
    let n = String.length off in
    let b = Buffer.create (String.length pipeline) in
    let rec go i =
      if i > String.length pipeline - n then Buffer.add_string b (String.sub pipeline i (String.length pipeline - i))
      else if String.sub pipeline i n = off then (
        Buffer.add_string b on;
        go (i + n))
      else (
        Buffer.add_char b pipeline.[i];
        go (i + 1))
    in
    go 0;
    Buffer.contents b

(* The options LLVM is started with for [optimized] and [tier1], the same
   for both, since LLVM reads them once for the whole process. Every
   function starts on a 64-byte line, so where a function lies within its
   line, and so which branches share a predictor's entries, does not move
   when the code before it changes size: a change elsewhere once cost an
   unchanged loop of `copies` 40% more mispredicted branches (tests/perf).

   Instruction combining sinks no instruction into the block that uses it.
   It splits the load of a struct with no padding into a load of each
   member, so a packed sum read whole is read as its tag and its room, and
   with sinking on it moves the room's load into the case that reads the
   payload. Nothing tells LLVM that load is safe to make before the tag is
   tested, so the case stays a branch, one the predictor cannot learn when
   which case a value holds follows no pattern. Left beside the tag's load,
   the room is read either way and the case's work becomes a select
   (docs/optimizations.md, "A sum's case picked without a branch"). *)
let llvm_options = [ "-align-all-functions=6"; "-instcombine-code-sinking=false" ]

(* [unoptimized], [optimized] when *optimize*, or [tier1] for *tier1*,
   for [triple]. *)
let pipeline ~triple ~optimize ~tier1:is_tier1 =
  if is_tier1 then nontrivial triple tier1 else if optimize then nontrivial triple optimized else unoptimized
