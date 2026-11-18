(* Frame slots kept in registers.

   A held local lives in its scope's frame, which the runtime places, so
   LLVM keeps every slot in memory: a list's count and block are loaded
   and stored each time round a loop wherever the loop holds a call that
   may grow the list, even on a path the loop seldom takes.

   After the O2 passes, each slot of a frame (a base an `llvm.assume`
   names, as every placed frame has, or a phi of such bases) past the
   frame's record ([Abi.mark_size]) that is loaded and stored whole, as
   one scalar type, gets a copy in an alloca: the copy is filled from the
   slot where the frame is placed, every load reads it and every store
   writes it, and after a call given an address in the frame it is filled
   again, only where that call may have written it. SROA then makes it a
   register. The slot is written back from the copy before each read of
   it there: a call given an address in the frame, every call once the
   runtime keeps one, and a wider load. Where another thread or a stored
   pointer may reach the frame, every store writes the slot too. A frame
   whose address escapes any other way (an offset that is not a constant,
   a merge with another pointer) is left alone. *)

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
              walk (Llvm_extra.struct_element_types t).(k) (i + 1)
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
   [seen] holds the phis and selects already reached, with what this
   returns for them: their offset, [Some None] while one is being worked
   out, which a loop back to it agrees with, or [None] where one has none.
   A failure is kept as well as an offset, or a web of phis that reach
   each other by many paths would be walked again along each. A phi that
   fails while one it reaches is still being worked out fails whatever
   that one's offset turns out to be, since the loop back agreed with
   every offset. *)
let rec offset_from dl seen base p =
  if p == base then Some (Some 0L)
  else if Llvm.classify_type (Llvm.type_of p) <> Llvm.TypeKind.Pointer then None
  else
    match Hashtbl.find_opt seen p with
    | Some r -> r
    | None -> (
        match Llvm.classify_value p with
        | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
            match (gep_offset dl p, offset_from dl seen base (Llvm.operand p 0)) with
            | Some d, Some (Some o) -> Some (Some (Int64.add d o))
            (* Only a step of zero agrees with the offset a loop back to
               an unresolved merge is given. *)
            | Some 0L, Some None -> Some None
            | _ -> None)
        | Llvm.ValueKind.Instruction (Llvm.Opcode.PHI | Llvm.Opcode.Select as op) -> (
            Hashtbl.replace seen p (Some None);
            let inputs =
              if op = Llvm.Opcode.PHI then List.map fst (Llvm.incoming p)
              else [ Llvm.operand p 1; Llvm.operand p 2 ]
            in
            (* The inputs' offsets, stopping at the first input with none or
               with another offset than one before it. *)
            let rec agree at = function
              | [] -> Some at
              | v :: rest -> (
                  match (offset_from dl seen base v, at) with
                  | None, _ -> None
                  | Some None, _ -> agree at rest
                  | Some (Some o), None -> agree (Some o) rest
                  | Some (Some o), Some o' -> if o = o' then agree at rest else None)
            in
            let r = match agree None inputs with Some (Some o) -> Some (Some o) | _ -> None in
            Hashtbl.replace seen p r;
            r)
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
  let indexes = Hashtbl.create n in
  Array.iteri (fun i b -> Hashtbl.replace indexes b i) rpo;
  let index b = Option.value ~default:(-1) (Hashtbl.find_opt indexes b) in
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

(* Adds to [calls] every call of [f] that [base] comes before and that is
   not [inert]: the calls after which a frame whose slot's address escaped
   is filled again. *)
let calls_after f dom base calls =
  let bb = Llvm.instr_parent base in
  let add b i =
    if Llvm.instr_opcode i = Llvm.Opcode.Call && not (List.memq i !calls) then
      match callee i with
      | Some n when inert n -> ()
      | _ -> if (b == bb && before base i) || (b != bb && dom bb b) then calls := i :: !calls
  in
  Llvm.iter_blocks (fun b -> Llvm.iter_instrs (add b) b) f

(* Whether call [i] keeps none of the addresses [p] it is given: each
   operand that is [p] is a parameter of a known callee marked
   `captures(none)`, or the call is to an intrinsic. *)
let keeps_none i p =
  let n = Llvm.num_operands i in
  let f = Llvm.operand i (n - 1) in
  if Llvm.classify_value f <> Llvm.ValueKind.Function then false
  else if starts "llvm." (Llvm.value_name f) then true
  else
    let captures = Llvm.enum_attr_kind "captures" in
    let none_at k =
      Array.exists
        (fun a ->
          (* A type attribute, as `sret(T)`, has no representation. *)
          match Llvm.repr_of_attr a with
          | Llvm.AttrRepr.Enum (kind, v) -> kind = captures && v = 0L
          | _ -> false
          | exception Assert_failure _ -> false)
        (Llvm_extra.function_attrs f (Llvm.AttrIndex.Param k))
    in
    let rec go k = k >= n - 1 || ((Llvm.operand i k != p || none_at k) && go (k + 1)) in
    go 0

let func ctx dl (f : Llvm.llvalue) =
  (* The frames: what an `llvm.assume` names. [framed] holds the same, to
     look one up. *)
  let frames = ref [] and framed = Hashtbl.create 16 in
  let is_frame v = Hashtbl.mem framed v in
  let add v =
    frames := v :: !frames;
    Hashtbl.replace framed v ()
  in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          if Llvm.instr_opcode i = Llvm.Opcode.Call && callee i = Some "llvm.assume" then
            for k = 1 to Llvm.num_operands i - 2 do
              let v = Llvm.operand i k in
              match Llvm.classify_value v with
              | Llvm.ValueKind.Instruction _ when not (is_frame v) -> add v
              | _ -> ()
            done)
        b)
    f;
  (* A merge of frames is a frame: where LLVM threads a scope's entry into
     its fast and slow paths, each path places the frame and names it, and
     a phi at the join is the frame the scope's code uses. *)
  let merges = ref [] in
  let changed = ref true in
  while !changed do
    changed := false;
    Llvm.iter_blocks
      (fun b ->
        Llvm.iter_instrs
          (fun i ->
            if
              Llvm.instr_opcode i = Llvm.Opcode.PHI
              && (not (is_frame i))
              && List.for_all (fun (v, _) -> is_frame v) (Llvm.incoming i)
            then begin
              add i;
              merges := i :: !merges;
              changed := true
            end)
          b)
      f
  done;
  (* The runtime's view of the innermost scope, [Walks.zane_open], read
     again on a path that placed a frame and merged with it: the code
     through it reads and writes the scope's record and allocates past the
     frame, as every other read of [zane_open] in the function does. *)
  let open_scope v =
    Llvm.classify_value v = Llvm.ValueKind.Instruction Llvm.Opcode.Load
    &&
    let p = Llvm.operand v 0 in
    Llvm.classify_value p = Llvm.ValueKind.GlobalVariable && Llvm.value_name p = "zane_open"
  in
  (* A phi beside a merge whose every input is at one offset from the
     frame the merge takes from the same block, as a slot's address LLVM
     carries through the join apart from the frame, is the merge's frame at
     that offset: [parallel] holds it with its merge and offset. An input
     is at an offset from a frame through constant GEPs, from the frame or
     from a phi already found beside it: a slot's address, not one LLVM
     loops through, which [offset_from] would walk back for every phi in
     the block. *)
  let parallel = ref [] in
  let seeds b =
    let t = Hashtbl.create 16 in
    List.iter (fun (q, (m, o)) -> if m == b then Hashtbl.replace t q (Some (Some o))) !parallel;
    t
  in
  let rec chain b v =
    if v == b then Some 0L
    else
      match List.assq_opt v !parallel with
      | Some (m, o) when m == b -> Some o
      | _ -> (
          match Llvm.classify_value v with
          | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
              match (gep_offset dl v, chain b (Llvm.operand v 0)) with
              | Some d, Some o -> Some (Int64.add d o)
              | _ -> None)
          | _ -> None)
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun m ->
        let into = Llvm.incoming m in
        Llvm.iter_instrs
          (fun q ->
            if
              Llvm.instr_opcode q = Llvm.Opcode.PHI
              && (not (is_frame q))
              && not (List.mem_assq q !parallel)
            then
              let offsets =
                List.map
                  (fun (v, pred) ->
                    match List.find_opt (fun (_, p) -> p == pred) into with
                    | None -> None
                    | Some (b, _) -> (                        chain b v))
                  (Llvm.incoming q)
              in
              match List.sort_uniq compare offsets with
              | [ Some o ] ->
                  parallel := (q, (m, o)) :: !parallel;
                  changed := true
              | _ -> ())
          (Llvm.instr_parent m))
      !merges
  done;
  let followed i =
    (not (List.memq i !merges))
    && (not (List.mem_assq i !parallel))
    && not (List.exists (fun (v, _) -> open_scope v) (Llvm.incoming i))
  in
  (* A merge is shadowed only where each frame it joins was visited whole:
     a use of one that is neither the merge nor beside it would reach the
     merge's slots unseen. *)
  let clean = ref [] in
  (* The frames a merge joins: each path's frame is written through, so
     that the merge, filled where it is placed, reads what the path
     stored. *)
  let joined = ref [] in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          if Llvm.instr_opcode i = Llvm.Opcode.PHI && not (followed i) then
            List.iter (fun (v, _) -> joined := v :: !joined) (Llvm.incoming i))
        b)
    f;
  let dom = lazy (dominators f) in
  let order = List.filter (fun b -> not (List.memq b !merges)) !frames @ List.rev !merges in
  List.iter
    (fun base ->
      if (not (List.memq base !merges)) || List.for_all (fun (v, _) -> List.memq v !clean) (Llvm.incoming base) then begin
        (* Every use of an address in the frame: loads and stores at their
           offsets, and calls given one. [stored] is whether an address in
           it is stored as a value, past its record, and [kept] the callees
           that may keep one. *)
        let loads = ref [] and stores = ref [] and calls = ref [] and escaped = ref false in
        let stored = ref false and kept = ref [] in
        let seen = seeds base and visited = ref [] in
        let at i = match offset_from dl seen base i with Some (Some o) -> o | _ -> raise (Escapes_at i) in
        let mark = Int64.of_int Abi.mark_size in
        (* Whether [i] is only ever stored, as a value. *)
        let link i =
          let only = ref true in
          Llvm.iter_uses
            (fun u ->
              let s = Llvm.user u in
              if
                not
                  (Llvm.classify_value s = Llvm.ValueKind.Instruction Llvm.Opcode.Store
                  && Llvm.operand s 0 == i
                  && Llvm.operand s 1 != i)
              then only := false)
            i;
          !only
        in
        (* Whether [i] is only compared, directly or as a difference, as
           entering a scope inline checks the room left past its frame. *)
        let rec compared i =
          let only = ref true in
          Llvm.iter_uses
            (fun u ->
              let s = Llvm.user u in
              match Llvm.classify_value s with
              | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp -> ()
              | Llvm.ValueKind.Instruction Llvm.Opcode.Sub when compared s -> ()
              | _ -> only := false)
            i;
          !only
        in
        let rec visit p off =
          Llvm.iter_uses
            (fun u ->
              let i = Llvm.user u in
              match Llvm.classify_value i with
              | Llvm.ValueKind.Instruction op -> (
                  match op with
                  | Llvm.Opcode.GetElementPtr when Llvm.operand i 0 == p -> visit i (at i)
                  (* A merge of frames is visited as its own frame. *)
                  | Llvm.Opcode.PHI when not (followed i) -> ()
                  (* The scope chain's link, chosen between the frame and
                     a scope it encloses, as entering a scope inline picks
                     the record's skip ([ZANE_MARK_SKIP]): stored only as a
                     value, as the frame itself is below. *)
                  | (Llvm.Opcode.PHI | Llvm.Opcode.Select) when off < mark && link i -> ()
                  | Llvm.Opcode.PHI | Llvm.Opcode.Select when Llvm.operand i 0 != p || op = Llvm.Opcode.PHI ->
                      if not (List.memq i !visited) then begin
                        visited := i :: !visited;
                        visit i (at i)
                      end
                  (* An ordered or volatile read must stay a read of the frame. *)
                  | Llvm.Opcode.Load when Llvm.is_volatile i || Llvm_extra.is_atomic i -> raise (Escapes_at i)
                  | Llvm.Opcode.Load -> loads := (i, off) :: !loads
                  | Llvm.Opcode.Store when Llvm.operand i 1 == p && Llvm.operand i 0 != p -> stores := (i, off) :: !stores
                  (* The frame's record names it in the scope chain. *)
                  | Llvm.Opcode.Store when Llvm.operand i 0 == p && off < mark -> ()
                  (* A slot's address the runtime keeps, as a deferred job
                     does: any call may then write the slot. *)
                  | Llvm.Opcode.Store when Llvm.operand i 0 == p && Llvm.operand i 1 != p ->
                      escaped := true;
                      stored := true
                  | Llvm.Opcode.Call -> (
                      (* A callee that may keep the address, as `overwrite`
                         does in a deferred job a later call runs, may have
                         any later call write the slot: the frame escaped. *)
                      if not (keeps_none i p) then begin
                        escaped := true;
                        kept := callee i :: !kept
                      end;
                      match callee i with
                      | Some n when inert n -> ()
                      | _ when List.memq i !calls -> ()
                      | _ -> calls := i :: !calls)
                  | Llvm.Opcode.ICmp -> ()
                  | Llvm.Opcode.PtrToInt when compared i -> ()
                  | _ -> raise (Escapes_at i))
              | _ -> raise (Escapes_at i))
            p
        in
        let whole () =
          visit base 0L;
          List.iter (fun (q, (m, o)) -> if m == base then visit q o) !parallel
        in
        match whole () with
        | exception Escapes_at _ -> ()
        | () ->
            clean := base :: !clean;
            let size t = Llvm_target.DataLayout.store_size t dl in
            let accesses =
              List.map (fun (i, o) -> (o, Llvm.type_of i)) !loads
              @ List.map (fun (i, o) -> (o, Llvm.type_of (Llvm.operand i 0))) !stores
            in
            (* Whether an access at [o'] of [t'] holds all of the slot at [o]
               of [t], and more. *)
            let covers (o', t') (o, t) =
              o' <= o && Int64.add o' (size t') >= Int64.add o (size t) && size t' > size t
            in
            (* A slot: an offset loaded at least once, where every access that
               overlaps it is of the same offset and type, or is wider and
               holds the whole slot: a load of more than the slot reads the
               frame, which every store still writes, and a store of more (a
               list's count and room stored as one pair, as copying the list
               into a struct does) fills the copy again. *)
            let slots =
              List.sort_uniq compare (List.map snd (List.filter (fun (_, o) -> o >= mark) !loads))
              |> List.filter_map (fun o ->
                     let t = Llvm.type_of (fst (List.find (fun (_, o2) -> o2 = o) !loads)) in
                     let hi = Int64.add o (size t) in
                     let overlapping =
                       List.filter (fun (o', t') -> o' < hi && Int64.add o' (size t') > o) accesses
                     in
                     let ok =
                       scalar t
                       && List.for_all (fun (o', t') -> (o' = o && t' == t) || covers (o', t') (o, t)) overlapping
                     in
                     if ok then Some (o, t) else None)
            in
            if slots <> [] then begin
              (* A frame a slot's address escaped from is filled again after
                 every call it is placed before. *)
              let addressed = !calls in
              if !escaped then calls_after f (Lazy.force dom) base calls;
              (* Whether the frame may still be used after call [c], or by it:
                 a load or store past its record, or a call given an address
                 in it, is reachable from [c] without placing the frame again.
                 Past its last use the frame may be drained, and its memory
                 another frame's. *)
              let uses =
                List.filter_map (fun (i, o) -> if o >= mark then Some i else None) (!loads @ !stores) @ addressed
              in
              let home = Llvm.instr_parent base in
              let used_in = Hashtbl.create 16 in
              List.iter (fun i -> Hashtbl.replace used_in (Llvm.instr_parent i) ()) uses;
              let live_in = Hashtbl.create 16 in
              let live b = Hashtbl.mem live_in b in
              let successors b = match Llvm.block_terminator b with Some t -> Array.to_list (Llvm.successors t) | None -> [] in
              let grew = ref true in
              while !grew do
                grew := false;
                Llvm.iter_blocks
                  (fun b ->
                    if b != home && (not (live b)) && (Hashtbl.mem used_in b || List.exists live (successors b)) then begin
                      Hashtbl.replace live_in b ();
                      grew := true
                    end)
                  f
              done;
              let used_after c =
                List.memq c addressed
                ||
                let rec go = function
                  | Llvm.Before i -> List.memq i uses || go (Llvm.instr_succ i)
                  | Llvm.At_end b -> List.exists live (successors b)
                in
                go (Llvm.instr_succ c)
              in
              let calls = List.filter used_after !calls in
              (* Whether the copies' stores may wait for the next read of the
                 frame: no address in it is stored, the only callees that
                 keep one are the runtime's, which read it only inside a
                 later call (a drain reads what `zane_hold` lists, growth the
                 header it was given), and no merge reads the frame after
                 it. Then no other thread holds an address in it, so a slot
                 is read only by this function, through the frame, and by
                 the calls given an address in it or after one was kept; it
                 is written back before each. A frame placed on a path a
                 merge joins is written through. *)
              let runtime_keeps = "zane_hold" :: "zane_scope_drain" :: Frame_scopes.list_calls in
              let deferred =
                (not !stored)
                && (not (List.memq base !joined))
                && List.for_all (function Some n -> List.mem n runtime_keeps | None -> false) !kept
              in
              let entry = Llvm.entry_block f in
              let at_entry = Llvm.builder_at ctx (Llvm.instr_begin entry) in
              let i8 = Llvm.i8_type ctx and i64 = Llvm.i64_type ctx in
              let copies = List.map (fun (o, t) -> (o, t, Llvm.build_alloca t "shadow" at_entry)) slots in
              let slot b o = Llvm.build_in_bounds_gep i8 base [| Llvm.const_of_int64 i64 o true |] "" b in
              (* Filling a copy from its slot, and writing it back. *)
              let fill b = List.iter (fun (o, t, a) -> ignore (Llvm.build_store (Llvm.build_load t (slot b o) "" b) a b)) in
              let back b = List.iter (fun (o, t, a) -> ignore (Llvm.build_store (Llvm.build_load t a "" b) (slot b o) b)) in
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
              (* The copy an access of exactly [t] at [o] reads or writes, and
                 the copies a wider access at [o] of [t] holds. *)
              let copy o t = List.find_opt (fun (o', t', _) -> o' = o && t' == t) copies in
              let held o t = List.filter (fun (o', t', _) -> covers (o, t) (o', t')) copies in
              let header = Llvm_target.DataLayout.abi_size (List_handle.header ctx) dl in
              let within lo len = List.filter (fun (o, t, _) -> o < Int64.add lo len && Int64.add o (size t) > lo) copies in
              let in_frame p = match offset_from dl (Hashtbl.create 16) base p with Some (Some o) -> Some o | _ -> None in
              let elsewhere () = if !escaped then copies else [] in
              let mem n = starts "llvm.memset" n || starts "llvm.memcpy" n || starts "llvm.memmove" n in
              (* The copies a call may have written, so filled again after
                 it: after a `memset`, `memcpy` or `memmove` of a constant
                 length, those its destination covers, and none when the
                 destination is outside a frame whose address went nowhere
                 else; after the runtime's list growth
                 ([Frame_scopes.list_calls]), which writes the list's header at
                 its first argument and nothing else the frame holds, those of
                 the header (whether or not a slot's address went elsewhere:
                 growth writes through no address it was given before); after
                 any other call, all. An arithmetic coder's bit writer clears
                 its byte and count with one `memset` per byte, and the push
                 that follows would otherwise load every slot again, the
                 coder's tables among them (tests/perf `refills`). *)
              let refilled c =
                match callee c with
                | Some n when mem n -> (
                    match (in_frame (Llvm.operand c 0), Llvm.int64_of_const (Llvm.operand c 2)) with
                    | Some o, Some len -> within o len
                    | None, _ -> elsewhere ()
                    | Some _, None -> copies)
                | Some n when List.mem n Frame_scopes.list_calls -> (
                    match in_frame (Llvm.operand c 0) with Some o -> within o header | None -> elsewhere ())
                | _ -> copies
              in
              (* The copies a call may read, so written back before it, with
                 those it may write, which are filled again from the frame:
                 none for a `memset`, the source for a `memcpy` or `memmove`,
                 the header for growth, and all for any other call. *)
              let read c =
                match callee c with
                | Some n when starts "llvm.memset" n -> []
                | Some n when mem n -> (
                    match (in_frame (Llvm.operand c 1), Llvm.int64_of_const (Llvm.operand c 2)) with
                    | Some o, Some len -> within o len
                    | None, _ -> elsewhere ()
                    | Some _, None -> copies)
                | Some n when List.mem n Frame_scopes.list_calls -> (
                    match in_frame (Llvm.operand c 0) with Some o -> within o header | None -> elsewhere ())
                | _ -> copies
              in
              (* The copies that may hold what their slots do not, at each
                 call and wider load: stored since the frame was last filled
                 into them or they were written back to it, on some path
                 from where the frame is placed. Only those are written
                 back, so a call a loop makes each pass writes back what the
                 pass stored, not every copy. *)
              let dirty_at = Hashtbl.create 16 and ending_at = Hashtbl.create 16 in
              if deferred then begin
                let minus d xs = List.filter (fun x -> not (List.memq x xs)) d in
                let union a b = a @ minus b a in
                let store_of = Hashtbl.create 16 and load_of = Hashtbl.create 16 and call_of = Hashtbl.create 16 in
                List.iter
                  (fun (i, o) ->
                    let t = Llvm.type_of (Llvm.operand i 0) in
                    Hashtbl.replace store_of i (match copy o t with Some x -> `Dirty x | None -> `Agree (held o t)))
                  !stores;
                List.iter
                  (fun (i, o) ->
                    match copy o (Llvm.type_of i) with
                    | None -> Hashtbl.replace load_of i (`Wider (held o (Llvm.type_of i)))
                    | Some _ -> Hashtbl.replace load_of i `Exact)
                  !loads;
                List.iter (fun c -> Hashtbl.replace call_of c (union (refilled c) (read c))) calls;
                let step record d i =
                  if i == base then []
                  else
                    match Hashtbl.find_opt store_of i with
                    | Some (`Dirty x) -> if List.memq x d then d else x :: d
                    | Some (`Agree h) -> minus d h
                    | None -> (
                        match Hashtbl.find_opt load_of i with
                        | Some (`Wider h) ->
                            if record then Hashtbl.replace dirty_at i d;
                            minus d h
                        | Some `Exact ->
                            if record then Hashtbl.replace dirty_at i d;
                            d
                        | None -> (
                            match Hashtbl.find_opt call_of i with
                            | Some w ->
                                if record then Hashtbl.replace dirty_at i d;
                                minus d w
                            | None -> d))
                in
                let preds = Hashtbl.create 16 in
                Llvm.iter_blocks
                  (fun b -> List.iter (fun s -> Hashtbl.add preds s b) (successors b))
                  f;
                (* What is written back at the end of a block, on its way
                   into a loop (below). *)
                let ending = Hashtbl.create 16 in
                let ends b = Option.value ~default:[] (Hashtbl.find_opt ending b) in
                let solve () =
                  let out = Hashtbl.create 16 in
                  let into b = List.fold_left (fun d p -> union d (Option.value ~default:[] (Hashtbl.find_opt out p))) [] (Hashtbl.find_all preds b) in
                  let through record b = minus (Llvm.fold_left_instrs (step record) (into b) b) (ends b) in
                  let grew = ref true in
                  while !grew do
                    grew := false;
                    Llvm.iter_blocks
                      (fun b ->
                        let d = through false b in
                        let old = Option.value ~default:[] (Hashtbl.find_opt out b) in
                        if List.exists (fun x -> not (List.memq x old)) d then begin
                          Hashtbl.replace out b (union old d);
                          grew := true
                        end)
                      f
                  done;
                  (out, through)
                in
                (* A copy dirty on the way into a loop and clean on its way
                   round is written back once, on the way in, rather than
                   at each pass's call: as a list pushed to before a loop
                   whose every pass calls a function given the frame. Only
                   into a block the frame is live in, so its memory is
                   still its own, and from one the frame's placement
                   dominates. *)
                let rec settle () =
                  let out, _ = solve () in
                  let at b = Option.value ~default:[] (Hashtbl.find_opt out b) in
                  let added = ref false in
                  Llvm.iter_blocks
                    (fun b ->
                      if live b then begin
                        let ps = Hashtbl.find_all preds b in
                        let round, entering = List.partition (fun p -> Lazy.force dom b p) ps in
                        if round <> [] then
                          let clean_round x = List.for_all (fun p -> not (List.memq x (at p))) round in
                          List.iter
                            (fun p ->
                              let w = List.filter clean_round (at p) in
                              if w <> [] && Lazy.force dom home p then begin
                                Hashtbl.replace ending p (union (ends p) w);
                                added := true
                              end)
                            entering
                      end)
                    f;
                  if !added then settle ()
                in
                settle ();
                Hashtbl.iter (fun b w -> Hashtbl.replace ending_at b w) ending;
                let _, through = solve () in
                Llvm.iter_blocks (fun b -> ignore (through true b)) f
              end;
              let dirty i = match Hashtbl.find_opt dirty_at i with Some d -> d | None -> [] in
              (* The copies filled again only where they are next loaded,
                 rather than right after each call that may write their
                 slots: [lazy_] holds them, and [filled_at] the loads that
                 fill one first. A copy is stale from such a call to its next
                 load or store, which must find it stale on every path, or
                 fresh on every path, and nothing may write it back while it
                 may be stale; a copy for which that fails is filled after
                 each call. A loop that calls a function given the frame on
                 every pass then loads only the slots that pass reads, where
                 it reads them, as it would with no copies; one that calls
                 now and then keeps its copies filled. *)
              let lazy_ = ref copies and filled_at = Hashtbl.create 16 and ends_filled = Hashtbl.create 16 in
              (let minus d xs = List.filter (fun x -> not (List.memq x xs)) d in
               let inter a b = List.filter (fun x -> List.memq x b) a in
               let backs = Hashtbl.create 16 in
               if deferred then begin
                 List.iter
                   (fun (i, o) ->
                     if copy o (Llvm.type_of i) = None then
                       Hashtbl.replace backs i (inter (dirty i) (held o (Llvm.type_of i))))
                   !loads;
                 List.iter (fun c -> Hashtbl.replace backs c (inter (dirty c) (refilled c @ read c))) calls
               end;
               let stores_at = Hashtbl.create 16 and loads_at = Hashtbl.create 16 and calls_at = Hashtbl.create 16 in
               List.iter
                 (fun (i, o) ->
                   let t = Llvm.type_of (Llvm.operand i 0) in
                   Hashtbl.replace stores_at i (match copy o t with Some x -> [ x ] | None -> held o t))
                 !stores;
               List.iter
                 (fun (i, o) -> match copy o (Llvm.type_of i) with Some x -> Hashtbl.replace loads_at i x | None -> ())
                 !loads;
               List.iter (fun c -> Hashtbl.replace calls_at c (refilled c)) calls;
               let preds = Hashtbl.create 16 in
               Llvm.iter_blocks (fun b -> List.iter (fun s -> Hashtbl.add preds s b) (successors b)) f;
               (* One instruction's effect on the copies that may be, and
                  must be, stale, noting in [bad] those found stale where
                  they must not be. *)
               (* The loads that may find a copy stale and may find it
                  fresh, with their blocks, gathered while [collecting]; and
                  the copies filled at the end of a block, on the paths
                  where they are stale into a block where one is loaded. *)
               let collecting = ref false and mixed = ref [] and fills_at_end = Hashtbl.create 16 in
               let step bad (may, must) i =
                 let check xs = List.iter (fun x -> if List.memq x may then bad := x :: !bad) xs in
                 (match Hashtbl.find_opt backs i with Some xs -> check xs | None -> ());
                 if i == base then ([], [])
                 else
                   match Hashtbl.find_opt stores_at i with
                   | Some xs -> (minus may xs, minus must xs)
                   | None -> (
                       match Hashtbl.find_opt loads_at i with
                       | Some x ->
                           if List.memq x may && not (List.memq x must) then
                             if List.memq x (dirty i) then bad := x :: !bad
                             else if !collecting then mixed := (x, Llvm.instr_parent i) :: !mixed;
                           (minus may [ x ], minus must [ x ])
                       | None -> (
                           match Hashtbl.find_opt calls_at i with
                           | Some w ->
                               let w = inter w !lazy_ in
                               (may @ minus w may, must @ minus w must)
                           | None -> (may, must)))
               in
               let through bad s b =
                 let s = Llvm.fold_left_instrs (step bad) s b in
                 (match Hashtbl.find_opt ending_at b with
                 | Some w -> List.iter (fun x -> if List.memq x (fst s) then bad := x :: !bad) w
                 | None -> ());
                 let w = Option.value ~default:[] (Hashtbl.find_opt fills_at_end b) in
                 (minus (fst s) w, minus (snd s) w)
               in
               let rec settle () =
                 let out = Hashtbl.create 16 in
                 let into b =
                   match Hashtbl.find_all preds b with
                   | [] -> ([], [])
                   | ps ->
                       let seen = List.filter_map (Hashtbl.find_opt out) ps in
                       let may = List.fold_left (fun d (m, _) -> d @ minus m d) [] seen in
                       let must =
                         match seen with [] -> [] | (_, m) :: rest -> List.fold_left (fun d (_, m) -> inter d m) m rest
                       in
                       (may, must)
                 in
                 let same a b = List.length a = List.length b && List.for_all (fun x -> List.memq x b) a in
                 let grew = ref true and rounds = ref 0 in
                 while !grew && !rounds < 64 do
                   grew := false;
                   incr rounds;
                   Llvm.iter_blocks
                     (fun b ->
                       let s = through (ref []) (into b) b in
                       match Hashtbl.find_opt out b with
                       | Some (m, n) when same m (fst s) && same n (snd s) -> ()
                       | _ ->
                           Hashtbl.replace out b s;
                           grew := true)
                     f
                 done;
                 (* Past the bound, every copy is filled after each call. *)
                 let bad = ref (if !grew then !lazy_ else []) in
                 collecting := true;
                 mixed := [];
                 Llvm.iter_blocks (fun b -> ignore (through bad (into b) b)) f;
                 collecting := false;
                 (* A load that finds a copy stale on some paths only is
                    found no state of it in its block before it: the copy is
                    filled at the end of each block it is surely stale out
                    of, on the way there, and the blocks it may be stale out
                    of are followed back the same way. *)
                 let added = ref false in
                 List.iter
                   (fun (x, b) ->
                     let met = ref [] in
                     let rec need b =
                       List.iter
                         (fun p ->
                           match Hashtbl.find_opt out p with
                           | Some (m, n) when List.memq x m ->
                               if List.memq x n then begin
                                 let w = Option.value ~default:[] (Hashtbl.find_opt fills_at_end p) in
                                 if List.memq x w then bad := x :: !bad
                                 else if Lazy.force dom home p then begin
                                   Hashtbl.replace fills_at_end p (x :: w);
                                   added := true
                                 end
                                 else bad := x :: !bad
                               end
                               else if not (List.memq p !met) then begin
                                 met := p :: !met;
                                 need p
                               end
                           | _ -> ())
                         (Hashtbl.find_all preds b)
                     in
                     if List.memq x !lazy_ then need b)
                   !mixed;
                 let bad = inter !lazy_ !bad in
                 if bad <> [] then begin
                   lazy_ := minus !lazy_ bad;
                   Hashtbl.reset fills_at_end;
                   settle ()
                 end
                 else if !added then settle ()
                 else
                   Llvm.iter_blocks
                     (fun b ->
                       ignore
                         (Llvm.fold_left_instrs
                            (fun s i ->
                              (match Hashtbl.find_opt loads_at i with
                              | Some x when List.memq x (fst s) -> Hashtbl.replace filled_at i ()
                              | _ -> ());
                              step (ref []) s i)
                            (into b) b))
                     f;
                 Hashtbl.iter (fun b w -> Hashtbl.replace ends_filled b w) fills_at_end
               in
               settle ());
              fill (Llvm.builder_at ctx placed) copies;
              Hashtbl.iter
                (fun b w ->
                  match Llvm.block_terminator b with
                  | Some t -> fill (Llvm.builder_before ctx t) (List.filter (fun x -> List.memq x !lazy_) w)
                  | None -> ())
                ends_filled;
              Hashtbl.iter
                (fun b w ->
                  match Llvm.block_terminator b with
                  | Some t -> back (Llvm.builder_before ctx t) w
                  | None -> ())
                ending_at;
              List.iter
                (fun (i, o) ->
                  match copy o (Llvm.type_of i) with
                  | Some ((_, t, a) as x) ->
                      let b = Llvm.builder_before ctx i in
                      if Hashtbl.mem filled_at i then fill b [ x ];
                      let v = Llvm.build_load t a "" b in
                      Llvm.replace_all_uses_with i v;
                      Llvm.delete_instruction i
                  | None ->
                      (* A wider load reads the frame, so what it holds is
                         written back first. *)
                      if deferred then
                        back (Llvm.builder_before ctx i) (List.filter (fun x -> List.memq x (dirty i)) (held o (Llvm.type_of i))))
                !loads;
              List.iter
                (fun (i, o) ->
                  let t = Llvm.type_of (Llvm.operand i 0) in
                  match copy o t with
                  | Some (_, _, a) ->
                      let b = Llvm.builder_at ctx (Llvm.instr_succ i) in
                      ignore (Llvm.build_store (Llvm.operand i 0) a b);
                      if deferred then Llvm.delete_instruction i
                  | None ->
                      (* A wider store fills again the copies it holds, from
                         the frame it has just written, which GVN then reads
                         from the stored value. *)
                      let h = held o t in
                      if h <> [] then fill (Llvm.builder_at ctx (Llvm.instr_succ i)) h)
                !stores;
              List.iter
                (fun c ->
                  if deferred then begin
                    let w = refilled c and d = dirty c in
                    back
                      (Llvm.builder_before ctx c)
                      (List.filter (fun x -> List.memq x d && (List.memq x w || List.memq x (read c))) copies)
                  end;
                  match Llvm.instr_succ c with
                  | Llvm.Before _ as pos ->
                      fill (Llvm.builder_at ctx pos) (List.filter (fun x -> not (List.memq x !lazy_)) (refilled c))
                  | Llvm.At_end _ -> ())
                calls
            end
      end)
    order

let run m =
  let ctx = Llvm.module_context m in
  let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx dl f) m

(* The passes run again once the copies are in. *)
let again =
  "function(sroa,early-cse<memssa>,loop-mssa(licm<allowspeculation>),gvn<pre;load-pre>,instcombine<no-verify-fixpoint>,simplifycfg,dse,loop-mssa(licm<allowspeculation>))"
