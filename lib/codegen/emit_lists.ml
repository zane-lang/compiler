(* A list's or an array's elements: locating one, checked against the count
   (§9), pushing one and removing one, with the alias tags that let LLVM keep
   a list's header across its elements' writes: the fourth part of Emit, which
   includes it after Emit_frames. *)

open Cgt.Nodes
open Loop_shapes
open Call_pieces
open Llvm_extra
open Emit_types
open Loop_copies
open Emit_runtime
open Emit_frames

(* The address of a list's or an array's element, counted from 1, checked
   against its count here rather than in the runtime, so LLVM sees the count,
   the index and the address the way it sees any arithmetic. Only an index
   outside calls the runtime, which stops the program (§9). One unsigned
   compare of the index less one covers both ends. *)
let element ?cached ?(unchecked = false) env fr b fn args =
  let base, index, count, stride =
    match (fn, args, cached) with
    | Cgt.Runtime.List_at, [ _; index; stride ], Some (items, count) -> (items, index, count, stride)
    | Cgt.Runtime.List_at, [ list; index; stride ], None ->
        let tag = handle_field env and count_tag = if List_handle.on () then handle_field env else count_field env in
        (List_handle.items ~tag env.ctx b list, index, List_handle.count ~tag:count_tag env.ctx b list, stride)
    | Cgt.Runtime.Array_at, [ array; index; count; stride ], _ -> (array, index, count, stride)
    | _ -> Diagnostic.bug "codegen: an element address with the wrong arguments"
  in
  let offset = Llvm.build_sub index (Llvm.const_int env.i64 1) "" b in
  (* The address is taken from a base biased one element down,
     [(base - stride) + index * stride], so the index less one that the
     check compares is not on the way to the address: an index loaded from
     memory (a tree's child, a graph's neighbour) is scaled and added to a
     base the loop does not change, and LLVM folds the bias into the load's
     displacement (tests/perf `nodes`). The biased base is outside the
     block, so neither GEP is in bounds. *)
  let address () =
    let i8 = Llvm.i8_type env.ctx in
    let biased = Llvm.build_gep i8 base [| Llvm.build_neg stride "" b |] "" b in
    Llvm.build_gep i8 biased [| Llvm.build_nsw_mul index stride "" b |] "" b
  in
  if unchecked then address ()
  else
  let stop = block env fr and inside = block env fr in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Uge offset count "" b) stop inside b);
  Llvm.position_at_end stop b;
  let f, fty = runtime env Cgt.Runtime.Out_of_range in
  ignore (Llvm.build_call fty f [||] "" b);
  ignore (Llvm.build_unreachable b);
  Llvm.position_at_end inside b;
  address ()

(* Whether the address [p] is, by how it was made, in the innermost scope's
   region while that scope is open: a slot of the function's innermost
   frame, or of its machine stack, which the runtime counts as the
   innermost scope's (runtime/arena.c). Anything else is found at run time. *)
let innermost fr p =
  let rec base v =
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> base (Llvm.operand v 0)
    | _ -> v
  in
  let p = base p in
  let innermost_frame = match fr.open_ with frame :: _ -> Some frame | [] -> None in
  match (Llvm.classify_value p, Held_spills.find p) with
  (* A held local's alloca (Held_spills) is its scope's, which may be one
     around the innermost. *)
  | _, Some h -> ( match innermost_frame with Some frame -> h.Held_spills.arena == frame | None -> false)
  | Llvm.ValueKind.Instruction Llvm.Opcode.Alloca, None -> true
  | _ -> ( match innermost_frame with Some frame -> p == frame | None -> false)

(* An empty list's first block of [first] bytes, made here when its handle
   holds no block (its room is 0, as runtime/list.c reads it: the push's
   fast path loads the room already, while a look at the items would load
   them ahead of its check) and is in the innermost scope's region, the
   open one, as the runtime would make it (runtime/list.c): the top of the
   scope's size class of [first] bytes when it holds a returned block; else
   the next word-aligned bytes in the scope's heap when it has them; or,
   when nothing has yet been allocated in the scope, the first word-aligned
   bytes past its frame, which stretches by ZANE_STRETCH bytes for them. The handle is checked to be in
   the frame unless [innermost] knows it is in the scope's region already.
   Any check that fails goes to [fail]; otherwise the push is made and the
   element's address is returned. *)
let first_block env fr b ~header ~list ~fail ~first ~stride =
  let ptr = env.ptr and i64 = env.i64 in
  let n x = Llvm.const_int i64 x in
  let check cond =
    let next = block env fr in
    ignore (Llvm.build_cond_br cond next fail b);
    Llvm.position_at_end next b
  in
  let address p = Llvm.build_ptrtoint p i64 "" b in
  let aligned p =
    Llvm.build_and
      (Llvm.build_add p (n (Abi.list_align - 1)) "" b)
      (Llvm.const_of_int64 i64 (Int64.of_int (-Abi.list_align)) true)
      "" b
  in
  ignore header;
  let room = List_handle.room ~tag:(handle_field env) env.ctx b list in
  check (Llvm.build_icmp Llvm.Icmp.Eq room (n 0) "" b);
  let m = List_handle.aligned env.ctx 8 (Llvm.build_load ptr (open_scope env) "" b) in
  check (Llvm.build_icmp Llvm.Icmp.Ne m (Llvm.const_null ptr) "" b);
  let c = field env b ptr m record_context in
  let record = address m in
  if not (innermost fr list) then begin
    let at = address list in
    let from = address (field env b ptr c context_frontier) in
    check
      (Llvm.build_and
         (Llvm.build_icmp Llvm.Icmp.Uge at record "" b)
         (Llvm.build_icmp Llvm.Icmp.Ult at from "" b)
         "" b)
  end;
  let class_at = byte_at env b m (8 * ((first / 8) - 1)) in
  let top = List_handle.aligned env.ctx 8 (Llvm.build_load ptr class_at "" b) in
  let pop = block env fr and look = block env fr in
  let fresh = block env fr and used = block env fr and taken = block env fr and bumped = block env fr in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ne top (Llvm.const_null ptr) "" b) pop look b);
  Llvm.position_at_end pop b;
  ignore (Llvm.build_store (List_handle.aligned env.ctx 8 (Llvm.build_load ptr top "" b)) class_at b);
  ignore (Llvm.build_br taken b);
  Llvm.position_at_end look b;
  let bump = field env b ptr m Walks.frontier in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Eq bump (Llvm.const_null ptr) "" b) fresh used b);
  Llvm.position_at_end used b;
  let start_used = aligned (address bump) in
  let ends = address (field env b ptr m Walks.frontier_end) in
  check (Llvm.build_icmp Llvm.Icmp.Ule (Llvm.build_add start_used (n first) "" b) ends "" b);
  let used_end = Llvm.insertion_block b in
  ignore (Llvm.build_br bumped b);
  Llvm.position_at_end fresh b;
  let frontier = field env b ptr c context_frontier in
  let stretched = byte_at env b frontier Abi.stretch in
  check (Llvm.build_icmp Llvm.Icmp.Ule (Llvm.build_sub (address stretched) record "" b) (n Abi.stretched) "" b);
  check (Llvm.build_icmp Llvm.Icmp.Ule (address stretched) (address (field env b ptr c context_limit)) "" b);
  set_field env b stretched c context_frontier;
  set_field env b stretched m Walks.frontier_end;
  let start_fresh = aligned (address frontier) in
  let fresh_end = Llvm.insertion_block b in
  ignore (Llvm.build_br bumped b);
  Llvm.position_at_end bumped b;
  let start = Llvm.build_phi [ (start_used, used_end); (start_fresh, fresh_end) ] "" b in
  let start = Llvm.build_inttoptr start ptr "" b in
  set_field env b (byte_at env b start first) m Walks.frontier;
  ignore (Llvm.build_br taken b);
  Llvm.position_at_end taken b;
  let start = Llvm.build_phi [ (top, pop); (start, bumped) ] "" b in
  let live = field env b i64 m Walks.live in
  set_field env b (Llvm.build_add live (n 1) "" b) m Walks.live;
  let tag = handle_field env in
  List_handle.set_items ~tag env.ctx b start list;
  List_handle.set_count ~tag env.ctx b (n 1) list;
  List_handle.set_room ~tag env.ctx b (n (List_handle.units ~bytes:first ~stride)) list;
  start

(* Room for one more element at the end of a list, [stride] bytes wide: the
   address the element is then moved into. While the list's block has room,
   the push is made here, so LLVM sees the count and the address the way it
   sees any arithmetic, and so is an empty list's first block in the
   innermost scope ([first_block]) in a function with a scope of its own
   open; otherwise the runtime grows the block and makes the push (§9). A
   function with none keeps the call, so its code stays small enough for
   LLVM to unroll a loop of a few pushes, as a recursive build makes.

   The first push of a run ([runs]) makes room for the [ahead] pushes of
   the run, its own and those after it, and each of the others is made
   [unchecked], with no look at the room at all. *)
let push env fr b ?(ahead = 1) ?(unchecked = false) list stride =
  let header = List_handle.header env.ctx in
  let tag = handle_field env in
  let stored = List_handle.count_stored ~tag env.ctx b list in
  let count = List_handle.widen_count env.ctx b stored in
  let room = List_handle.room ~tag env.ctx b list in
  let next = Llvm.build_nsw_add count (Llvm.const_int env.i64 1) "" b in
  let in_room () =
    let items = List_handle.items ~tag env.ctx b list in
    let offset = Llvm.build_nsw_mul count stride "" b in
    let at = Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items [| offset |] "" b in
    List_handle.set_count_after ~tag env.ctx b stored list;
    at
  in
  if unchecked then in_room ()
  else
    let wanted =
      if ahead = 1 then next else Llvm.build_nsw_add count (Llvm.const_int env.i64 ahead) "" b
    in
    let full =
      if List_handle.elements () then Llvm.build_icmp Llvm.Icmp.Sgt wanted room "" b
      else Llvm.build_icmp Llvm.Icmp.Sgt (Llvm.build_nsw_mul wanted stride "" b) room "" b
    in
    let grow = block env fr and fits = block env fr and pushed = block env fr in
    unlikely env (Llvm.build_cond_br full grow fits b);
    Llvm.position_at_end fits b;
    let at = in_room () in
    ignore (Llvm.build_br pushed b);
    Llvm.position_at_end grow b;
    let runtime_ = block env fr in
    let firsts =
      match Llvm.int64_of_const stride with
      | Some s when s >= 1L && Int64.mul s (Int64.of_int ahead) <= Int64.of_int Abi.list_first && fr.open_ <> [] ->
          let first = List_handle.first_room ~bytes:(Int64.to_int s * ahead) ~stride:(Int64.to_int s) in
          let made = first_block env fr b ~header ~list ~fail:runtime_ ~first ~stride:(Int64.to_int s) in
          let made_end = Llvm.insertion_block b in
          ignore (Llvm.build_br pushed b);
          [ (made, made_end) ]
      | _ ->
          ignore (Llvm.build_br runtime_ b);
          []
    in
    Llvm.position_at_end runtime_ b;
    let grown =
      if ahead = 1 then
        let f, fty = runtime env Cgt.Runtime.List_push in
        Llvm.build_call fty f [| list; stride |] "" b
      else
        let f, fty = runtime env Cgt.Runtime.List_reserve in
        Llvm.build_call fty f [| list; stride; Llvm.const_int env.i64 ahead |] "" b
    in
    (* The paths above are the runtime's own fast ones, so its body would
       only repeat them here (Runtime_bodies). *)
    Llvm.add_call_site_attr grown
      (Llvm.create_enum_attr env.ctx "noinline" 0L)
      Llvm.AttrIndex.Function;
    ignore (Llvm.build_br pushed b);
    Llvm.position_at_end pushed b;
    Llvm.build_phi ((at, fits) :: (grown, runtime_) :: firsts) "" b

let remove env fr b fn list index stride =
  let i8 = Llvm.i8_type env.ctx and one = Llvm.const_int env.i64 1 in
  let tag = handle_field env in
  let count = List_handle.count ~tag env.ctx b list in
  let items = List_handle.items ~tag env.ctx b list in
  let slot n = Llvm.build_in_bounds_gep i8 items [| Llvm.build_nsw_mul n stride "" b |] "" b in
  let at = slot (Llvm.build_nsw_sub index one "" b) in
  let move name dst src size =
    let i1 = Llvm.i1_type env.ctx in
    let t = Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr; env.i64; i1 |] in
    let f =
      match Llvm.lookup_function name env.m with
      | Some f -> f
      | None -> Llvm.declare_function name t env.m
    in
    let moved = Llvm.build_call t f [| dst; src; size; Llvm.const_int i1 0 |] "" b in
    match fn with
    | Cgt.Runtime.List_remove { scalars = true } | Cgt.Runtime.List_swap_remove { scalars = true } ->
        Llvm.set_metadata moved (Llvm.mdkind_id env.ctx "tbaa") env.value_tag
    | _ -> ()
  in
  (match fn with
  | Cgt.Runtime.List_remove _ -> (
      let later = Llvm.build_nsw_mul (Llvm.build_nsw_sub count index "" b) stride "" b in
      let from = Llvm.build_in_bounds_gep i8 at [| stride |] "" b in
      (* A move of more than 4 KiB by less than 64 bytes is made 2 KiB at a
         time, lowest first, so that glibc copies each piece with its vector
         loop rather than `rep movsb`, which it takes from 4 KiB on with
         AVX2 and which some Intel processors run at a byte a cycle when the
         source is that close past the destination (runtime/list.c,
         `zane_shift_down`). Each piece writes below what the next reads. *)
      match Llvm.int64_of_const stride with
      | Some s when s < 64L ->
          let piece = Llvm.const_int env.i64 2048 in
          let large = Llvm.build_icmp Llvm.Icmp.Sgt later (Llvm.const_int env.i64 4096) "" b in
          let entry = Llvm.insertion_block b in
          let pieces = block env fr and small = block env fr and moved = block env fr in
          ignore (Llvm.build_cond_br large pieces small b);
          Llvm.position_at_end pieces b;
          let i = Llvm.build_phi [ (Llvm.const_int env.i64 0, entry) ] "" b in
          let rest = Llvm.build_sub later i "" b in
          let size = Llvm.build_select (Llvm.build_icmp Llvm.Icmp.Slt rest piece "" b) rest piece "" b in
          move "llvm.memmove.p0.p0.i64" (Llvm.build_gep i8 at [| i |] "" b) (Llvm.build_gep i8 from [| i |] "" b) size;
          let next = Llvm.build_add i piece "" b in
          Llvm.add_incoming (next, Llvm.insertion_block b) i;
          ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt next later "" b) pieces moved b);
          Llvm.position_at_end small b;
          move "llvm.memmove.p0.p0.i64" at from later;
          ignore (Llvm.build_br moved b);
          Llvm.position_at_end moved b
      | _ -> move "llvm.memmove.p0.p0.i64" at from later)
  | _ ->
      let before = Llvm.build_icmp Llvm.Icmp.Slt index count "" b in
      let moving = block env fr and moved = block env fr in
      ignore (Llvm.build_cond_br before moving moved b);
      Llvm.position_at_end moving b;
      move "llvm.memcpy.p0.p0.i64" at (slot (Llvm.build_nsw_sub count one "" b)) stride;
      ignore (Llvm.build_br moved b);
      Llvm.position_at_end moved b);
  List_handle.set_count ~tag env.ctx b (Llvm.build_nsw_sub count one "" b) list

