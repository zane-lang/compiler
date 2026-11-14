(* EXPERIMENT (LangArena zane-vs-c; on with ZANE_FRAME_SHADOW=1): frame
   slots kept in registers.

   A held local lives in its scope's frame, which the runtime places, so
   LLVM keeps every slot in memory: a list's count and block are loaded
   and stored each time round a loop wherever the loop holds a call that
   may grow the list, even on a path the loop seldom takes, where C keeps
   its locals in registers.

   After the O2 passes, each slot of a frame (a base an `llvm.assume`
   names, as every placed frame has) past the frame's record
   ([Abi.mark_size]) that is only loaded and stored whole, always as the
   same scalar type, gets a copy in an alloca: the copy is filled from the
   slot where the frame is placed, every store also stores to it, every
   load reads it, and after a call given an address in the frame it is
   filled again. The slot is still written each time, so the runtime and
   every callee see it as before; only reads move to the copy, which SROA
   then makes a register. A frame whose address escapes any other way (a
   pointer stored, an offset that is not a constant, a merge with another
   pointer) is left alone. *)

let on () = Sys.getenv_opt "ZANE_FRAME_SHADOW" = Some "1"

let debug () = Sys.getenv_opt "ZANE_FRAME_SHADOW_DEBUG" = Some "1"

let callee i =
  let n = Llvm.num_operands i in
  let f = Llvm.operand i (n - 1) in
  if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* An intrinsic that reads or writes no memory a frame holds. *)
let inert name =
  starts "llvm." name
  && not (starts "llvm.memcpy" name || starts "llvm.memmove" name || starts "llvm.memset" name)

(* A GEP's constant byte offset from its pointer operand. *)
let gep_offset dl p =
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
              walk (Llvm.struct_element_types t).(k) (i + 1)
                (Int64.add offset (Llvm_target.DataLayout.offset_of_element t k dl))
          | Llvm.TypeKind.Array ->
              let e = Llvm.element_type t in
              walk e (i + 1) (Int64.add offset (Int64.mul c (Llvm_target.DataLayout.abi_size e dl)))
          | _ -> None)
  in
  match Llvm.int64_of_const (Llvm.operand p 1) with
  | None -> None
  | Some c -> walk source 2 (Int64.mul c (Llvm_target.DataLayout.abi_size source dl))

(* [p]'s constant byte offset from [base], through constant GEPs and
   through phis and selects whose every input is at the same offset.
   [seen] holds the merges already reached: their offset, or [None] while
   one is being worked out, which a loop back to it agrees with. *)
let rec offset_from dl seen base p =
  if p == base then Some (Some 0L)
  else
    match List.assq_opt p !seen with
    | Some o -> Some o
    | None -> (
        match Llvm.classify_value p with
        | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
            match (gep_offset dl p, offset_from dl seen base (Llvm.operand p 0)) with
            | Some d, Some (Some o) -> Some (Some (Int64.add d o))
            | _, Some None -> Some None
            | _ -> None)
        | Llvm.ValueKind.Instruction (Llvm.Opcode.PHI | Llvm.Opcode.Select as op) -> (
            seen := (p, None) :: !seen;
            let inputs =
              if op = Llvm.Opcode.PHI then List.map fst (Llvm.incoming p)
              else [ Llvm.operand p 1; Llvm.operand p 2 ]
            in
            let offsets = List.map (offset_from dl seen base) inputs in
            seen := List.filter (fun (q, _) -> q != p) !seen;
            if List.exists Option.is_none offsets then None
            else
              match List.sort_uniq compare (List.filter_map Fun.id (List.map Option.get offsets)) with
              | [ o ] ->
                  seen := (p, Some o) :: !seen;
                  Some (Some o)
              | _ -> None)
        | _ -> None)


(* Whether block [a] dominates block [b] in [f] (Cooper, Harvey and
   Kennedy's iteration over reverse postorder), as a function of [f]. *)
let dominators f =
  let entry = Llvm.entry_block f in
  let order = ref [] and seen = ref [] in
  let rec dfs b =
    if not (List.memq b !seen) then begin
      seen := b :: !seen;
      (match Llvm.block_terminator b with
      | Some t -> Array.iter dfs (Llvm.successors t)
      | None -> ());
      order := b :: !order
    end
  in
  dfs entry;
  let rpo = Array.of_list !order in
  let n = Array.length rpo in
  let index b =
    let rec go i = if i >= n then -1 else if rpo.(i) == b then i else go (i + 1) in
    go 0
  in
  let preds = Array.make n [] in
  Array.iteri
    (fun i b ->
      match Llvm.block_terminator b with
      | Some t -> Array.iter (fun s -> let j = index s in if j >= 0 then preds.(j) <- i :: preds.(j)) (Llvm.successors t)
      | None -> ())
    rpo;
  let idom = Array.make n (-1) in
  idom.(0) <- 0;
  let rec intersect a b =
    if a = b then a else if a > b then intersect idom.(a) b else intersect a idom.(b)
  in
  let changed = ref true in
  while !changed do
    changed := false;
    for i = 1 to n - 1 do
      let ps = List.filter (fun p -> idom.(p) >= 0) preds.(i) in
      match ps with
      | [] -> ()
      | p :: rest ->
          let d = List.fold_left intersect p rest in
          if idom.(i) <> d then begin
            idom.(i) <- d;
            changed := true
          end
    done
  done;
  fun a b ->
    let a = index a and b = index b in
    if a < 0 || b < 0 then false
    else
      let rec up x = if x = a then true else if x = 0 then a = 0 else up idom.(x) in
      up b

(* Whether instruction [a] comes before [b] in their one block. *)
let before a b =
  let rec go = function
    | Llvm.Before i -> if i == a then true else if i == b then false else go (Llvm.instr_succ i)
    | Llvm.At_end _ -> false
  in
  go (Llvm.instr_begin (Llvm.instr_parent a))

exception Escapes_at of Llvm.llvalue

let scalar t =
  match Llvm.classify_type t with
  | Llvm.TypeKind.Integer | Llvm.TypeKind.Pointer | Llvm.TypeKind.Double | Llvm.TypeKind.Float -> true
  | _ -> false

let func ctx dl (f : Llvm.llvalue) =
  (* The frames: what an `llvm.assume` names. *)
  let frames = ref [] in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          if Llvm.instr_opcode i = Llvm.Opcode.Call && callee i = Some "llvm.assume" then
            for k = 1 to Llvm.num_operands i - 2 do
              let v = Llvm.operand i k in
              match Llvm.classify_value v with
              | Llvm.ValueKind.Instruction _ when not (List.memq v !frames) -> frames := v :: !frames
              | _ -> ()
            done)
        b)
    f;
  if debug () then Printf.eprintf "frame shadow: %s: %d frames\n" (Llvm.value_name f) (List.length !frames);
  let shadowed = ref 0 in
  let dom = lazy (dominators f) in
  List.iter
    (fun base ->
      (* Every use of an address in the frame: loads and stores at their
         offsets, and calls given one. *)
      let loads = ref [] and stores = ref [] and calls = ref [] and escaped = ref false in
      let seen = ref [] and visited = ref [] in
      let at i = match offset_from dl seen base i with Some (Some o) -> o | _ -> raise (Escapes_at i) in
      let mark = Int64.of_int Abi.mark_size in
      let rec visit p off =
        Llvm.iter_uses
          (fun u ->
            let i = Llvm.user u in
            match Llvm.classify_value i with
            | Llvm.ValueKind.Instruction op -> (
                match op with
                | Llvm.Opcode.GetElementPtr when Llvm.operand i 0 == p -> visit i (at i)
                | Llvm.Opcode.PHI | Llvm.Opcode.Select when Llvm.operand i 0 != p || op = Llvm.Opcode.PHI ->
                    if not (List.memq i !visited) then begin
                      visited := i :: !visited;
                      visit i (at i)
                    end
                | Llvm.Opcode.Load -> loads := (i, off) :: !loads
                | Llvm.Opcode.Store when Llvm.operand i 1 == p && Llvm.operand i 0 != p -> stores := (i, off) :: !stores
                (* The frame's record names it in the scope chain. *)
                | Llvm.Opcode.Store when Llvm.operand i 0 == p && off < mark -> ()
                (* A slot's address the runtime keeps, as a deferred job
                   does: any call may then write the slot. *)
                | Llvm.Opcode.Store when Llvm.operand i 0 == p && Llvm.operand i 1 != p -> escaped := true
                | Llvm.Opcode.Call -> (
                    match callee i with
                    | Some n when inert n -> ()
                    | _ -> if not (List.memq i !calls) then calls := i :: !calls)
                | Llvm.Opcode.ICmp -> ()
                | _ -> raise (Escapes_at i))
            | _ -> raise (Escapes_at i))
          p
      in
      match visit base 0L with
      | exception Escapes_at i ->
          if debug () then
            Printf.eprintf "frame shadow: %s: escapes at %s\n" (Llvm.value_name f)
              (let s = Llvm.string_of_llvalue i in String.sub s 0 (min 120 (String.length s)))
      | () ->
          let size t = Llvm_target.DataLayout.store_size t dl in
          let accesses =
            List.map (fun (i, o) -> (o, Llvm.type_of i)) !loads
            @ List.map (fun (i, o) -> (o, Llvm.type_of (Llvm.operand i 0))) !stores
          in
          (* A slot: an offset loaded at least once, where every access that
             overlaps it is of the same offset and type. *)
          let slots =
            List.sort_uniq compare (List.map snd (List.filter (fun (_, o) -> o >= mark) !loads))
            |> List.filter_map (fun o ->
                   let t = Llvm.type_of (fst (List.find (fun (_, o2) -> o2 = o) !loads)) in
                   let hi = Int64.add o (size t) in
                   let overlapping =
                     List.filter (fun (o', t') -> o' < hi && Int64.add o' (size t') > o) accesses
                   in
                   if scalar t && List.for_all (fun (o', t') -> o' = o && t' == t) overlapping then Some (o, t) else None)
          in
          (* ZANE_FRAME_SHADOW_OFFSETS: only these slot offsets (decimal,
             comma-separated), for finding which slot's copy changes a time. *)
          let slots =
            match Sys.getenv_opt "ZANE_FRAME_SHADOW_OFFSETS" with
            | None -> slots
            | Some l ->
                let keep = List.filter_map Int64.of_string_opt (String.split_on_char ',' l) in
                List.filter (fun (o, _) -> List.mem o keep) slots
          in
          let stored o = List.length (List.filter (fun (_, o') -> o' = o) !stores) in
          (* EXPERIMENT (ZANE_FRAME_SHADOW_WRITTEN=1): only a slot stored more
             than once gets a copy. One written once, where its value is made,
             and then only read is left a load: the copy keeps its value in a
             register across every loop that reads it, and HuffDecode's tree
             root, read once per symbol, got 25% slower for it (step 16). *)
          let slots =
            match Sys.getenv_opt "ZANE_FRAME_SHADOW_WRITTEN" with
            | Some "1" -> List.filter (fun (o, _) -> stored o > 1) slots
            | Some "2" -> List.filter (fun (o, _) -> stored o > 0) slots
            | _ -> slots
          in
          if debug () then
            List.iter
              (fun (o, t) ->
                Printf.eprintf "frame shadow: %s: slot %Ld %s, %d stores\n" (Llvm.value_name f) o (Llvm.string_of_lltype t)
                  (stored o))
              slots;
          if slots <> [] then begin
            let entry = Llvm.entry_block f in
            let at_entry = Llvm.builder_at ctx (Llvm.instr_begin entry) in
            let i8 = Llvm.i8_type ctx and i64 = Llvm.i64_type ctx in
            let copies = List.map (fun (o, t) -> (o, t, Llvm.build_alloca t "shadow" at_entry)) slots in
            let fill b =
              List.iter
                (fun (o, t, a) ->
                  let p = Llvm.build_in_bounds_gep i8 base [| Llvm.const_of_int64 i64 o true |] "" b in
                  ignore (Llvm.build_store (Llvm.build_load t p "" b) a b))
                copies
            in
            (* Filled where the frame is placed: after it, past any phis. *)
            let placed =
              match Llvm.classify_value base with
              | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
                  let rec past = function
                    | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.PHI -> past (Llvm.instr_succ i)
                    | pos -> pos
                  in
                  past (Llvm.instr_begin (Llvm.instr_parent base))
              | _ -> Llvm.instr_succ base
            in
            fill (Llvm.builder_at ctx placed);
            let copy o = List.find_opt (fun (o', _, _) -> o' = o) copies in
            List.iter
              (fun (i, o) ->
                match copy o with
                | Some (_, t, a) ->
                    let b = Llvm.builder_before ctx i in
                    let v = Llvm.build_load t a "" b in
                    Llvm.replace_all_uses_with i v;
                    Llvm.delete_instruction i
                | None -> ())
              !loads;
            List.iter
              (fun (i, o) ->
                match copy o with
                | Some (_, _, a) ->
                    let b = Llvm.builder_at ctx (Llvm.instr_succ i) in
                    ignore (Llvm.build_store (Llvm.operand i 0) a b)
                | None -> ())
              !stores;
            (* A frame a slot's address escaped from is filled again after
               every call it is placed before. *)
            if !escaped then begin
              let dom = Lazy.force dom in
              let bb = Llvm.instr_parent base in
              Llvm.iter_blocks
                (fun b ->
                  Llvm.iter_instrs
                    (fun i ->
                      if Llvm.instr_opcode i = Llvm.Opcode.Call && not (List.memq i !calls) then
                        match callee i with
                        | Some n when inert n -> ()
                        | _ ->
                            if (b == bb && before base i) || (b != bb && dom bb b) then calls := i :: !calls)
                    b)
                f
            end;
            List.iter
              (fun c ->
                match Llvm.instr_succ c with
                | Llvm.Before _ as pos -> fill (Llvm.builder_at ctx pos)
                | Llvm.At_end _ -> ())
              !calls;
            shadowed := !shadowed + List.length slots
          end)
    !frames;
  if debug () && !shadowed > 0 then
    Printf.eprintf "frame shadow: %s: %d slots\n" (Llvm.value_name f) !shadowed

let run m =
  if on () then begin
    let ctx = Llvm.module_context m in
    let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
    (* ZANE_FRAME_SHADOW_ONLY / _SKIP: comma-separated substrings of the
       functions that get copies, or that do not ("" in SKIP matches every
       function, leaving only the passes run again). For finding which
       function's copies change a test's time. *)
    let names v = Option.map (String.split_on_char ',') (Sys.getenv_opt v) in
    let has s sub =
      let n = String.length sub and m = String.length s in
      let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
      go 0
    in
    let picked f =
      let name = Llvm.value_name f in
      (match names "ZANE_FRAME_SHADOW_ONLY" with None -> true | Some l -> List.exists (has name) l)
      && match names "ZANE_FRAME_SHADOW_SKIP" with None -> true | Some l -> not (List.exists (has name) l)
    in
    Llvm.iter_functions (fun f -> if (not (Llvm.is_declaration f)) && picked f then func ctx dl f) m
  end

(* The passes run again once the copies are in. *)
let again =
  "function(sroa,early-cse<memssa>,loop-mssa(licm<allowspeculation>),gvn<pre;load-pre>,instcombine<no-verify-fixpoint>,simplifycfg,dse,loop-mssa(licm<allowspeculation>))"
