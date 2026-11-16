(* EXPERIMENT (LangArena zane-vs-c; on with ZANE_FRAME_SCOPES=1): alias
   scopes for the slots of a frame.

   A held local lives in its scope's frame, which the runtime places, so to
   LLVM every slot is memory the runtime may reach: a call such as
   `zane_list_push(&tape.bytes)` in a cold path of a loop makes it reload
   every other slot of the frame each time round, where C's locals, whose
   address only inlined code sees, stay in registers.

   Each function's accesses at a constant offset from one base (a frame, or
   an alloca) are grouped by the bytes they touch, overlapping ranges
   together, and each group gets its own scope: a load or store is in its
   group's scope and noalias with the base's other groups. A call to the
   runtime's list growth (push, reserve, room) touches only the list's
   header at its first argument, the list's blocks and the runtime's own
   records, so it gets the header's group and is noalias with the rest.
   The frame's record (its first [Abi.mark_size] bytes), which the runtime
   writes as it allocates, is never put in a group.

   A scope is declared (`llvm.experimental.noalias.scope.decl`) right
   after its base is made, so a frame placed again, in a later iteration
   or by another inlined copy, is a new instance of it. *)

let on () = Sys.getenv_opt "ZANE_FRAME_SCOPES" = Some "1"

let list_calls = [ "zane_list_push"; "zane_list_reserve"; "zane_list_room" ]

(* [p] as its base and a constant byte offset, through constant GEPs. *)
let rec decompose dl p =
  match Llvm.classify_value p with
  | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
      let source = Llvm_extra.gep_source_type p in
      let n = Llvm.num_operands p in
      let rec walk t i offset =
        if i >= n then Some offset
        else
          match Llvm.int64_of_const (Llvm.operand p i) with
          | None -> None
          | Some c -> (
              match Llvm.classify_type t with
              | Llvm.TypeKind.Struct ->
                  let k = Int64.to_int c in
                  walk (Llvm_extra.struct_element_types t).(k) (i + 1)
                    (Int64.add offset (Llvm_target.DataLayout.offset_of_element t k dl))
              | Llvm.TypeKind.Array ->
                  let e = Llvm.element_type t in
                  walk e (i + 1) (Int64.add offset (Int64.mul c (Llvm_target.DataLayout.abi_size e dl)))
              | _ -> None)
      in
      match Llvm.int64_of_const (Llvm.operand p 1) with
      | None -> None
      | Some c -> (
          match walk source 2 (Int64.mul c (Llvm_target.DataLayout.abi_size source dl)) with
          | None -> None
          | Some off -> (
              match decompose dl (Llvm.operand p 0) with
              | Some (base, o) -> Some (base, Int64.add o off)
              | None -> None)))
  | Llvm.ValueKind.Instruction
      (Llvm.Opcode.Alloca | Llvm.Opcode.Call | Llvm.Opcode.PHI | Llvm.Opcode.Load | Llvm.Opcode.IntToPtr | Llvm.Opcode.Select) ->
      Some (p, 0L)
  | _ -> None

let callee i =
  let n = Llvm.num_operands i in
  let f = Llvm.operand i (n - 1) in
  if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

let func ctx m dl (f : Llvm.llvalue) =
  let header = Llvm_target.DataLayout.abi_size (List_handle.header ctx) dl in
  (* Each access: the instruction, its base, and the bytes it touches. *)
  let accesses = ref [] in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          let add p size =
            match decompose dl p with
            | Some (base, off) when Llvm.int64_of_const base = None && off >= Int64.of_int Abi.mark_size ->
                accesses := (i, base, off, Int64.add off size) :: !accesses
            | _ -> ()
          in
          match Llvm.instr_opcode i with
          | Llvm.Opcode.Load -> add (Llvm.operand i 0) (Llvm_target.DataLayout.store_size (Llvm.type_of i) dl)
          | Llvm.Opcode.Store ->
              add (Llvm.operand i 1) (Llvm_target.DataLayout.store_size (Llvm.type_of (Llvm.operand i 0)) dl)
          | Llvm.Opcode.Call -> (
              match callee i with
              | Some name when List.mem name list_calls -> add (Llvm.operand i 0) header
              | _ -> ())
          | _ -> ())
        b)
    f;
  (* Per base, its ranges merged where they overlap. *)
  let bases = List.sort_uniq compare (List.map (fun (_, b, _, _) -> b) !accesses) in
  let kind = Llvm.mdkind_id ctx in
  let decl =
    lazy
      (let t = Llvm.function_type (Llvm.void_type ctx) [| Llvm.type_of (Llvm.mdstring ctx "") |] in
       match Llvm.lookup_function "llvm.experimental.noalias.scope.decl" m with
       | Some d -> (d, t)
       | None -> (Llvm.declare_function "llvm.experimental.noalias.scope.decl" t m, t))
  in
  List.iteri
    (fun bi base ->
      let mine = List.filter (fun (_, b, _, _) -> b == base) !accesses in
      let ranges = List.sort compare (List.map (fun (_, _, lo, hi) -> (lo, hi)) mine) in
      let groups =
        List.fold_left
          (fun acc (lo, hi) ->
            match acc with
            | (glo, ghi) :: rest when lo < ghi -> (glo, max hi ghi) :: rest
            | _ -> (lo, hi) :: acc)
          [] ranges
        |> List.rev
      in
      if Sys.getenv_opt "ZANE_FRAME_SCOPES_DEBUG" = Some "1" then
        Printf.eprintf "frame scopes: %s base %d: %d accesses, %d groups, %d list calls\n" (Llvm.value_name f) bi
          (List.length mine) (List.length groups)
          (List.length (List.filter (fun (i, _, _, _) -> Llvm.instr_opcode i = Llvm.Opcode.Call) mine));
      if List.length groups >= 2 then begin
        let name = Printf.sprintf "%s.frame%d" (Llvm.value_name f) bi in
        let domain = Llvm_extra.loop_id ctx [| Llvm.mdstring ctx name |] in
        let scopes =
          List.mapi (fun gi _ -> Llvm_extra.loop_id ctx [| domain; Llvm.mdstring ctx (Printf.sprintf "%s.%d" name gi) |]) groups
        in
        let group_of lo = List.find_index (fun (glo, ghi) -> lo >= glo && lo < ghi) groups |> Option.get in
        List.iter
          (fun (i, _, lo, _) ->
            let g = group_of lo in
            let own = List.nth scopes g in
            let others = List.filteri (fun k _ -> k <> g) scopes in
            Llvm.set_metadata i (kind "alias.scope") (Llvm.mdnode ctx [| own |]);
            Llvm.set_metadata i (kind "noalias") (Llvm.mdnode ctx (Array.of_list others)))
          mine;
        (* Declared where the base is made: after it, past any phis. *)
        let d, t = Lazy.force decl in
        let at =
          match Llvm.classify_value base with
          | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
              let b = Llvm.instr_parent base in
              let rec past = function
                | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.PHI -> past (Llvm.instr_succ i)
                | pos -> pos
              in
              past (Llvm.instr_begin b)
          | _ -> Llvm.instr_succ base
        in
        let builder = Llvm.builder_at ctx at in
        List.iter
          (fun s -> ignore (Llvm.build_call t d [| Llvm.mdnode ctx [| s |] |] "" builder))
          scopes
      end)
    bases

let run m =
  if on () then begin
    let ctx = Llvm.module_context m in
    let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
    Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx m dl f) m
  end

(* The passes run again once the scopes are in. *)
let again =
  "function(loop-mssa(licm<allowspeculation>),gvn<pre;load-pre>,instcombine<no-verify-fixpoint>,simplifycfg,loop-mssa(licm<allowspeculation>))"
