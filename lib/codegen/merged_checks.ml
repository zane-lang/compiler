(* EXPERIMENT (LangArena zane-vs-c; on with ZANE_MERGE_CHECKS=1): one
   check of an index against every list it is about to index.

   `ranks[prior]~=ranks[index] or second[prior]~=second[index]` checks
   `prior` against `ranks`'s count and then against `second`'s, where C
   indexes both with no check at all. A failed check stops the program
   (`zane_out_of_range` flushes the output and exits), so where a later
   check of the same index follows an earlier one on every path, with no
   call between them that could write output, stopping at the earlier
   one instead is the same to everything outside the program: the earlier
   check compares against the smaller of the two counts, and the later
   one goes.

   A check is a conditional branch on an unsigned compare of an index
   against a bound, one of whose targets does nothing but call
   `zane_out_of_range`. From each, the path is followed through blocks
   with no other way in, past stores and other checks, until a call, any
   other branch, or the end; each check of the same index on it whose
   bound is defined above the first check is folded into the first. *)

let on () = Sys.getenv_opt "ZANE_MERGE_CHECKS" = Some "1"

let callee i =
  let n = Llvm.num_operands i in
  let f = Llvm.operand i (n - 1) in
  if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

(* Whether block [b] does nothing but stop the program out of range. *)
let rec stops ?(depth = 4) b =
  match Llvm.instr_begin b with
  | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Call -> (
      callee i = Some "zane_out_of_range"
      && match Llvm.instr_succ i with Llvm.Before u -> Llvm.instr_opcode u = Llvm.Opcode.Unreachable | _ -> false)
  | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Br && Llvm.num_operands i = 1 && depth > 0 ->
      stops ~depth:(depth - 1) (Llvm.block_of_value (Llvm.operand i 0))
  | _ -> false

(* A check: the terminator [t] of a block, the compare it branches on, the
   index and the bound (passing when index <u bound), and the block it
   continues to when it passes. *)
let check t =
  if Llvm.instr_opcode t <> Llvm.Opcode.Br || Llvm.num_operands t <> 3 then None
  else
    let c = Llvm.operand t 0 in
    (* Operands of a conditional `br`: the condition, then the false and
       the true target. *)
    let if_false = Llvm.block_of_value (Llvm.operand t 1) and if_true = Llvm.block_of_value (Llvm.operand t 2) in
    match Llvm.classify_value c with
    | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp -> (
        let a = Llvm.operand c 0 and b = Llvm.operand c 1 in
        let pred = Llvm.icmp_predicate c in
        let passing =
          match pred with
          | Some Llvm.Icmp.Ult -> Some (a, b, true)
          | Some Llvm.Icmp.Ugt -> Some (b, a, true)
          | Some Llvm.Icmp.Uge -> Some (a, b, false)
          | Some Llvm.Icmp.Ule -> Some (b, a, false)
          | _ -> None
        in
        match passing with
        | Some (index, bound, true) when stops if_false -> Some (c, index, bound, if_true, true)
        | Some (index, bound, false) when stops if_true -> Some (c, index, bound, if_false, false)
        | _ -> None)
    | _ -> None

let inert name = String.length name >= 5 && String.sub name 0 5 = "llvm." && not (String.starts_with ~prefix:"llvm.mem" name)

(* Whether only one branch leads to [b]. *)
let single_pred b =
  let n = ref 0 in
  Llvm.iter_uses (fun _ -> incr n) (Llvm.value_of_block b);
  !n = 1

let func ctx f =
  let dom = lazy (Frame_shadow.dominators f) in
  let merged = ref 0 in
  (* Whether [v] is defined above instruction [at]. *)
  let above v at =
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction _ ->
        let vb = Llvm.instr_parent v and ab = Llvm.instr_parent at in
        if vb == ab then Frame_shadow.before v at else (Lazy.force dom) vb ab
    | _ -> true
  in
  let blocks = Llvm.fold_left_blocks (fun acc b -> b :: acc) [] f |> List.rev in
  List.iter
    (fun b0 ->
      match Llvm.block_terminator b0 with
      | None -> ()
      | Some t0 -> (
          match check t0 with
          | None -> ()
          | Some (c0, index, _, next, _) ->
              let rec follow b =
                if not (single_pred b) then ()
                else
                  let rec scan = function
                    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.Call -> (
                        match callee i with Some n when inert n -> scan (Llvm.instr_succ i) | _ -> false)
                    | Llvm.Before i when i == Option.get (Llvm.block_terminator b) -> true
                    | Llvm.Before i -> scan (Llvm.instr_succ i)
                    | Llvm.At_end _ -> false
                  in
                  if scan (Llvm.instr_begin b) then
                    let t = Option.get (Llvm.block_terminator b) in
                    match check t with
                    | Some (c, i, bound, cont, passes_true) ->
                        if Sys.getenv_opt "ZANE_MERGE_CHECKS_DEBUG" = Some "2" && i == index then
                          Printf.eprintf "  pair in %s: above=%b same=%b\n" (Llvm.value_name f) (above bound c0) (c == c0);
                        if i == index && above bound c0 && c != c0 then begin
                          (* The first check takes the smaller bound. *)
                          let builder = Llvm.builder_before ctx c0 in
                          let ty = Llvm.type_of bound in
                          let umin =
                            let name = Printf.sprintf "llvm.umin.i%d" (Llvm.integer_bitwidth ty) in
                            let fty = Llvm.function_type ty [| ty; ty |] in
                            let fn =
                              match Llvm.lookup_function name (Llvm.global_parent f) with
                              | Some fn -> fn
                              | None -> Llvm.declare_function name fty (Llvm.global_parent f)
                            in
                            fun x y -> Llvm.build_call fty fn [| x; y |] "" builder
                          in
                          (* c0 compares index with its bound in one of four
                             forms; its bound operand is replaced. *)
                          let k = if Llvm.operand c0 0 == index then 1 else 0 in
                          let old = Llvm.operand c0 k in
                          if Llvm.type_of old == ty then begin
                            Llvm.set_operand c0 k (umin old bound);
                            Llvm.set_operand t 0 (Llvm.const_int (Llvm.i1_type ctx) (if passes_true then 1 else 0));
                            incr merged
                          end
                        end;
                        follow cont
                    | None -> (
                        match Llvm.instr_opcode t with
                        | Llvm.Opcode.Br when Llvm.num_operands t = 1 -> follow (Llvm.block_of_value (Llvm.operand t 0))
                        | _ -> ())
              in
              follow next))
    blocks;
  if Sys.getenv_opt "ZANE_MERGE_CHECKS_DEBUG" = Some "1" && !merged > 0 then
    Printf.eprintf "merged checks: %s: %d\n" (Llvm.value_name f) !merged

let run m =
  if on () then
    let ctx = Llvm.module_context m in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx f) m

let again = "function(instcombine<no-verify-fixpoint>,simplifycfg,loop-mssa(licm<allowspeculation>),gvn,simplifycfg)"
