(* A function's frame while it is built: its slots, the scopes and arenas
   it opens and drains (L8), and the branch weights and loop metadata its
   control flow carries: the third part of Emit, which includes it after
   Emit_runtime. *)

open Cgt.Nodes
open Loop_shapes
open Call_pieces
open Llvm_extra
open Emit_types
open Loop_copies
open Emit_runtime

(* Where a list's run of pushes stands ([runs]): [Ahead n] before its first
   push, which makes room for all [n]; [Room n] while the next [n] have
   room already. *)
type run = Ahead of int | Room of int

(* What a function being built keeps: its symbol, its slots, the exit
   block of each expansion it is inside with how many arenas were open when
   it began, each open arena's record, the arenas open where it is building,
   innermost first (L8), where in its arena's frame each slot is, how
   many loops it is building inside, and its runs of pushes. *)
type frame = {
  fn : Llvm.llvalue;
  symbol : string;
  locals : (int, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  labels : (int, Llvm.llbasicblock * int) Hashtbl.t;
  arenas : (int, Llvm.llvalue) Hashtbl.t;
  mutable open_ : Llvm.llvalue list;
  (* The open arenas that place a slot holding a foreign handle. *)
  mutable handled : Llvm.llvalue list;
  (* The open arenas that spawn a call. *)
  mutable spawning : Llvm.llvalue list;
  offsets : (int, int) Hashtbl.t;
  (* The function's result type and how it comes back, and the slot it is
     written to when that is by address. *)
  ret : Ty.t * passing;
  sret : Llvm.llvalue option;
  mutable loops : int;
  (* Each fresh list a run of pushes follows ([runs]), with where its run
     stands. *)
  runs : (int, run) Hashtbl.t;
  (* Experimental (ZANE_HOIST_HANDLES): the lists whose items and count the
     loop being emitted read once before it ([invariant_lists]), each by the
     expression of its address, and how a local of the loop's body names one. *)
  mutable hoisted : (Expr.t * (Llvm.llvalue * Llvm.llvalue)) list;
  (* The function's lists only it reaches (Loop_shapes.own_lists). *)
  own : int -> bool;
  names : (int, Expr.t) Hashtbl.t;
  (* The element addresses the loop being emitted checks before it ([ranged]). *)
  mutable unchecked : Expr.t list;
  (* Each list an optimized build's loop made room for, with its block read
     once before the loop and its count kept in a local. *)
  kept : (int, Llvm.llvalue * Llvm.llvalue) Hashtbl.t;
}

let call_runtime env b name args =
  let f, fty = runtime env name in
  Llvm.build_call fty f args "" b

let block env fr = Llvm.append_block env.ctx "" fr.fn

let open_scope env = Walks.zane_open env.m env.ptr

(* Whether drains are checked (runtime/main.c). *)
let checking env =
  match Llvm.lookup_global "zane_checking" env.m with
  | Some g -> g
  | None -> Llvm.declare_global (Llvm.i32_type env.ctx) "zane_checking" env.m

let byte_at env b p offset =
  if offset = 0 then p
  else Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) p [| Llvm.const_int env.i64 offset |] "" b

(* A runtime record's field. A pointer one names a record, a context or a
   block, each aligned to a word at least. *)
let field env b t p offset =
  let v = Llvm.build_load t (byte_at env b p offset) "" b in
  if t == env.ptr then List_handle.aligned env.ctx 8 v else v
let set_field env b v p offset = ignore (Llvm.build_store v (byte_at env b p offset) b)

let zero env b p size =
  if size > 0 then begin
    let name = "llvm.memset.p0.i64" in
    let i1 = Llvm.i1_type env.ctx and i8 = Llvm.i8_type env.ctx in
    let t = Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; i8; env.i64; i1 |] in
    let f = match Llvm.lookup_function name env.m with Some f -> f | None -> Llvm.declare_function name t env.m in
    ignore
      (Llvm.build_call t f [| p; Llvm.const_int i8 0; Llvm.const_int env.i64 size; Llvm.const_int i1 0 |] "" b)
  end

(* A branch that is almost never taken, marked so by LLVM's branch weights,
   so its code is laid out away from the path that is taken. *)
let unlikely env br =
  let i32 = Llvm.i32_type env.ctx in
  let weights =
    Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "branch_weights"; Llvm.const_int i32 1; Llvm.const_int i32 2000 |]
  in
  Llvm.set_metadata br (Llvm.mdkind_id env.ctx "prof") weights

(* A loop's test, [br], weighted as going round [trips] times for each time
   it leaves. *)
let weigh env br trips =
  let i32 = Llvm.i32_type env.ctx in
  let weights =
    Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "branch_weights"; Llvm.const_int i32 trips; Llvm.const_int i32 1 |]
  in
  Llvm.set_metadata br (Llvm.mdkind_id env.ctx "prof") weights

(* The `llvm.loop` node that asks for a loop unrolled twice. *)
let unroll_twice env =
  let i32 = Llvm.i32_type env.ctx in
  Llvm_extra.loop_id env.ctx [| Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "llvm.loop.unroll.count"; Llvm.const_int i32 2 |] |]

(* Offsets into a scope's record and a context (runtime/zane_abi.h). *)
let record_context = Abi.mark_context
and record_depth = Abi.mark_depth
and record_outer = Abi.mark_outer
and record_skip = Abi.mark_skip
and record_tasks = Abi.mark_tasks
and record_mappings = Abi.mark_mappings
and record_held = Abi.mark_held
and record_stacks = Abi.mark_stacks
and context_frontier = Abi.context_frontier
and context_top = Abi.context_top
and context_limit = Abi.context_limit

(* A scope opens with a frame of [size] bytes (Frames), and its record's
   address names it. Only this thread changes its context's scopes, so the
   code places the frame itself: the record goes at the frontier, which
   moves past the frame, and links to the scope around it and to the one it
   skips to (runtime/zane_internal.h). A frame larger than the guard after
   the range is checked against the range's end first; a smaller one that
   does not fit faults in the guard. A thread that runs no context yet has
   no open scope, and the runtime places the frame instead.

   Either way, reading any slot of the open scope's frame is safe: in the
   range the runtime makes the slot's memory usable, and in the guard it
   stops the program, which a frame that does not fit requires at
   whichever of its slots is touched first. The frame is on a 16-byte
   boundary, since every frame is a multiple of 16 bytes (Frames) placed
   where the one before it ended. LLVM is given both facts about the open
   scope, so it may read a slot ahead of a branch, as it hoists a list's
   count out of a loop that checks its indices (docs/optimizations.md). *)
let enter env fr b size =
  let ptr = env.ptr and i64 = env.i64 in
  let outer = List_handle.aligned env.ctx 8 (Llvm.build_load ptr (open_scope env) "" b) in
  let inline = block env fr and shared = block env fr and opened = block env fr in
  ignore
    (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ne outer (Llvm.const_null ptr) "" b) inline shared b);
  Llvm.position_at_end inline b;
  let c = field env b ptr outer record_context in
  let m = field env b ptr c context_frontier in
  if size > Frames.guard then begin
    (* The room left is compared, not the frame's end, which would be an
       address past the range when the frame does not fit. *)
    let limit = field env b ptr c context_limit in
    let room = Llvm.build_sub (Llvm.build_ptrtoint limit i64 "" b) (Llvm.build_ptrtoint m i64 "" b) "" b in
    let over = Llvm.build_icmp Llvm.Icmp.Ult room (Llvm.const_int i64 size) "" b in
    let stop = block env fr and fits = block env fr in
    unlikely env (Llvm.build_cond_br over stop fits b);
    Llvm.position_at_end stop b;
    ignore (call_runtime env b Cgt.Runtime.Too_deep [||]);
    ignore (Llvm.build_unreachable b);
    Llvm.position_at_end fits b
  end;
  set_field env b (byte_at env b m size) c context_frontier;
  zero env b m Frames.record;
  set_field env b c m record_context;
  let depth = field env b i64 outer record_depth in
  set_field env b (Llvm.build_add depth (Llvm.const_int i64 1) "" b) m record_depth;
  set_field env b outer m record_outer;
  let a = field env b ptr outer record_skip in
  let a_depth = field env b i64 a record_depth in
  let b_ = field env b ptr a record_skip in
  let b_depth = field env b i64 b_ record_depth in
  let equal =
    Llvm.build_icmp Llvm.Icmp.Eq
      (Llvm.build_sub depth a_depth "" b)
      (Llvm.build_sub a_depth b_depth "" b)
      "" b
  in
  set_field env b (Llvm.build_select equal b_ outer "" b) m record_skip;
  set_field env b m c context_top;
  ignore (Llvm.build_store m (open_scope env) b);
  let inline_end = Llvm.insertion_block b in
  ignore (Llvm.build_br opened b);
  Llvm.position_at_end shared b;
  let placed = call_runtime env b Cgt.Runtime.Scope_enter [| Llvm.const_int i64 size |] in
  ignore (Llvm.build_br opened b);
  Llvm.position_at_end opened b;
  let frame = Llvm.build_phi [ (m, inline_end); (placed, shared) ] "" b in
  let assume, assume_ty =
    match Llvm.lookup_function "llvm.assume" env.m with
    | Some f -> (f, value_type f)
    | None ->
        let t = Llvm.function_type (Llvm.void_type env.ctx) [| Llvm.i1_type env.ctx |] in
        (Llvm.declare_function "llvm.assume" t env.m, t)
  in
  assume_dereferenceable (Llvm.insertion_block b) assume_ty assume frame (Llvm.const_int i64 size)
    (Llvm.const_int i64 16);
  frame

(* A scope drains (L8). One that spawned nothing, has no dynamic chunk and
   holds no foreign handle, while its context is this thread's alone and
   drains are not checked, has nothing to wait for, end or give back but its
   frame, so the code moves the frontier back to its record itself.
   Otherwise the runtime drains it. Only a scope that spawns a call can have
   one to wait for, and only one that places a slot holding a handle can
   hold one, so no other scope checks. *)
let drain_scope env fr b m =
  let ptr = env.ptr in
  let null = Llvm.const_null ptr in
  let innermost =
    Llvm.build_icmp Llvm.Icmp.Eq (List_handle.aligned env.ctx 8 (Llvm.build_load ptr (open_scope env) "" b)) m "" b
  in
  let look = block env fr and inline = block env fr and runtime_ = block env fr and drained = block env fr in
  ignore (Llvm.build_cond_br innermost look runtime_ b);
  Llvm.position_at_end look b;
  let empty p = Llvm.build_icmp Llvm.Icmp.Eq p null "" b in
  let unchecked =
    Llvm.build_icmp Llvm.Icmp.Eq
      (Llvm.build_load (Llvm.i32_type env.ctx) (checking env) "" b)
      (Llvm.const_int (Llvm.i32_type env.ctx) 0)
      "" b
  in
  let alone = empty (field env b ptr m record_mappings) in
  let alone =
    if List.memq m fr.spawning then Llvm.build_and (empty (field env b ptr m record_tasks)) alone "" b else alone
  in
  let alone =
    if List.memq m fr.handled then Llvm.build_and alone (empty (field env b ptr m record_held)) "" b else alone
  in
  let plain = Llvm.build_and alone unchecked "" b in
  ignore (Llvm.build_cond_br plain inline runtime_ b);
  Llvm.position_at_end inline b;
  let c = field env b ptr m record_context in
  set_field env b m c context_frontier;
  let outer = field env b ptr m record_outer in
  set_field env b outer c context_top;
  ignore (Llvm.build_store outer (open_scope env) b);
  ignore (Llvm.build_br drained b);
  Llvm.position_at_end runtime_ b;
  ignore (call_runtime env b Cgt.Runtime.Scope_drain [| m |]);
  ignore (Llvm.build_br drained b);
  Llvm.position_at_end drained b

(* Drain the arenas opened since [depth] were open, innermost first: what a
   way out of them does before it jumps. *)
let drain env fr b depth =
  List.iteri (fun i arena -> if i < List.length fr.open_ - depth then drain_scope env fr b arena) fr.open_

(* A slot in its scope's frame, where Frames put it. *)
let frame_slot env fr b scope id =
  byte_at env b (Hashtbl.find fr.arenas scope) (Hashtbl.find fr.offsets id)

(* With checked drains, a slot whose value may own blocks is listed as its
   value arrives, so the drain can return them (runtime/slot.c). One whose
   value may hold a foreign handle is listed whether or not drains are
   checked, so the drain ends the handle (docs/design/ffi.md F12). *)
let hold env fr b slot l =
  if Walks.holds_handle (walks env) l then
    ignore (call_runtime env b Cgt.Runtime.Hold [| slot; layout env l |])
  else if listed env l then begin
    let on =
      Llvm.build_icmp Llvm.Icmp.Ne
        (Llvm.build_load (Llvm.i32_type env.ctx) (checking env) "" b)
        (Llvm.const_int (Llvm.i32_type env.ctx) 0)
        "" b
    in
    let listing = block env fr and after = block env fr in
    unlikely env (Llvm.build_cond_br on listing after b);
    Llvm.position_at_end listing b;
    ignore (call_runtime env b Cgt.Runtime.Hold [| slot; layout env l |]);
    ignore (Llvm.build_br after b);
    Llvm.position_at_end after b
  end

(* Every local is a stack slot in the entry block (L3); LLVM's `mem2reg`
   promotes the ones that can live in registers. *)
let alloca env fr t =
  let top = Llvm.builder_at env.ctx (Llvm.instr_begin (Llvm.entry_block fr.fn)) in
  Llvm.build_alloca t "" top

let slot env fr id t =
  let s = alloca env fr t in
  Hashtbl.replace fr.locals id (s, t);
  s

(* A value of type [t] moved into a fresh place: stored, tagged as [access]
   tags it, and the blocks it owns that the place's region outlives move
   into it (memory.md §3.5). *)
let place env b t p v l =
  (match t with
  (* Experimental (Loop_pushes, unless ZANE_LOOP_PUSHES=0): a struct of scalars is stored member
     by member, each tagged as a scalar, so that LLVM knows the stores never
     touch a list's handle and can keep its count in a register through a
     loop of pushes. *)
  | (Ty.Struct ts | Ty.Packed (Ty.Struct ts))
    when Sys.getenv_opt "ZANE_LOOP_PUSHES" <> Some "0"
         && List.for_all (function Ty.I1 | Ty.I8 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true | _ -> false) ts ->
      let name = match t with Ty.Packed _ -> unaligned_name | _ -> "" in
      List.iteri
        (fun i m ->
          let at = Llvm.build_struct_gep (lltype env t) p i name b in
          ignore (access env m (Llvm.build_store (Llvm.build_extractvalue v i "" b) at b)))
        ts
  | _ -> ignore (access env t (Llvm.build_store v p b)));
  if listed env l then ignore (call_runtime env b Cgt.Runtime.Arrive [| p; layout env l |])

(* A value stored where its address can be passed. *)
let spill env fr b v =
  let p = alloca env fr (Llvm.type_of v) in
  ignore (Llvm.build_store v p b);
  p

(* A struct value stored into the slot at [p] member by member, so the
   bytes between its members keep what the slot held. *)
let rec store_fields env b (t : Ty.t) v p =
  match t with
  | Ty.Struct ts ->
      let st = lltype env t in
      List.iteri
        (fun i m ->
          if m <> Ty.Void then
            store_fields env b m (Llvm.build_extractvalue v i "" b) (Llvm.build_struct_gep st p i "" b))
        ts
  | _ -> ignore (Llvm.build_store v p b)

let has_terminator b =
  match Llvm.block_terminator (Llvm.insertion_block b) with Some _ -> true | None -> false

(* How a snapshot of a value of type [t] is read (§9). An 8-byte value
   aligned to 8 is one load: a write-back stores those 8 bytes in a single
   store of the same 8 bytes (runtime/snapshot.c), since its pieces are
   aligned blocks of at most 8 and no smaller place lies inside such a value
   for a write-back to target, so the load is the snapshot. A narrower value
   can sit inside a wider piece a write-back stores whole, an access of
   another size that LLVM gives no atomicity with it, so it is read by the
   runtime. A value that holds an address,
   such as a box's, is read with acquire ordering, so what the address names,
   written before the write-back's release fence published it, is seen with
   it; one that holds none needs only `unordered`, which LLVM moves and
   merges like a plain load. A wider value is read by the runtime,
   which retries a torn read and fences the same way. *)
let snapshot_read t =
  let rec names_block = function
    | Ty.Ptr | Ty.Ref | Ty.Box32 | Ty.Handle | Ty.Handle16 -> true
    | Ty.Struct ts | Ty.Sum ts -> List.exists names_block ts
    | Ty.Array (t, _) | Ty.Packed t -> names_block t
    | Ty.Void | Ty.I1 | Ty.I8 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> false
  in
  if size_align t <> (8, 8) then `Runtime
  else if names_block t then `Acquire
  else `Unordered
