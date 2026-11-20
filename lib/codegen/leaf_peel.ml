(* A recursive function's base case made at each of its self-calls with no
   call (leaf_peel_stubs.cpp), so a recursion's leaves take no call. *)


external func : Llvm.llvalue -> int -> int -> int = "zane_leaf_peel"

(* Functions of at most this many instructions, after LLVM's passes. *)
let budget = 200

(* Functions whose frame allocates at most this many bytes: the leaf
   inlined at a self-call adds its own copy of the frame's allocations to
   each level of the recursion. *)
let frame = 4096

let run m =
  let fs = ref [] in
  (* A memoized function's own body (Cgt.Memo) is left: its table already
     answers the calls that repeat, and a test at each call costs more than
     the calls it saves (tests/perf `leaves`). *)
  let remembered f = String.ends_with ~suffix:Cgt.Memo.suffix_plain (Llvm.value_name f) in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f || remembered f) then fs := f :: !fs) m;
  List.iter (fun f -> ignore (func f budget frame)) !fs

(* The test and the base case inlined at each call, then folded. *)
let again =
  "always-inline,function(sroa,early-cse<memssa>,instcombine<no-verify-fixpoint>,constraint-elimination,simplifycfg,gvn,simplifycfg),globaldce"
