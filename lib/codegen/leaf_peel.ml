(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_LEAF_PEEL=1): a
   recursive function's base case made at each of its self-calls with no
   call (leaf_peel_stubs.cpp), as Goose's compiler emits a recursion's
   leaves in place. *)

let on () = Sys.getenv_opt "ZANE_LEAF_PEEL" = Some "1"

external func : Llvm.llvalue -> int -> int = "zane_leaf_peel"

(* Functions of at most this many instructions, after LLVM's passes. *)
let budget = 200

let run m =
  let fs = ref [] in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then fs := f :: !fs) m;
  List.iter
    (fun f ->
      if func f budget = 1 && Sys.getenv_opt "ZANE_LEAF_PEEL_DEBUG" = Some "1" then
        prerr_endline ("leaf peel: " ^ Llvm.value_name f))
    !fs

(* The test and the base case inlined at each call, then folded. *)
let again =
  "always-inline,function(sroa,early-cse<memssa>,instcombine<no-verify-fixpoint>,simplifycfg,gvn,simplifycfg),globaldce"
