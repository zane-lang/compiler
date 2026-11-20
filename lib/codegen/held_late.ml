(* Experimental (docs/experiments/held-allocas, ZANE_HELD_ALLOCAS=1 and
   ZANE_HELD_LATE=1): held allocas given to Zane functions, settled after
   LLVM's passes.

   Held_spills leaves a held alloca given to a Zane function as it is, and
   anchors each held alloca where it is held with a call naming it and its
   frame slot (Held_spills.anchor), which keeps it whole through LLVM's
   passes. Those passes may inline the function, or leave the call.

   After the passes, each anchored alloca is settled as Held_spills settles
   one before them: a call to the runtime is given the frame slot around
   the call, and any other use the alloca does not allow (a call to a Zane
   function above all) gives the alloca's uses the frame slot. The anchors
   then go, and SROA runs again, now free to keep the alloca in registers. *)

let on () = Held_spills.on && Held_spills.late

(* The anchors in [f] (Held_spills.anchor). *)
let marks f =
  let found = ref [] in
  Llvm.iter_blocks
    (fun b -> Llvm.iter_instrs (fun i -> if Held_spills.callee i = Some Held_spills.anchor_name then found := i :: !found) b)
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

(* [a], with its lifetime markers removed: a marker takes only an alloca,
   and the slot is the frame's for the whole scope. *)
let without_lifetimes a =
  let lifetimes = ref [] in
  Llvm.iter_uses
    (fun u ->
      let i = Llvm.user u in
      match Held_spills.callee i with
      | Some n when Held_spills.starts "llvm.lifetime" n -> lifetimes := i :: !lifetimes
      | _ -> ())
    a;
  List.iter Llvm.delete_instruction !lifetimes;
  a

(* Whether instruction [d] comes before instruction [i]. *)
let precedes dominates d i =
  let db = Llvm.instr_parent d and ib = Llvm.instr_parent i in
  if db == ib then Frame_shadow.before d i else dominates db ib

(* Each call [spills] names given the slot around it. The slot is read
   from [cell], an alloca each mark stored its own slot into where it
   stood: SROA, which runs again after this pass, makes it the slot of the
   pass the call is in, a phi where copies of the hold join. Every call is
   reached by a mark, since its local is held before it is used. *)
let around ctx ty a cell spills =
  List.iter
    (function
      | Held_spills.Fine -> ()
      | Held_spills.Spill (c, _, _) as s ->
          let b = Llvm.builder_before ctx c in
          let slot = Llvm.build_load (Llvm.pointer_type ctx) cell "" b in
          Held_spills.spill ctx ty a slot [ s ])
    spills

let settle ctx dl f =
  let dominates = lazy (Frame_shadow.dominators f) in
  if Held_spills.debug then begin
    let n = ref 0 and allocas = ref [] in
    Llvm.iter_blocks
      (fun b ->
        Llvm.iter_instrs
          (fun i ->
            if Held_spills.callee i = Some "llvm.assume" then incr n;
            if is_alloca i then allocas := Llvm.string_of_llvalue i :: !allocas)
          b)
      f;
    Printf.eprintf "late %s: %d assumes, %d marks, allocas: %s\n" (Llvm.value_name f) !n (List.length (marks f))
      (String.concat "; " !allocas)
  end;
  (* Each alloca with the slots its marks name: more than one where LLVM
     copied the code that holds it, as a loop's unrolling or peeling does,
     each copy naming the slot of its own pass. *)
  let named = ref [] in
  let top = Llvm.builder_at ctx (Llvm.instr_begin (Llvm.entry_block f)) in
  List.iter
    (fun mark ->
      let a = Llvm.operand mark 0 and slot = Llvm.operand mark 1 in
      if Held_spills.debug && not (is_alloca a) then
        Printf.eprintf "late %s: mark names %s\n" (Llvm.value_name f) (Llvm.string_of_llvalue a);
      if is_alloca a then begin
        let cell =
          match List.find_opt (fun (x, _, _) -> x == a) !named with
          | Some (_, slots, cell) ->
              slots := slot :: !slots;
              cell
          | None ->
              let cell = Llvm.build_alloca (Llvm.pointer_type ctx) "" top in
              named := (a, ref [ slot ], cell) :: !named;
              cell
        in
        ignore (Llvm.build_store slot cell (Llvm.builder_before ctx mark))
      end;
      Llvm.delete_instruction mark)
    (marks f);
  List.iter
    (fun (a, slots, cell) ->
      let ty = Wrappers.allocated_type a in
      let verdict = Held_spills.uses ~after:true dl a 0L [] in
      if verdict = None then ignore (without_lifetimes a);
      match (verdict, !slots) with
      | Some spills, _ ->
          if Held_spills.debug then
            Printf.eprintf "late %s: alloca of %s, spills at %s\n" (Llvm.value_name f) (Llvm.string_of_lltype ty)
              (String.concat ", "
                 (List.filter_map
                    (function Held_spills.Spill (c, _, _) -> Held_spills.callee c | Held_spills.Fine -> None)
                    spills));
          around ctx ty a cell spills
      | None, [ slot ] when reaches (Lazy.force dominates) slot a ->
          if Held_spills.debug then Printf.eprintf "late %s: framed\n" (Llvm.value_name f);
          Llvm.replace_all_uses_with a slot;
          Llvm.delete_instruction a
      | None, slots -> (
          (* No one slot reaches every use: every call is given the slot
             of the pass it is in, around the call. *)
          match Held_spills.uses ~after:true ~every:true dl a 0L [] with
          | Some spills ->
              if Held_spills.debug then Printf.eprintf "late %s: calls given their slots\n" (Llvm.value_name f);
              around ctx ty a cell spills
          | None ->
              Diagnostic.bug (Printf.sprintf "held allocas: `%s` uses an alloca before its frame slot" (Llvm.value_name f))))
    (List.rev !named)

let run m =
  let ctx = Llvm.module_context m in
  let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then settle ctx dl f) m;
  match Llvm.lookup_function Held_spills.anchor_name m with
  | Some f when Llvm.use_begin f = None -> Llvm.delete_function f
  | _ -> ()

let again = Frame_shadow.again
