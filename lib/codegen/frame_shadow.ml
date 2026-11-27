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
   again, only where that call may have written it, and where its next
   loads find it stale. SROA then makes it a register. The slot is
   written back from the copy before each read of it there, when the copy
   was stored since the two last agreed: a call given an address in the
   frame, every call once the runtime keeps one, and a wider load. Where
   another thread or a stored pointer may reach the frame, every store
   writes the slot too. The record's skip and an inline scope entry's
   room check name the frame without reaching its slots. A frame whose
   address escapes by any other route (an offset that is not a constant, a
   merge with another pointer) is left alone. *)

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
   out, which a loop back to it matches, or [None] where one has none.
   A failure is kept as well as an offset, or a web of phis that reach
   each other by many paths would be walked again along each. A phi that
   fails while one it reaches is still being worked out fails whatever
   that phi's offset turns out to be, since the loop back matched
   every offset. *)
let rec offset_from dl seen base p =
  if p == base then Some (Some 0L)
  else if Llvm.classify_type (Llvm.type_of p) <> Llvm.TypeKind.Pointer then None
  else match Hashtbl.find_opt seen p with Some r -> r | None -> reach dl seen base p

and reach dl seen base p =
  match Llvm.classify_value p with
  | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
      match (gep_offset dl p, offset_from dl seen base (Llvm.operand p 0)) with
      | Some d, Some (Some o) -> Some (Some (Int64.add d o))
      (* Only a step of zero matches the offset a loop back to an
         unresolved merge is given. *)
      | Some 0L, Some None -> Some None
      | _ -> None)
  | Llvm.ValueKind.Instruction (Llvm.Opcode.PHI | Llvm.Opcode.Select as op) ->
      Hashtbl.replace seen p (Some None);
      let inputs =
        if op = Llvm.Opcode.PHI then List.map fst (Llvm.incoming p) else [ Llvm.operand p 1; Llvm.operand p 2 ]
      in
      let r = match agree dl seen base None inputs with Some (Some o) -> Some (Some o) | _ -> None in
      Hashtbl.replace seen p r;
      r
  | _ -> None

(* The inputs' offsets, stopping at the first input with none or with
   another offset than one before it. *)
and agree dl seen base at = function
  | [] -> Some at
  | v :: rest -> (
      match (offset_from dl seen base v, at) with
      | None, _ -> None
      | Some None, _ -> agree dl seen base at rest
      | Some (Some o), None -> agree dl seen base (Some o) rest
      | Some (Some o), Some o' -> if o = o' then agree dl seen base at rest else None)



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


(* Sets of copies, compared by identity. *)
let minus d xs = List.filter (fun x -> not (List.memq x xs)) d
let union a b = a @ minus b a
let inter a b = List.filter (fun x -> List.memq x b) a
let same a b = List.length a = List.length b && List.for_all (fun x -> List.memq x b) a
let found t k = Option.value ~default:[] (Hashtbl.find_opt t k)

let successors b = match Llvm.block_terminator b with Some t -> Array.to_list (Llvm.successors t) | None -> []

(* Each block of [f] to the blocks that branch to it. *)
let predecessors f =
  let preds = Hashtbl.create 16 in
  Llvm.iter_blocks (fun b -> List.iter (fun s -> Hashtbl.add preds s b) (successors b)) f;
  preds

let mark = Int64.of_int Abi.mark_size

(* The frames: what an `llvm.assume` names, and a merge of frames. Where
   LLVM threads a scope's entry into its fast and slow paths, each path
   places the frame and names it, and a phi at the join is the frame the
   scope's code uses. *)
type frames = { framed : (Llvm.llvalue, unit) Hashtbl.t; mutable all : Llvm.llvalue list; mutable merges : Llvm.llvalue list }

let is_frame fr v = Hashtbl.mem fr.framed v

let add_frame fr v =
  fr.all <- v :: fr.all;
  Hashtbl.replace fr.framed v ()

let named fr i =
  if Llvm.instr_opcode i = Llvm.Opcode.Call && callee i = Some "llvm.assume" then
    for k = 1 to Llvm.num_operands i - 2 do
      let v = Llvm.operand i k in
      match Llvm.classify_value v with
      | Llvm.ValueKind.Instruction _ when not (is_frame fr v) -> add_frame fr v
      | _ -> ()
    done

(* Whether [i] is a merge not yet known: a phi of frames only. *)
let merging fr i =
  Llvm.instr_opcode i = Llvm.Opcode.PHI
  && (not (is_frame fr i))
  && List.for_all (fun (v, _) -> is_frame fr v) (Llvm.incoming i)

let find_frames f =
  let fr = { framed = Hashtbl.create 16; all = []; merges = [] } in
  Llvm.iter_blocks (fun b -> Llvm.iter_instrs (named fr) b) f;
  let changed = ref true in
  let merge i =
    if merging fr i then begin
      add_frame fr i;
      fr.merges <- i :: fr.merges;
      changed := true
    end
  in
  while !changed do
    changed := false;
    Llvm.iter_blocks (fun b -> Llvm.iter_instrs merge b) f
  done;
  fr

(* The runtime's view of the innermost scope, [Walks.zane_open], read
   again on a path that placed a frame and merged with it: the code through
   it reads and writes the scope's record and allocates past the frame, as
   every other read of [zane_open] in the function does. *)
let open_scope v =
  Llvm.classify_value v = Llvm.ValueKind.Instruction Llvm.Opcode.Load
  &&
  let p = Llvm.operand v 0 in
  Llvm.classify_value p = Llvm.ValueKind.GlobalVariable && Llvm.value_name p = "zane_open"

(* A phi beside a merge whose every input is at one offset from the frame
   the merge takes from the same block, as a slot's address LLVM carries
   through the join apart from the frame, is the merge's frame at that
   offset: [parallel] holds it with its merge and offset. An input is at an
   offset from a frame through constant GEPs, from the frame or from a phi
   already found beside it: a slot's address, not one LLVM loops through,
   which [offset_from] would walk back for every phi in the block. *)
let rec chain dl parallel b v =
  if v == b then Some 0L
  else
    match List.assq_opt v parallel with
    | Some (m, o) when m == b -> Some o
    | _ -> (
        match Llvm.classify_value v with
        | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> (
            match (gep_offset dl v, chain dl parallel b (Llvm.operand v 0)) with
            | Some d, Some o -> Some (Int64.add d o)
            | _ -> None)
        | _ -> None)

(* The offset of phi [q] beside merge [m] from [m]'s frames, if one. *)
let beside dl parallel m q =
  let into = Llvm.incoming m in
  let from (v, pred) =
    match List.find_opt (fun (_, p) -> p == pred) into with None -> None | Some (b, _) -> chain dl parallel b v
  in
  match List.sort_uniq compare (List.map from (Llvm.incoming q)) with [ Some o ] -> Some o | _ -> None

let find_parallel dl fr =
  let parallel = ref [] and changed = ref true in
  let try_phi m q =
    if Llvm.instr_opcode q = Llvm.Opcode.PHI && (not (is_frame fr q)) && not (List.mem_assq q !parallel) then
      match beside dl !parallel m q with
      | Some o ->
          parallel := (q, (m, o)) :: !parallel;
          changed := true
      | None -> ()
  in
  while !changed do
    changed := false;
    List.iter (fun m -> Llvm.iter_instrs (try_phi m) (Llvm.instr_parent m)) fr.merges
  done;
  !parallel

let seeds parallel b =
  let t = Hashtbl.create 16 in
  List.iter (fun (q, (m, o)) -> if m == b then Hashtbl.replace t q (Some (Some o))) parallel;
  t

(* Every use of an address in a frame: loads and stores at their offsets,
   and calls given one. [escaped] is whether a slot's address may reach a
   call it is not given, [stored] whether an address in the frame is
   stored as a value, past its record, and [kept] the callees that may keep
   one. *)
type uses = {
  mutable loads : (Llvm.llvalue * int64) list;
  mutable stores : (Llvm.llvalue * int64) list;
  mutable calls : Llvm.llvalue list;
  mutable escaped : bool;
  mutable stored : bool;
  mutable kept : string option list;
}

(* Whether [i] is only ever stored, as a value. *)
let link i =
  let only = ref true in
  let check u =
    let s = Llvm.user u in
    if
      not
        (Llvm.classify_value s = Llvm.ValueKind.Instruction Llvm.Opcode.Store
        && Llvm.operand s 0 == i
        && Llvm.operand s 1 != i)
    then only := false
  in
  Llvm.iter_uses check i;
  !only

(* Whether [i] is only compared, directly or as a difference, as entering
   a scope inline checks the room left past its frame. *)
let rec compared i =
  let only = ref true in
  let check u =
    let s = Llvm.user u in
    match Llvm.classify_value s with
    | Llvm.ValueKind.Instruction Llvm.Opcode.ICmp -> ()
    | Llvm.ValueKind.Instruction Llvm.Opcode.Sub when compared s -> ()
    | _ -> only := false
  in
  Llvm.iter_uses check i;
  !only

(* A call given address [p] in the frame. A callee that may keep the
   address, as `overwrite` does in a deferred job a later call runs, may
   have any later call write the slot: the frame escaped. *)
let given (u : uses) p i =
  if not (keeps_none i p) then begin
    u.escaped <- true;
    u.kept <- callee i :: u.kept
  end;
  match callee i with
  | Some n when inert n -> ()
  | _ when List.memq i u.calls -> ()
  | _ -> u.calls <- i :: u.calls

(* The uses of [base] and of the phis beside it, or [Escapes_at] the first
   use that may reach its slots unseen. *)
let visit_frame dl ~followed ~parallel base =
  let u = { loads = []; stores = []; calls = []; escaped = false; stored = false; kept = [] } in
  let seen = seeds parallel base and visited = ref [] in
  let at i = match offset_from dl seen base i with Some (Some o) -> o | _ -> raise (Escapes_at i) in
  let rec visit p off = Llvm.iter_uses (fun x -> use p off (Llvm.user x)) p
  and use p off i =
    match Llvm.classify_value i with Llvm.ValueKind.Instruction op -> instr p off op i | _ -> raise (Escapes_at i)
  and instr p off op i =
    match op with
    | Llvm.Opcode.GetElementPtr when Llvm.operand i 0 == p -> visit i (at i)
    (* A merge of frames is visited as its own frame. *)
    | Llvm.Opcode.PHI when not (followed i) -> ()
    (* The scope chain's link, chosen between the frame and a scope it
       encloses, as entering a scope inline picks the record's skip
       ([ZANE_MARK_SKIP]): stored only as a value, as the frame itself is
       below. *)
    | (Llvm.Opcode.PHI | Llvm.Opcode.Select) when off < mark && link i -> ()
    | Llvm.Opcode.PHI | Llvm.Opcode.Select when Llvm.operand i 0 != p || op = Llvm.Opcode.PHI ->
        if not (List.memq i !visited) then begin
          visited := i :: !visited;
          visit i (at i)
        end
    (* An ordered or volatile read must stay a read of the frame. *)
    | Llvm.Opcode.Load when Llvm.is_volatile i || Llvm_extra.is_atomic i -> raise (Escapes_at i)
    | Llvm.Opcode.Load -> u.loads <- (i, off) :: u.loads
    | Llvm.Opcode.Store when Llvm.operand i 1 == p && Llvm.operand i 0 != p -> u.stores <- (i, off) :: u.stores
    (* The frame's record names it in the scope chain. *)
    | Llvm.Opcode.Store when Llvm.operand i 0 == p && off < mark -> ()
    (* A slot's address the runtime keeps, as a deferred job does: any call
       may then write the slot. *)
    | Llvm.Opcode.Store when Llvm.operand i 0 == p && Llvm.operand i 1 != p ->
        u.escaped <- true;
        u.stored <- true
    | Llvm.Opcode.Call -> given u p i
    | Llvm.Opcode.ICmp -> ()
    | Llvm.Opcode.PtrToInt when compared i -> ()
    | _ -> raise (Escapes_at i)
  in
  visit base 0L;
  List.iter (fun (q, (m, o)) -> if m == base then visit q o) parallel;
  u

let size dl t = Llvm_target.DataLayout.store_size t dl

(* Tests whether an access at [o'] of [t'] holds all of the slot at [o] of
   [t] and is larger than the slot. *)
let covers dl (o', t') (o, t) = o' <= o && Int64.add o' (size dl t') >= Int64.add o (size dl t) && size dl t' > size dl t

(* The slots: each offset loaded at least once, where every access that
   overlaps it is of the same offset and type, or is wider and holds the
   whole slot: a load of more than the slot reads the frame, which the
   copy is written back to first, and a store of more (a list's count and
   room stored as one pair, as copying the list into a struct does) fills
   the copy again. *)
let slots_of dl u =
  let accesses =
    List.map (fun (i, o) -> (o, Llvm.type_of i)) u.loads
    @ List.map (fun (i, o) -> (o, Llvm.type_of (Llvm.operand i 0))) u.stores
  in
  let slot o =
    let t = Llvm.type_of (fst (List.find (fun (_, o2) -> o2 = o) u.loads)) in
    let hi = Int64.add o (size dl t) in
    let overlapping = List.filter (fun (o', t') -> o' < hi && Int64.add o' (size dl t') > o) accesses in
    let fits (o', t') = (o' = o && t' == t) || covers dl (o', t') (o, t) in
    if scalar t && List.for_all fits overlapping then Some (o, t) else None
  in
  List.sort_uniq compare (List.map snd (List.filter (fun (_, o) -> o >= mark) u.loads)) |> List.filter_map slot

(* One frame being rewritten: its copies, each an offset, a type and the
   alloca, and what the passes over it share. *)
type shadow = {
  ctx : Llvm.llcontext;
  dl : Llvm_target.DataLayout.t;
  f : Llvm.llvalue;
  base : Llvm.llvalue;
  home : Llvm.llbasicblock;
  u : uses;
  copies : (int64 * Llvm.lltype * Llvm.llvalue) list;
  dom : Llvm.llbasicblock -> Llvm.llbasicblock -> bool;
  preds : (Llvm.llbasicblock, Llvm.llbasicblock) Hashtbl.t;
  parallel : (Llvm.llvalue * (Llvm.llvalue * int64)) list;
  live : Llvm.llbasicblock -> bool;
  calls : Llvm.llvalue list;
  deferred : bool;
}

(* The blocks the frame is live into: a load or store past its record, or
   a call given an address in it, is reachable from the block's start
   without placing the frame again. Past its last use the frame may be
   drained, and its memory another frame's. *)
let live_blocks f home uses =
  let used_in = Hashtbl.create 16 and live_in = Hashtbl.create 16 in
  List.iter (fun i -> Hashtbl.replace used_in (Llvm.instr_parent i) ()) uses;
  let live b = Hashtbl.mem live_in b in
  let grew = ref true in
  let step b =
    if b != home && (not (live b)) && (Hashtbl.mem used_in b || List.exists live (successors b)) then begin
      Hashtbl.replace live_in b ();
      grew := true
    end
  in
  while !grew do
    grew := false;
    Llvm.iter_blocks step f
  done;
  live

(* Whether the frame may still be used after call [c], or by it. *)
let used_after ~addressed ~uses ~live c =
  let rec go = function
    | Llvm.Before i -> List.memq i uses || go (Llvm.instr_succ i)
    | Llvm.At_end b -> List.exists live (successors b)
  in
  List.memq c addressed || go (Llvm.instr_succ c)

let slot s b o =
  Llvm.build_in_bounds_gep (Llvm.i8_type s.ctx) s.base [| Llvm.const_of_int64 (Llvm.i64_type s.ctx) o true |] "" b

(* Filling copies from their slots, and writing them back. *)
let fill s b = List.iter (fun (o, t, a) -> ignore (Llvm.build_store (Llvm.build_load t (slot s b o) "" b) a b))
let back s b = List.iter (fun (o, t, a) -> ignore (Llvm.build_store (Llvm.build_load t a "" b) (slot s b o) b))

(* The copy an access of exactly [t] at [o] reads or writes, and the
   copies a wider access at [o] of [t] holds. *)
let copy s o t = List.find_opt (fun (o', t', _) -> o' = o && t' == t) s.copies
let held s o t = List.filter (fun (o', t', _) -> covers s.dl (o, t) (o', t')) s.copies

let within s lo len = List.filter (fun (o, t, _) -> o < Int64.add lo len && Int64.add o (size s.dl t) > lo) s.copies
(* The offset of [p] in the frame, through the phis beside it as well:
   a `memcpy` given a slot's address LLVM carries through a merge apart
   from the frame reaches that slot. *)
let in_frame s p = match offset_from s.dl (seeds s.parallel s.base) s.base p with Some (Some o) -> Some o | _ -> None
let elsewhere s = if s.u.escaped then s.copies else []
let mem n = starts "llvm.memset" n || starts "llvm.memcpy" n || starts "llvm.memmove" n

(* The copies the [k]th operand of call [c] reaches: those a `memset`,
   `memcpy` or `memmove` of a constant length covers there (none when it
   is outside a frame whose address went nowhere else), the list header
   the runtime's growth ([Frame_scopes.list_calls]) is given (whether or
   not a slot's address went elsewhere: growth reaches no address it was
   given before), and every copy for any other call. *)
let reached s c k =
  let header = Llvm_target.DataLayout.abi_size (List_handle.header s.ctx) s.dl in
  match callee c with
  | Some n when mem n -> (
      match (in_frame s (Llvm.operand c k), Llvm.int64_of_const (Llvm.operand c 2)) with
      | Some o, Some len -> within s o len
      | None, _ -> elsewhere s
      | Some _, None -> s.copies)
  | Some n when List.mem n Frame_scopes.list_calls -> (
      match in_frame s (Llvm.operand c 0) with Some o -> within s o header | None -> elsewhere s)
  | _ -> s.copies

(* The copies a call may have written, so filled again after it: its
   destination's. An arithmetic coder's bit writer clears its byte and
   count with one `memset` per byte, and the push that follows would
   otherwise load every slot again, the coder's tables among them
   (tests/perf `refills`). *)
let refilled s c = reached s c 0

(* The copies a call may read, so written back before it, with those it
   may write, which are filled again from the frame: none for a `memset`,
   the source for a `memcpy` or `memmove`. *)
let read s c = match callee c with Some n when starts "llvm.memset" n -> [] | _ -> reached s c 1

(* The copies that may hold values their slots do not, at each call and
   load: stored since the frame was last filled into them or they were
   written back to it, on some path from where the frame is placed. Only
   those are written back, so a call a loop makes each pass writes back
   what the pass stored, not every copy. [ending] holds the copies written
   back at the end of a block, on its way into a loop. *)
type dirt = { dirty_at : (Llvm.llvalue, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t; ending : (Llvm.llbasicblock, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t }

type event = Dirty of (int64 * Llvm.lltype * Llvm.llvalue) | Agree of (int64 * Llvm.lltype * Llvm.llvalue) list | Reads of (int64 * Llvm.lltype * Llvm.llvalue) list

(* Each instruction's effect on the copies: a store to one dirties it, a
   wider store fills them again, a wider load and a call write back those
   they reach. *)
let events s =
  let at = Hashtbl.create 16 in
  let store (i, o) =
    let t = Llvm.type_of (Llvm.operand i 0) in
    Hashtbl.replace at i (match copy s o t with Some x -> Dirty x | None -> Agree (held s o t))
  in
  let load (i, o) = Hashtbl.replace at i (match copy s o (Llvm.type_of i) with None -> Reads (held s o (Llvm.type_of i)) | Some _ -> Reads []) in
  List.iter store s.u.stores;
  List.iter load s.u.loads;
  List.iter (fun c -> Hashtbl.replace at c (Reads (union (refilled s c) (read s c)))) s.calls;
  at

let dirty_step s at record dirt d i =
  if i == s.base then []
  else
    match Hashtbl.find_opt at i with
    | Some (Dirty x) -> if List.memq x d then d else x :: d
    | Some (Agree h) -> minus d h
    | Some (Reads w) ->
        if record then Hashtbl.replace dirt.dirty_at i d;
        minus d w
    | None -> d

(* The dirty copies out of each block, to a fixed point. *)
let dirty_out s at dirt =
  let out = Hashtbl.create 16 in
  let into b = List.fold_left (fun d p -> union d (found out p)) [] (Hashtbl.find_all s.preds b) in
  let through b = minus (Llvm.fold_left_instrs (dirty_step s at false dirt) (into b) b) (found dirt.ending b) in
  let grew = ref true in
  let step b =
    let d = through b and old = found out b in
    if List.exists (fun x -> not (List.memq x old)) d then begin
      Hashtbl.replace out b (union old d);
      grew := true
    end
  in
  while !grew do
    grew := false;
    Llvm.iter_blocks step s.f
  done;
  (out, into)

(* A copy dirty on the way into a loop and clean on its way round is
   written back once, on the way in, rather than at each pass's call: as a
   list pushed to before a loop whose every pass calls a function given the
   frame. Only into a block the frame is live in, so its memory is still
   its own, and from one the frame's placement dominates. Whether any was
   added. *)
let entering s out dirt b =
  let added = ref false in
  let round, entering = List.partition (fun p -> s.dom b p) (Hashtbl.find_all s.preds b) in
  let clean_round x = List.for_all (fun p -> not (List.memq x (found out p))) round in
  let enter p =
    let w = List.filter clean_round (found out p) in
    if w <> [] && s.dom s.home p then begin
      Hashtbl.replace dirt.ending p (union (found dirt.ending p) w);
      added := true
    end
  in
  if s.live b && round <> [] then List.iter enter entering;
  !added

let dirt s =
  let dirt = { dirty_at = Hashtbl.create 16; ending = Hashtbl.create 16 } in
  if s.deferred then begin
    let at = events s in
    let rec settle () =
      let out, _ = dirty_out s at dirt in
      let added = ref false in
      Llvm.iter_blocks (fun b -> if entering s out dirt b then added := true) s.f;
      if !added then settle ()
    in
    settle ();
    let _, into = dirty_out s at dirt in
    Llvm.iter_blocks (fun b -> ignore (Llvm.fold_left_instrs (dirty_step s at true dirt) (into b) b)) s.f
  end;
  dirt

let dirty dirt i = found dirt.dirty_at i

(* The copies filled again only where they are next loaded, rather than
   right after each call that may write their slots: [lazy_] holds them,
   [filled_at] the loads that fill one first, and [ends] the copies filled
   at the end of a block, on the paths where they are stale into a block
   where one is loaded. A copy is stale from such a call to its next load or
   store. A load that may find it stale and may find it fresh is reached
   by a fill on each path it is surely stale on; nothing may write a copy
   back while it may be stale, nor may a load find it stale and dirty; a
   copy for which that fails is filled after each call. A loop that calls a
   function given the frame on every pass then loads only the slots that
   pass reads, on the paths that read them, as it would with no copies;
   one that calls now and then keeps its copies filled. *)
type staleness = {
  mutable lazy_ : (int64 * Llvm.lltype * Llvm.llvalue) list;
  filled_at : (Llvm.llvalue, unit) Hashtbl.t;
  ends : (Llvm.llbasicblock, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t;
  backs : (Llvm.llvalue, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t;
  stores_at : (Llvm.llvalue, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t;
  loads_at : (Llvm.llvalue, int64 * Llvm.lltype * Llvm.llvalue) Hashtbl.t;
  calls_at : (Llvm.llvalue, (int64 * Llvm.lltype * Llvm.llvalue) list) Hashtbl.t;
  mutable bad : (int64 * Llvm.lltype * Llvm.llvalue) list;
  mutable mixed : ((int64 * Llvm.lltype * Llvm.llvalue) * Llvm.llbasicblock) list;
  mutable collecting : bool;
}

let staleness s dirt =
  let st =
    {
      lazy_ = s.copies;
      filled_at = Hashtbl.create 16;
      ends = Hashtbl.create 16;
      backs = Hashtbl.create 16;
      stores_at = Hashtbl.create 16;
      loads_at = Hashtbl.create 16;
      calls_at = Hashtbl.create 16;
      bad = [];
      mixed = [];
      collecting = false;
    }
  in
  let wider (i, o) = Hashtbl.replace st.backs i (inter (dirty dirt i) (held s o (Llvm.type_of i))) in
  if s.deferred then begin
    List.iter (fun (i, o) -> if copy s o (Llvm.type_of i) = None then wider (i, o)) s.u.loads;
    List.iter (fun c -> Hashtbl.replace st.backs c (inter (dirty dirt c) (refilled s c @ read s c))) s.calls
  end;
  let store (i, o) =
    let t = Llvm.type_of (Llvm.operand i 0) in
    Hashtbl.replace st.stores_at i (match copy s o t with Some x -> [ x ] | None -> held s o t)
  in
  List.iter store s.u.stores;
  List.iter (fun (i, o) -> Option.iter (Hashtbl.replace st.loads_at i) (copy s o (Llvm.type_of i))) s.u.loads;
  List.iter (fun c -> Hashtbl.replace st.calls_at c (refilled s c)) s.calls;
  st

(* A load of copy [x] in the state [(may, must)]: the copies that may be,
   and must be, stale. *)
let stale_load st dirt i x (may, must) =
  if List.memq x may && not (List.memq x must) then
    if List.memq x (dirty dirt i) then st.bad <- x :: st.bad
    else if st.collecting then st.mixed <- (x, Llvm.instr_parent i) :: st.mixed;
  (minus may [ x ], minus must [ x ])

let stale_step s st dirt (may, must) i =
  List.iter (fun x -> if List.memq x may then st.bad <- x :: st.bad) (found st.backs i);
  if i == s.base then ([], [])
  else
    match (Hashtbl.find_opt st.stores_at i, Hashtbl.find_opt st.loads_at i, Hashtbl.find_opt st.calls_at i) with
    | Some xs, _, _ -> (minus may xs, minus must xs)
    | None, Some x, _ -> stale_load st dirt i x (may, must)
    | None, None, Some w ->
        let w = inter w st.lazy_ in
        (may @ minus w may, must @ minus w must)
    | None, None, None -> (may, must)

let stale_through s st dirt state b =
  let may, must = Llvm.fold_left_instrs (stale_step s st dirt) state b in
  List.iter (fun x -> if List.memq x may then st.bad <- x :: st.bad) (found dirt.ending b);
  let w = found st.ends b in
  (minus may w, minus must w)

let stale_into s out b =
  match Hashtbl.find_all s.preds b with
  | [] -> ([], [])
  | ps -> (
      let seen = List.filter_map (Hashtbl.find_opt out) ps in
      let may = List.fold_left (fun d (m, _) -> union d m) [] seen in
      match seen with [] -> (may, []) | (_, m) :: rest -> (may, List.fold_left (fun d (_, m) -> inter d m) m rest))

(* The states out of each block, to a fixed point, and whether it was
   reached within the bound. *)
let stale_out s st dirt =
  let out = Hashtbl.create 16 in
  let grew = ref true and rounds = ref 0 in
  let saved = st.bad in
  let step b =
    let m, n = stale_through s st dirt (stale_into s out b) b in
    match Hashtbl.find_opt out b with
    | Some (m', n') when same m m' && same n n' -> ()
    | _ ->
        Hashtbl.replace out b (m, n);
        grew := true
  in
  while !grew && !rounds < 64 do
    grew := false;
    incr rounds;
    Llvm.iter_blocks step s.f
  done;
  st.bad <- saved;
  (out, not !grew)

(* Fills copy [x] at the end of each block it is surely stale out of on
   the way to block [b], following back the blocks it may be stale out
   of. Whether one was added. *)
let fill_paths s st out (x, b) =
  let met = ref [] and added = ref false in
  let rec need b = List.iter (from_pred b) (Hashtbl.find_all s.preds b)
  and from_pred _ p =
    match Hashtbl.find_opt out p with
    | Some (m, n) when List.memq x m && List.memq x n -> surely p
    | Some (m, _) when List.memq x m && not (List.memq p !met) ->
        met := p :: !met;
        need p
    | _ -> ()
  and surely p =
    let w = found st.ends p in
    if List.memq x w || not (s.dom s.home p) then st.bad <- x :: st.bad
    else begin
      Hashtbl.replace st.ends p (x :: w);
      added := true
    end
  in
  if List.memq x st.lazy_ then need b;
  !added

let rec settle_staleness s st dirt =
  let out, reached = stale_out s st dirt in
  (* Past the bound, every copy is filled after each call. *)
  st.bad <- (if reached then [] else st.lazy_);
  st.collecting <- true;
  st.mixed <- [];
  Llvm.iter_blocks (fun b -> ignore (stale_through s st dirt (stale_into s out b) b)) s.f;
  st.collecting <- false;
  let added = List.fold_left (fun a m -> fill_paths s st out m || a) false st.mixed in
  let bad = inter st.lazy_ st.bad in
  if bad <> [] then begin
    st.lazy_ <- minus st.lazy_ bad;
    Hashtbl.reset st.ends;
    settle_staleness s st dirt
  end
  else if added then settle_staleness s st dirt
  else
    let note state i =
      (match Hashtbl.find_opt st.loads_at i with
      | Some x when List.memq x (fst state) -> Hashtbl.replace st.filled_at i ()
      | _ -> ());
      stale_step s st dirt state i
    in
    Llvm.iter_blocks (fun b -> ignore (Llvm.fold_left_instrs note (stale_into s out b) b)) s.f

let at_end ctx b k = match Llvm.block_terminator b with Some t -> k (Llvm.builder_before ctx t) | None -> ()

(* Where the frame is placed: after it, past any phis. *)
let placed base =
  match Llvm.classify_value base with
  | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
      let rec past = function
        | Llvm.Before i when Llvm.instr_opcode i = Llvm.Opcode.PHI -> past (Llvm.instr_succ i)
        | pos -> pos
      in
      past (Llvm.instr_begin (Llvm.instr_parent base))
  | _ -> Llvm.instr_succ base

let rewrite_load s dirt st (i, o) =
  match copy s o (Llvm.type_of i) with
  | Some ((_, t, a) as x) ->
      let b = Llvm.builder_before s.ctx i in
      if Hashtbl.mem st.filled_at i then fill s b [ x ];
      let v = Llvm.build_load t a "" b in
      Llvm.replace_all_uses_with i v;
      Llvm.delete_instruction i
  | None ->
      (* A wider load reads the frame, so what it holds is written back
         first. *)
      if s.deferred then back s (Llvm.builder_before s.ctx i) (inter (held s o (Llvm.type_of i)) (dirty dirt i))

let rewrite_store s (i, o) =
  let t = Llvm.type_of (Llvm.operand i 0) in
  match copy s o t with
  | Some (_, _, a) ->
      let b = Llvm.builder_at s.ctx (Llvm.instr_succ i) in
      ignore (Llvm.build_store (Llvm.operand i 0) a b);
      if s.deferred then Llvm.delete_instruction i
  | None ->
      (* A wider store fills again the copies it holds, from the frame it
         has just written, which GVN then reads from the stored value. *)
      let h = held s o t in
      if h <> [] then fill s (Llvm.builder_at s.ctx (Llvm.instr_succ i)) h

let rewrite_call s dirt st c =
  (if s.deferred then
     let w = union (refilled s c) (read s c) in
     back s (Llvm.builder_before s.ctx c) (List.filter (fun x -> List.memq x (dirty dirt c) && List.memq x w) s.copies));
  match Llvm.instr_succ c with
  | Llvm.Before _ as pos -> fill s (Llvm.builder_at s.ctx pos) (minus (refilled s c) st.lazy_)
  | Llvm.At_end _ -> ()

(* Whether the copies' stores may wait for the next read of the frame: no
   address in it is stored, the only callees that keep one are the
   runtime's, which read it only inside a later call (a drain reads what
   `zane_hold` lists, growth the header it was given), and no merge reads
   the frame after it. Then no other thread holds an address in it, so a
   slot is read only by this function, through the frame, and by the calls
   given an address in it or after one was kept; it is written back before
   each. A frame placed on a path a merge joins is written through. *)
let defers ~joined base (u : uses) =
  let runtime_keeps = "zane_hold" :: "zane_scope_drain" :: Frame_scopes.list_calls in
  (not u.stored)
  && (not (List.memq base joined))
  && List.for_all (function Some n -> List.mem n runtime_keeps | None -> false) u.kept

let shadow_frame ctx dl f ~dom ~joined ~parallel base (u : uses) slots =
  (* A frame a slot's address escaped from is filled again after every
     call it is placed before. *)
  let addressed = u.calls in
  let calls = ref u.calls in
  if u.escaped then calls_after f (Lazy.force dom) base calls;
  let uses = List.filter_map (fun (i, o) -> if o >= mark then Some i else None) (u.loads @ u.stores) @ addressed in
  let home = Llvm.instr_parent base in
  let live = live_blocks f home uses in
  let at_entry = Llvm.builder_at ctx (Llvm.instr_begin (Llvm.entry_block f)) in
  let s =
    {
      ctx;
      dl;
      f;
      base;
      home;
      u;
      copies = List.map (fun (o, t) -> (o, t, Llvm.build_alloca t "shadow" at_entry)) slots;
      dom = Lazy.force dom;
      preds = predecessors f;
      parallel;
      live;
      calls = List.filter (used_after ~addressed ~uses ~live) !calls;
      deferred = defers ~joined base u;
    }
  in
  let dirt = dirt s in
  let st = staleness s dirt in
  settle_staleness s st dirt;
  fill s (Llvm.builder_at ctx (placed base)) s.copies;
  Hashtbl.iter (fun b w -> at_end ctx b (fun at -> fill s at (inter w st.lazy_))) st.ends;
  Hashtbl.iter (fun b w -> at_end ctx b (fun at -> back s at w)) dirt.ending;
  List.iter (rewrite_load s dirt st) u.loads;
  List.iter (rewrite_store s) u.stores;
  List.iter (rewrite_call s dirt st) s.calls

let func ctx dl (f : Llvm.llvalue) =
  let fr = find_frames f in
  let parallel = find_parallel dl fr in
  let followed i =
    (not (List.memq i fr.merges))
    && (not (List.mem_assq i parallel))
    && not (List.exists (fun (v, _) -> open_scope v) (Llvm.incoming i))
  in
  (* The frames a merge joins: each path's frame is written through, so
     that the merge, filled where it is placed, reads what the path
     stored. *)
  let joined = ref [] in
  let join i =
    if Llvm.instr_opcode i = Llvm.Opcode.PHI && not (followed i) then
      List.iter (fun (v, _) -> joined := v :: !joined) (Llvm.incoming i)
  in
  Llvm.iter_blocks (fun b -> Llvm.iter_instrs join b) f;
  (* A merge is shadowed only where each frame it joins was visited whole:
     a use of one that is neither the merge nor beside it would reach the
     merge's slots unseen. *)
  let clean = ref [] in
  let ready base =
    (not (List.memq base fr.merges)) || List.for_all (fun (v, _) -> List.memq v !clean) (Llvm.incoming base)
  in
  let dom = lazy (dominators f) in
  let one base =
    match visit_frame dl ~followed ~parallel base with
    | exception Escapes_at _ -> ()
    | u ->
        clean := base :: !clean;
        let slots = slots_of dl u in
        if slots <> [] then shadow_frame ctx dl f ~dom ~joined:!joined ~parallel base u slots
  in
  let order = List.filter (fun b -> not (List.memq b fr.merges)) fr.all @ List.rev fr.merges in
  List.iter (fun base -> if ready base then one base) order

let run m =
  let ctx = Llvm.module_context m in
  let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
  Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func ctx dl f) m

(* The passes run again once the copies are in. *)
let again =
  "function(sroa,early-cse<memssa>,loop-mssa(licm<allowspeculation>),gvn<pre;load-pre>,instcombine<no-verify-fixpoint>,simplifycfg,dse,loop-mssa(licm<allowspeculation>))"
