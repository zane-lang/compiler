(* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_DIV_CACHE=1): a loop's
   division by a divisor that is not a constant made a multiplication by
   its reciprocal, cached per division (div_cache_stubs.cpp). *)

let on () = Sys.getenv_opt "ZANE_DIV_CACHE" = Some "1"

external func : Llvm.llvalue -> int = "zane_div_cache"

let run m =
  let n = ref 0 in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then n := !n + func f) m;
  if Sys.getenv_opt "ZANE_DIV_CACHE_DEBUG" = Some "1" then prerr_endline (Printf.sprintf "div cache: %d divisions" !n)

(* The caches made registers, the reciprocal's arithmetic folded. *)
let again =
  if Sys.getenv_opt "ZANE_DIV_HOIST" = Some "1" then
    "function(sroa,instcombine<no-verify-fixpoint>,simplifycfg,early-cse<memssa>,loop-mssa(licm<allowspeculation>,simple-loop-unswitch),simplifycfg)"
  else "function(sroa,instcombine<no-verify-fixpoint>,simplifycfg,early-cse<memssa>)"
