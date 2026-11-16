(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_DIV_CACHE=1): a loop's
   division by a divisor that is not a constant made a multiplication by
   its reciprocal, cached per division (div_cache_stubs.cpp). *)

let on () = Sys.getenv_opt "ZANE_DIV_CACHE" = Some "1"

external func : Llvm.llvalue -> int = "zane_div_cache"

(* `zane_div_magic`, declared as the pass calls it. A tiered build declares
   it in both tiers before either lists what tier 1 takes from tier 0
   (Tiers.shared): tier 1's pass calls it after that list is made. *)
let declare m =
  let ctx = Llvm.module_context m in
  let i64 = Llvm.i64_type ctx in
  ignore (Llvm.declare_function "zane_div_magic" (Llvm.function_type (Llvm.struct_type ctx [| i64; i64 |]) [| i64 |]) m)

let run m =
  let n = ref 0 in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then n := !n + func f) m;
  if Sys.getenv_opt "ZANE_DIV_CACHE_DEBUG" = Some "1" then prerr_endline (Printf.sprintf "div cache: %d divisions" !n)

(* The caches made registers, the reciprocal's arithmetic folded. *)
let again =
  if Sys.getenv_opt "ZANE_DIV_HOIST" = Some "1" then
    "function(sroa,instcombine<no-verify-fixpoint>,simplifycfg,early-cse<memssa>,loop-mssa(licm<allowspeculation>,simple-loop-unswitch),simplifycfg)"
  else "function(sroa,instcombine<no-verify-fixpoint>,simplifycfg,early-cse<memssa>)"
