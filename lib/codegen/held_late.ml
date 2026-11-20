(* Experimental (docs/experiments/held-allocas, ZANE_HELD_ALLOCAS=1 and
   ZANE_HELD_LATE=1): held allocas given to Zane functions, settled after
   LLVM's passes.

   Held_spills leaves a held alloca given to a Zane function as it is, and
   marks each held alloca where it is held with an `llvm.assume` naming it
   and its frame slot (Llvm_extra.assume_held). LLVM's passes may inline the
   function, after which SROA keeps the alloca in registers and drops the
   mark's use of it, or may leave the call. SROA leaves alone an alloca whose
   address any call is still given, so such an alloca is never split.

   After the passes, each mark that still names an alloca settles it as
   Held_spills settles one before them: a call to the runtime is given the
   frame slot around the call, and any other use the alloca does not allow
   (a call to a Zane function above all) gives the alloca's uses the frame
   slot. Every mark is then removed, since Frame_shadow takes what an
   assume names for a frame, and SROA runs again over the copies. *)

let on () = Held_spills.on && Held_spills.late

(* The marks in [f]: an assume whose bundles name a pointer and then
   another pointer, where the frames' own name a pointer and then a size. *)
let marks f =
  let found = ref [] in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          if
            Llvm.instr_opcode i = Llvm.Opcode.Call
            && Held_spills.callee i = Some "llvm.assume"
            && Llvm.num_operands i = 5
            && Llvm.classify_type (Llvm.type_of (Llvm.operand i 2)) = Llvm.TypeKind.Pointer
          then found := i :: !found)
        b)
    f;
  List.rev !found

let is_alloca v = match Llvm.classify_value v with Llvm.ValueKind.Instruction Llvm.Opcode.Alloca -> true | _ -> false

(* Whether instruction [d] comes before every use of [a]: in a phi, at the
   end of the block the value comes from. *)
let reaches dominates d a =
  let ok = ref true in
  Llvm.iter_uses
    (fun u ->
      let i = Llvm.user u in
      let at =
        if Llvm.instr_opcode i = Llvm.Opcode.PHI then
          match List.find_opt (fun (v, _) -> v == a) (Llvm.incoming i) with
          | Some (_, b) -> ( match Llvm.block_terminator b with Some t -> t | None -> i)
          | None -> i
        else i
      in
      let db = Llvm.instr_parent d and ab = Llvm.instr_parent at in
      if not (if db == ab then Frame_shadow.before d at else dominates db ab) then begin
        if Held_spills.debug then Printf.eprintf "late: not reached: %s\n" (Llvm.string_of_llvalue i);
        ok := false
      end)
    a;
  !ok

let settle ctx dl f =
  let dominates = lazy (Frame_shadow.dominators f) in
  List.iter
    (fun mark ->
      let a = Llvm.operand mark 1 and slot = Llvm.operand mark 2 in
      Llvm.delete_instruction mark;
      if is_alloca a then begin
        let ty = Wrappers.allocated_type a in
        match Held_spills.uses ~after:true dl a 0L [] with
        | None ->
            (* A lifetime marker takes only an alloca; the slot is the
               frame's for the whole scope. *)
            let lifetimes = ref [] in
            Llvm.iter_uses
              (fun u ->
                let i = Llvm.user u in
                match Held_spills.callee i with
                | Some n when Held_spills.starts "llvm.lifetime" n -> lifetimes := i :: !lifetimes
                | _ -> ())
              a;
            List.iter Llvm.delete_instruction !lifetimes;
            if not (reaches (Lazy.force dominates) slot a) then
              Diagnostic.bug (Printf.sprintf "held allocas: `%s` uses an alloca before its frame slot" (Llvm.value_name f));
            if Held_spills.debug then Printf.eprintf "late %s: framed\n" (Llvm.value_name f);
            Llvm.replace_all_uses_with a slot;
            Llvm.delete_instruction a
        | Some spills ->
            if Held_spills.debug then
              Printf.eprintf "late %s: alloca of %s, spills at %s\n" (Llvm.value_name f) (Llvm.string_of_lltype ty)
                (String.concat ", "
                   (List.filter_map
                      (function Held_spills.Spill (c, _, _) -> Held_spills.callee c | Held_spills.Fine -> None)
                      spills));
            Held_spills.spill ctx ty a slot spills
      end)
    (marks f)

let run m =
  let ctx = Llvm.module_context m in
  let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then settle ctx dl f) m

let again = Frame_shadow.again
