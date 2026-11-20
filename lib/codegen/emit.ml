(* The CGT as an LLVM module (docs/design/lowering.md L1, L2). Every CGT
   function is one LLVM function and every CGT type one LLVM type; nothing
   is decided here that the tree does not already give.

   This file is the walk over expressions and statements. What the walk
   builds with comes before it, in parts this file includes: Emit_types
   (LLVM types and how values cross calls), Emit_runtime (runtime calls,
   alias tags, math), Emit_frames (frames, scopes and slots) and Emit_lists
   (locating, pushing and removing elements). *)

open Cgt.Nodes
open Loop_shapes
open Call_pieces
open Llvm_extra
include Emit_types
include Loop_copies
include Emit_runtime
include Emit_frames
include Emit_lists

(* ---------------------------------------------------------------------- *)
(* Arithmetic                                                             *)
(* ---------------------------------------------------------------------- *)

(* LLVM leaves an integer division by zero undefined, and the one quotient an
   integer cannot hold too. The first gives zero and the second wraps, as `+`
   and `*` do (operators.md §2.6). Both divisors, 0 and -1, are the two that
   `r + 1` takes below 2 unsigned, and they branch away to an unlikely block,
   so the [sdiv] sees neither and starts without waiting on the test. *)
let divide env fr b l r =
  let t = Llvm.type_of l in
  let zero = Llvm.const_int t 0 and one = Llvm.const_int t 1 in
  let special = block env fr and ordinary = block env fr and joined = block env fr in
  let exceptional = Llvm.build_icmp Llvm.Icmp.Ult (Llvm.build_add r one "" b) (Llvm.const_int t 2) "" b in
  unlikely env (Llvm.build_cond_br exceptional special ordinary b);
  Llvm.position_at_end ordinary b;
  let quotient = Llvm.build_sdiv l r "" b in
  ignore (Llvm.build_br joined b);
  Llvm.position_at_end special b;
  let by_zero = Llvm.build_icmp Llvm.Icmp.Eq r zero "" b in
  let replaced = Llvm.build_select by_zero zero (Llvm.build_sub zero l "" b) "" b in
  ignore (Llvm.build_br joined b);
  Llvm.position_at_end joined b;
  Llvm.build_phi [ (quotient, ordinary); (replaced, special) ] "" b

(* A scalar converted from [from] to [into] (Cgt.Nodes.Scalar). A float
   truncated to an integer saturates (types.md §2.9): a NaN gives zero, and
   one whose integer part the target cannot hold gives the target's nearest
   end. That is what LLVM's `llvm.fptosi.sat` gives, so the target's own
   saturating conversion is what runs. *)
let convert env b (from : Ty.t) (into : Ty.t) v =
  let target = lltype env into in
  let is_float = function Ty.F32 | Ty.F64 -> true | _ -> false in
  match (from, into) with
  (* Experimental (Ref32): a box's block stored in 32 bits, and back. *)
  | Ty.Ptr, Ty.Ref -> List_handle.encode env.ctx b v
  | Ty.Ref, Ty.Ptr -> List_handle.decode env.ctx b v
  | Ty.Ptr, Ty.Box32 -> List_handle.encode_box env.ctx b v
  | Ty.Box32, Ty.Ptr -> List_handle.decode_box env.ctx b v
  | _ -> (
  match (is_float from, is_float into) with
  | false, false ->
      (* A byte is unsigned: it widens by zero-extension. *)
      if from = Ty.I8 && Scalar.bits from < Scalar.bits into then Llvm.build_zext v target "" b
      else if Scalar.bits from < Scalar.bits into then Llvm.build_sext v target "" b
      else if Scalar.bits from > Scalar.bits into then Llvm.build_trunc v target "" b
      else v
  | false, true -> Llvm.build_sitofp v target "" b
  | true, true -> (
      match (from, into) with
      | Ty.F32, Ty.F64 -> Llvm.build_fpext v target "" b
      | Ty.F64, Ty.F32 -> Llvm.build_fptrunc v target "" b
      | _ -> v)
  | true, false ->
      let suffix = function Ty.I32 -> "i32" | Ty.I64 -> "i64" | Ty.F32 -> "f32" | _ -> "f64" in
      let name = Printf.sprintf "llvm.fptosi.sat.%s.%s" (suffix into) (suffix from) in
      let fty = Llvm.function_type target [| Llvm.type_of v |] in
      let f =
        match Llvm.lookup_function name env.m with
        | Some f -> f
        | None -> Llvm.declare_function name fty env.m
      in
      Llvm.build_call fty f [| v |] "" b)

let binary env fr b (op : Expr.binop) (t : Ty.t) l r =
  match (t, op) with
  | (Ty.I64 | Ty.I32), Expr.Add -> Llvm.build_add l r "" b
  | (Ty.I64 | Ty.I32), Expr.Mul -> Llvm.build_mul l r "" b
  | (Ty.I64 | Ty.I32), Expr.Div -> divide env fr b l r
  | (Ty.I64 | Ty.I32 | Ty.I8 | Ty.I1), Expr.Eq -> Llvm.build_icmp Llvm.Icmp.Eq l r "" b
  | Ty.I8, Expr.Less -> Llvm.build_icmp Llvm.Icmp.Ult l r "" b
  | (Ty.I64 | Ty.I32), Expr.Less -> Llvm.build_icmp Llvm.Icmp.Slt l r "" b
  | (Ty.F64 | Ty.F32), Expr.Add -> Llvm.build_fadd l r "" b
  | (Ty.F64 | Ty.F32), Expr.Mul -> Llvm.build_fmul l r "" b
  | (Ty.F64 | Ty.F32), Expr.Div -> Llvm.build_fdiv l r "" b
  | (Ty.F64 | Ty.F32), Expr.Eq -> Llvm.build_fcmp Llvm.Fcmp.Oeq l r "" b
  | (Ty.F64 | Ty.F32), Expr.Less -> Llvm.build_fcmp Llvm.Fcmp.Olt l r "" b
  | Ty.I1, Expr.Add -> Llvm.build_or l r "" b
  | Ty.I1, Expr.Mul -> Llvm.build_and l r "" b
  | _ ->
      Diagnostic.bug
        (Printf.sprintf "codegen: no `%s` on %s" (Expr.binop_to_string op) (Ty.to_string t))

(* ---------------------------------------------------------------------- *)
(* Expressions and statements                                             *)
(* ---------------------------------------------------------------------- *)

(* LLVM's `llvm.prefetch`: an address, whether for a write, how long to
   keep the line (3, in every cache) and whether it holds data (1). *)
let prefetch_intrinsic env =
  let fty = Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; Llvm.i32_type env.ctx; Llvm.i32_type env.ctx; Llvm.i32_type env.ctx |] in
  match Llvm.lookup_function "llvm.prefetch.p0" env.m with
  | Some f -> (f, fty)
  | None -> (Llvm.declare_function "llvm.prefetch.p0" fty env.m, fty)

(* An expression that has a value: anything but a [Void] one, which lowering
   never puts where a value is used. *)
let rec value_of env fr b (e : Expr.t) : Llvm.llvalue =
  match expr env fr b e with
  | Some v -> v
  | None ->
      Diagnostic.bug
        (Printf.sprintf "codegen: a %s of type %s has no value" (Expr.kind e.Expr.node)
           (Ty.to_string e.Expr.ty))

and expr env fr b (e : Expr.t) : Llvm.llvalue option =
  match e.Expr.node with
  | Expr.Int i -> Some (Llvm.const_of_int64 (lltype env e.Expr.ty) i true)
  | Expr.Offset { base; within; path } ->
      let base = value_of env fr b base in
      (* A place inside a packed type may be at any byte: its address is
         named so that `unaligned` marks what reads and writes it. *)
      let gep t p i =
        let packed = (match t with Ty.Packed _ -> true | _ -> false) || is_unaligned p in
        Llvm.build_struct_gep (lltype env t) p i (if packed then unaligned_name else "") b
      in
      let at, _ =
        List.fold_left
          (fun (p, t) i ->
            match t with
            | Ty.Struct ts | Ty.Packed (Ty.Struct ts) -> (gep t p i, List.nth ts i)
            (* A sum's payload room holds case [i]'s payload. *)
            | (Ty.Sum ts | Ty.Packed (Ty.Sum ts)) when List.nth ts i = Ty.Void -> (p, Ty.Void)
            | Ty.Sum ts when Option.is_some (Ty.byte_niche ts) -> (p, List.nth ts i)
            | Ty.Sum ts when Ty.niche ts -> (gep t p 0, List.nth ts i)
            | Ty.Sum ts | Ty.Packed (Ty.Sum ts) -> (gep t p 1, List.nth ts i)
            | _ -> Diagnostic.bug "codegen: an offset through something not a struct")
          (base, within) path
      in
      Some at
  | Expr.Take { address; layout = l } -> (
      let p = value_of env fr b address in
      match e.Expr.ty with
      | Ty.Void -> None
      | t ->
          let v = Llvm.build_load (lltype env t) p "" b in
          Option.iter
            (fun f ->
              ignore
                (Llvm.build_call
                   (Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr |])
                   f [| p |] "" b))
            (Walks.vacater (walks env) l);
          Some v)
  | Expr.Copy { value; layout = l } ->
      Option.map
        (fun v ->
          let p = spill env fr b v in
          if listed env l then ignore (call_runtime env b Cgt.Runtime.Copy [| p; layout env l |]);
          Llvm.build_load (Llvm.type_of v) p "" b)
        (expr env fr b value)
  (* A box and a hold are made in the innermost region, which every block
     the value they take owns already outlives: it was made in this scope or
     an enclosing one, or lent by the call that spawned this context, which
     waits for it. So nothing arrives (memory.md §3.5). *)
  | Expr.Box { value; _ } ->
      let size, align = size_align value.Expr.ty in
      let block = Walks.box (walks env).Walks.emitting fr.fn b size align in
      Option.iter (fun v -> ignore (Llvm.build_store v block b)) (expr env fr b value);
      Some block
  | Expr.Layout l -> Some (layout env l)
  | Expr.Function fn -> Some (fst (Hashtbl.find env.funcs fn))
  | Expr.Global g -> Some (Hashtbl.find env.globals g)
  | Expr.Snapshot p -> (
      let p = value_of env fr b p in
      match e.Expr.ty with
      | Ty.Void -> None
      | t ->
          let lt = lltype env t in
          let out = alloca env fr lt in
          let size = fst (size_align t) in
          (* A place inside a packed type may be at any byte, where a load
             is not atomic, so the runtime reads one not known to be
             aligned to its size (Alignment.known). *)
          let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout env.m) in
          let aligned = Alignment.known ~slots:false dl env.ctx 0 p >= size in
          (match if aligned then snapshot_read t else `Runtime with
          | (`Unordered | `Acquire) as order ->
              let word = Llvm.build_load (Llvm.integer_type env.ctx (8 * size)) p "" b in
              Llvm.set_alignment size word;
              set_ordering word (order = `Acquire);
              ignore (Llvm.build_store word out b)
          | `Runtime ->
              ignore
                (call_runtime env b Cgt.Runtime.Snapshot
                   [| out; p; Llvm.const_int env.i64 size |]));
          Some (Llvm.build_load lt out "" b))
  | Expr.Escape { value; layout = l; exit } -> (
      (* The arenas the exit drains are the innermost ones: all of the
         function's, or those opened since the expansion began. *)
      let kept = match exit with None -> 0 | Some label -> snd (Hashtbl.find fr.labels label) in
      let drained = List.filteri (fun i _ -> i < List.length fr.open_ - kept) fr.open_ in
      match (expr env fr b value, List.rev drained) with
      | Some v, outermost :: _ when listed env l ->
          let p = spill env fr b v in
          ignore (call_runtime env b Cgt.Runtime.Promote [| p; layout env l; outermost |]);
          Some (Llvm.build_load (Llvm.type_of v) p "" b)
      | v, _ -> v)
  | Expr.Float f -> Some (Llvm.const_float (lltype env e.Expr.ty) f)
  | Expr.Bool v -> Some (Llvm.const_int (Llvm.i1_type env.ctx) (if v then 1 else 0))
  | Expr.Text s -> Some (text env s)
  | Expr.Unit -> None
  | Expr.Local id ->
      Option.map (fun (slot, t) -> Llvm.build_load t slot "" b) (Hashtbl.find_opt fr.locals id)
  | Expr.Address id -> (
      match Hashtbl.find_opt fr.locals id with
      | Some (slot, _) -> Some slot
      | None -> Some (Llvm.const_null env.ptr))
  | Expr.Deref p -> (
      let p = expr env fr b p in
      match (e.Expr.ty, p) with
      | Ty.Void, _ | _, None -> None
      | t, Some p -> Some (access env t (Llvm.build_load (lltype env t) p "" b)))
  | Expr.Record members ->
      Some
        (List.fold_left
           (fun v (i, m) ->
             match expr env fr b m with Some x -> Llvm.build_insertvalue v x i "" b | None -> v)
           (Llvm.undef (lltype env e.Expr.ty))
           members)
  (* The count of a list the loop read before it ([invariant_lists]). *)
  | Expr.Member { value = { Expr.node = Expr.Local x | Expr.Deref { Expr.node = Expr.Address x; _ }; ty = Ty.Handle | Ty.Handle16 }; index = 1 }
    when List.mem_assoc { Expr.node = Expr.Address x; ty = Ty.Ptr } fr.hoisted ->
      let count = snd (List.assoc { Expr.node = Expr.Address x; ty = Ty.Ptr } fr.hoisted) in
      Some (if e.Expr.ty = Ty.I32 then Llvm.build_trunc count (Llvm.i32_type env.ctx) "" b else count)
  (* Not one through an element, whose own read checks its index. *)
  | Expr.Member { value = { Expr.node = Expr.Deref a; ty = Ty.Handle | Ty.Handle16 }; index = 1 }
    when List.mem_assoc a fr.hoisted && not (Loop_shapes.through_element a) ->
      let count = snd (List.assoc a fr.hoisted) in
      Some (if e.Expr.ty = Ty.I32 then Llvm.build_trunc count (Llvm.i32_type env.ctx) "" b else count)
  | Expr.Member { value; index } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | _, Some v -> Some (Llvm.build_extractvalue v index "" b))
  | Expr.Case { index; payload } when (match e.Expr.ty with Ty.Sum ts -> Option.is_some (Ty.byte_niche ts) | _ -> false) -> (
      let ts = match e.Expr.ty with Ty.Sum ts -> ts | _ -> [] in
      let n = Option.get (Ty.byte_niche ts) in
      let t = lltype env e.Expr.ty in
      let tmp = alloca env fr t in
      if index = n.case then (
        (* The payload's bytes are the sum's. *)
        match expr env fr b payload with
        | Some p ->
            ignore (Llvm.build_store p tmp b);
            (* An [i1] stored leaves its byte's other bits unspecified, so
               the spare [Bool] is stored again as the byte a test reads. *)
            Option.iter
              (fun path ->
                let bool = List.fold_left (fun v i -> Llvm.build_extractvalue v i "" b) p path in
                let byte = Llvm.build_zext bool (Llvm.i8_type env.ctx) "" b in
                ignore (Llvm.build_store byte (byte_at env b tmp n.at) b))
              n.path;
            Some (Llvm.build_load t tmp "" b)
        | None -> None)
      else begin
        (* Another case is the value its rank among them names, at the
           spare byte, the payload's other bytes zero. *)
        let rank = if index < n.case then index else index - 1 in
        ignore (Llvm.build_store (Llvm.const_null t) tmp b);
        let i8 = Llvm.i8_type env.ctx in
        ignore (Llvm.build_store (Llvm.const_int i8 (n.first + rank)) (byte_at env b tmp n.at) b);
        Some (Llvm.build_load t tmp "" b)
      end)
  | Expr.Case { index; payload } when (match e.Expr.ty with Ty.Sum ts -> Ty.niche ts | _ -> false) ->
      let t = lltype env e.Expr.ty in
      let word =
        match (index, expr env fr b payload) with
        | 0, _ | _, None -> Llvm.const_int (Llvm.i32_type env.ctx) 0
        | _, Some p -> p
      in
      Some (Llvm.build_insertvalue (Llvm.undef t) word 0 "" b)
  | Expr.Case { index; payload } ->
      let t = lltype env e.Expr.ty in
      let packed = match e.Expr.ty with Ty.Packed _ -> true | _ -> false in
      let tmp = alloca env fr t in
      let tag = Llvm.build_struct_gep t tmp 0 "" b in
      let tag_type = if packed then Llvm.i8_type env.ctx else Llvm.i32_type env.ctx in
      ignore (Llvm.build_store (Llvm.const_int tag_type index) tag b);
      (match expr env fr b payload with
      | Some p ->
          let at = Llvm.build_struct_gep t tmp 1 (if packed then unaligned_name else "") b in
          ignore (Llvm.build_store p at b)
      | None -> ());
      Some (Llvm.build_load t tmp "" b)
  | Expr.Payload { value; _ } when (match value.Expr.ty with Ty.Sum ts -> Option.is_some (Ty.byte_niche ts) | _ -> false) -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | t, Some v ->
          let tmp = alloca env fr (Llvm.type_of v) in
          ignore (Llvm.build_store v tmp b);
          Some (Llvm.build_load (lltype env t) tmp "" b))
  | Expr.Payload { value; _ } when (match value.Expr.ty with Ty.Sum ts -> Ty.niche ts | _ -> false) -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | _, Some v -> Some (Llvm.build_extractvalue v 0 "" b))
  | Expr.Payload { value; _ } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | t, Some v ->
          let sum = Llvm.type_of v in
          let tmp = alloca env fr sum in
          ignore (Llvm.build_store v tmp b);
          let name = if Llvm.is_packed sum then unaligned_name else "" in
          Some (Llvm.build_load (lltype env t) (Llvm.build_struct_gep sum tmp 1 name b) "" b))
  | Expr.Call _ | Expr.Call_value _ -> (
      match call env fr b e with
      | `Value v -> Some v
      | `Stored p -> Some (Llvm.build_load (lltype env e.Expr.ty) p "" b)
      | `Nothing -> None)
  | Expr.Runtime { fn = Cgt.Runtime.Prefetch; args = [ list; { Expr.node = Expr.Local i; ty }; { Expr.node = Expr.Int stride; _ } ] } ->
      prefetch env fr b [ { Lookahead.list; index = Lookahead.Read (i, ty); stride = Int64.to_int stride } ];
      None
  | Expr.Runtime { fn = (Cgt.Runtime.List_at | Cgt.Runtime.Array_at) as fn; args } ->
      let cached =
        match (fn, args) with
        | Cgt.Runtime.List_at, l :: _ when fr.hoisted <> [] ->
            (* The address as [invariant_lists] named it: each local the
               loop's body binds to part of it replaced by what it names. *)
            let rec key (e : Expr.t) =
              match e.Expr.node with
              | Expr.Local x -> Option.value ~default:e (Hashtbl.find_opt fr.names x)
              | Expr.Offset o -> { e with Expr.node = Expr.Offset { o with base = key o.base } }
              | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ list; index; stride ] } ->
                  { e with Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ key list; key index; stride ] } }
              | _ -> e
            in
            List.assoc_opt (key l) fr.hoisted
        | _ -> None
      in
      let unchecked = cached <> None && List.memq e fr.unchecked in
      Some (element ?cached ~unchecked env fr b fn (List.filter_map (expr env fr b) args))
  | Expr.Runtime { fn = (Cgt.Runtime.List_remove _ | Cgt.Runtime.List_swap_remove _) as fn; args } -> (
      match List.filter_map (expr env fr b) args with
      | [ list; index; stride ] ->
          remove env fr b fn list index stride;
          None
      | _ -> Diagnostic.bug "codegen: a removal with the wrong arguments")
  (* A new list is empty and owns no block (runtime/list.c). *)
  | Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] } -> Some (Llvm.const_null (lltype env e.Expr.ty))
  | Expr.Runtime { fn = Cgt.Runtime.List_push; args } -> (
      let run =
        match args with
        | { Expr.node = Expr.Address id; _ } :: _ -> Option.map (fun r -> (id, r)) (Hashtbl.find_opt fr.runs id)
        | _ -> None
      in
      match List.filter_map (expr env fr b) args with
      | [ list; stride ] -> (
          match run with
          | Some (id, Ahead n) ->
              Hashtbl.replace fr.runs id (Room (n - 1));
              Some (push env fr b ~ahead:n list stride)
          | Some (id, Room _) when Hashtbl.mem fr.kept id ->
              let items, counter = Hashtbl.find fr.kept id in
              let count = Llvm.build_load env.i64 counter "" b in
              let at = Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items [| Llvm.build_nsw_mul count stride "" b |] "" b in
              let next = Llvm.build_nsw_add count (Llvm.const_int env.i64 1) "" b in
              ignore (Llvm.build_store next counter b);
              let stored = if List_handle.on () then List_handle.narrow env.ctx b next else next in
              List_handle.set_count ~tag:(handle_field env) env.ctx b stored list;
              Some at
          | Some (id, Room n) ->
              if n = 1 then Hashtbl.remove fr.runs id else Hashtbl.replace fr.runs id (Room (n - 1));
              Some (push env fr b ~unchecked:true list stride)
          | None -> Some (push env fr b list stride))
      | _ -> Diagnostic.bug "codegen: a push with the wrong arguments")
  | Expr.Runtime
      {
        fn = Cgt.Runtime.Pool_push;
        args = { Expr.node = Expr.Local x; _ } :: node :: { Expr.node = Expr.Int size; _ } :: { Expr.node = Expr.Int n; _ } :: links;
      }
    when Pool_cache.held x ->
      let rec pairs k = function
        | o :: { Expr.node = Expr.Int l; _ } :: rest when k > 0 -> (value_of env fr b o, Int64.to_int l) :: pairs (k - 1) rest
        | _ -> []
      in
      let node = value_of env fr b node in
      let links = pairs (Int64.to_int n) links in
      Some (Pool_cache.push env.ctx env.m b (Option.get !Pool_cache.current) node (Int64.to_int size) links)
  | Expr.Runtime { fn = Cgt.Runtime.Pool_new; args = [ out ] } when Pool_cache.unchecked () ->
      Pool_cache.fresh env.ctx env.m b (value_of env fr b out);
      None
  | Expr.Runtime { fn; args = given } -> (
      let f, fty = runtime env fn in
      let args = given in
      let args =
        List.filter_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env fr b a) with
            | (Ty.Handle | Ty.Handle16), Some v -> Some (spill env fr b v)
            | _, v -> v)
          args
      in
      Pool_cache.around env.ctx b given (fun () ->
          match e.Expr.ty with
          | Ty.Void ->
              ignore (Llvm.build_call fty f (Array.of_list args) "" b);
              None
          | (Ty.Handle | Ty.Handle16) as h ->
              let t = lltype env h in
              let out = alloca env fr t in
              ignore (Llvm.build_call fty f (Array.of_list (out :: args)) "" b);
              Some (Llvm.build_load t out "" b)
          | _ -> Some (Llvm.build_call fty f (Array.of_list args) "" b)))
  | Expr.Foreign_call { thunk; args } -> foreign_call env fr b thunk args e.Expr.ty
  | Expr.Math { fn; args } ->
      (* The operands' instructions come in the order they are listed. *)
      let args = List.map (value_of env fr b) args in
      Some (math env b fn e.Expr.ty args)
  | Expr.Binary { op; left; right } -> (
      (* The left operand's instructions come first. *)
      let l = expr env fr b left in
      match (l, expr env fr b right) with
      | Some l, Some r -> Some (binary env fr b op left.Expr.ty l r)
      | _ -> Diagnostic.bug "codegen: an operand has no value")
  | Expr.Flip value -> (
      match (value.Expr.ty, expr env fr b value) with
      | (Ty.I64 | Ty.I32), Some v -> Some (Llvm.build_neg v "" b)
      | (Ty.F64 | Ty.F32), Some v -> Some (Llvm.build_fneg v "" b)
      | Ty.I1, Some v -> Some (Llvm.build_not v "" b)
      | _ -> Diagnostic.bug "codegen: `~` on a value it does not flip")
  (* A 32-bit handle's count or room is never negative, so it widens with
     zeros, as List_handle reads it everywhere else: the same widening of the
     same load, so LLVM sees a loop's bound and an index's check compare
     with one value. *)
  | Expr.Convert ({ Expr.node = Expr.Member { value = { Expr.ty = Ty.Handle16; _ }; index = 1 | 2 }; _ } as value)
    when e.Expr.ty = Ty.I64 -> (
      match expr env fr b value with
      | Some v -> Some (Llvm.build_zext v env.i64 "" b)
      | None -> Diagnostic.bug "codegen: a conversion of no value")
  | Expr.Convert value -> (
      match expr env fr b value with
      | Some v -> Some (convert env b value.Expr.ty e.Expr.ty v)
      | None -> Diagnostic.bug "codegen: a conversion of no value")
  | Expr.Expand { label; body; result } ->
      Option.iter (fun id -> ignore (slot env fr id (lltype env e.Expr.ty))) result;
      let exit = block env fr in
      Hashtbl.replace fr.labels label (exit, List.length fr.open_);
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br exit b);
      Llvm.position_at_end exit b;
      Option.bind result (fun id -> expr env fr b { Expr.node = Expr.Local id; ty = e.Expr.ty })

(* A call (docs/design/lowering.md §9). Each argument passes as its type
   says: as itself; as words, through a slot of words; or by address, a
   place's own and a fresh slot of this frame for any other value. The
   arguments run in order first. A result that comes back by address is
   written to [into], a fresh slot the caller names, or to one made here;
   one that comes back as words is put back together in a slot. *)
and call ?into env fr b (e : Expr.t) =
  let f, fty, a, args =
    match e.Expr.node with
    | Expr.Call { fn; args } ->
        let f, fty = Hashtbl.find env.funcs fn in
        (f, fty, Hashtbl.find env.abis fn, args)
    | Expr.Call_value { fn; args } ->
        (* The function's type is its arguments' and its result's, which the
           tree gives, as for a direct call. *)
        let f = value_of env fr b fn in
        let a = abi env (List.map (fun (a : Expr.t) -> a.Expr.ty) args) e.Expr.ty in
        (f, abi_type env a, a, args)
    | _ -> Diagnostic.bug "codegen: a call that is not one"
  in
  let rec pass passings (args : Expr.t list) =
    match (args, passings) with
    | [], [] -> []
    | (arg : Expr.t) :: rest, _ when arg.Expr.ty = Ty.Void ->
        ignore (expr env fr b arg);
        pass passings rest
    | arg :: rest, (_, p) :: passings ->
        let passed =
          match p with
          | Itself -> [ value_of env fr b arg ]
          | Address -> [ in_memory env fr b arg ]
          | Words n -> to_words env fr b n (value_of env fr b arg)
        in
        passed @ pass passings rest
    | _ -> Diagnostic.bug "codegen: a call whose arguments do not match its signature"
  in
  let ret, ret_passing = a.ret in
  let dest =
    match ret_passing with
    | Address -> Some (match into with Some p -> p | None -> alloca env fr (lltype env ret))
    | Itself | Words _ -> None
  in
  let given = args in
  let args = pass a.params args in
  let site =
    Pool_cache.around env.ctx b given (fun () -> Llvm.build_call fty f (Array.of_list (Option.to_list dest @ args)) "" b)
  in
  List.iter
    (fun (i, attrs) -> List.iter (fun at -> Llvm.add_call_site_attr site at (Llvm.AttrIndex.Param i)) attrs)
    (abi_attrs env a);
  match (ret_passing, dest) with
  | _ when ret = Ty.Void -> `Nothing
  | Address, Some p -> `Stored p
  | Words n, _ ->
      let slot = alloca env fr (Llvm.array_type env.i64 n) in
      ignore (Llvm.build_store site slot b);
      `Stored slot
  | _ -> `Value site

(* A call into C through a thunk of the glue (docs/design/ffi.md F8, F10):
   the arguments run in order, each is stored in a slot of its own as C lays
   out its type, a struct's padding zeroed and a `Bool` a byte, and the
   thunk is handed an array of the slots' addresses and a zeroed slot for
   the result, from which the result is read back. A function value is
   handed over as its lambda's C entry, read from the constant whose offset
   from the lambda's code the 32 bits before it hold (docs/design/ffi.md
   F11). *)
and foreign_call env fr b thunk (args : Expr.t list) (ret : Ty.t) =
  let i8 = Llvm.i8_type env.ctx in
  let functions = Option.value ~default:[] (Hashtbl.find_opt env.entries thunk) in
  let entry v =
    let i32 = Llvm.i32_type env.ctx in
    let at = Llvm.build_gep i8 v [| Llvm.const_int env.i64 (-4) |] "" b in
    let offset = Llvm.build_load i32 at "" b in
    Llvm.set_alignment 4 offset;
    Llvm.build_load env.ptr (Llvm.build_gep i8 v [| Llvm.build_sext offset env.i64 "" b |] "" b) "" b
  in
  let slot_of i (a : Expr.t) =
    let v = value_of env fr b a in
    let v = if List.nth_opt functions i = Some true then entry v else v in
    match a.Expr.ty with
    | Ty.I1 -> spill env fr b (Llvm.build_zext v i8 "" b)
    (* A 16-byte list handle's count is 32 bits; the `zane_span` C reads
       holds it in a `size_t`. *)
    | Ty.Handle16 when List_handle.on () ->
        let h = spill env fr b v in
        let span = Llvm.struct_type env.ctx [| env.ptr; env.i64 |] in
        let p = alloca env fr span in
        ignore (Llvm.build_store (List_handle.items env.ctx b h) (Llvm.build_struct_gep span p 0 "" b) b);
        ignore (Llvm.build_store (List_handle.count env.ctx b h) (Llvm.build_struct_gep span p 1 "" b) b);
        p
    | Ty.Struct _ as t ->
        let p = alloca env fr (lltype env t) in
        zero env b p (fst (size_align t));
        store_fields env b t v p;
        p
    | _ -> spill env fr b v
  in
  let slots = List.mapi slot_of args in
  let table_type = Llvm.array_type env.ptr (max 1 (List.length slots)) in
  let table = alloca env fr table_type in
  List.iteri
    (fun i s ->
      let at = Llvm.build_in_bounds_gep table_type table [| Llvm.const_int env.i64 0; Llvm.const_int env.i64 i |] "" b in
      ignore (Llvm.build_store s at b))
    slots;
  let result_type = match ret with Ty.I1 -> i8 | t -> lltype env t in
  let result =
    match ret with
    | Ty.Void -> Llvm.const_null env.ptr
    | _ ->
        let p = alloca env fr result_type in
        zero env b p (match ret with Ty.I1 -> 1 | t -> fst (size_align t));
        p
  in
  ignore (Llvm.build_call (Walks.thunk_type env.ctx) (Walks.thunk env.ctx env.m thunk) [| table; result |] "" b);
  match ret with
  | Ty.Void -> None
  | Ty.I1 -> Some (Llvm.build_icmp Llvm.Icmp.Ne (Llvm.build_load i8 result "" b) (Llvm.const_int i8 0) "" b)
  | _ -> Some (Llvm.build_load result_type result "" b)

(* The address of a slot holding [e]'s value, for a parameter passed by
   address. A place is lent in place: nothing else in the call writes it
   (memory.md §2.9.1). A call that returns by address writes its result
   straight into a fresh slot, and an expansion's result is its own slot.
   Any other value is stored in a fresh slot of this frame first. *)
and in_memory env fr b (e : Expr.t) =
  match e.Expr.node with
  | Expr.Local id when Hashtbl.mem fr.locals id -> fst (Hashtbl.find fr.locals id)
  | Expr.Deref p -> value_of env fr b p
  | (Expr.Call _ | Expr.Call_value _) when returning env e.Expr.ty = Address -> (
      match call env fr b e with
      | `Stored p -> p
      | _ -> Diagnostic.bug "codegen: a result passed by address came back otherwise")
  | Expr.Expand { result = Some id; _ } -> (
      ignore (expr env fr b e);
      match Hashtbl.find_opt fr.locals id with
      | Some (slot, _) -> slot
      | None -> Diagnostic.bug "codegen: an expansion's result has no slot")
  | _ -> spill env fr b (value_of env fr b e)

(* A value as [n] words, through a slot of words it is stored in. *)
and to_words env fr b n v =
  let slot = alloca env fr (Llvm.array_type env.i64 n) in
  ignore (Llvm.build_store v slot b);
  List.init n (fun i ->
      Llvm.build_load env.i64 (Llvm.build_in_bounds_gep env.i64 slot [| Llvm.const_int env.i64 i |] "" b) "" b)

(* [v] split into [n] words, and packed into one value of the [n]-word type
   when there is more than one. *)
and packed_words env fr b n v =
  let words = to_words env fr b n v in
  if n = 1 then List.hd words
  else
    List.fold_left
      (fun (acc, i) w -> (Llvm.build_insertvalue acc w i "" b, i + 1))
      (Llvm.undef (words_type env n), 0)
      words
    |> fst

and stats env fr b body =
  List.iter (fun (id, n) -> Hashtbl.replace fr.runs id (Ahead n)) (runs body);
  List.iter (fun s -> if not (has_terminator b) then stat env fr b s) body

(* Experimental (Lookahead): a prefetch of each of [targets] at the top of
   a loop's body, for the iteration [Lookahead.distance] on. Each element
   read in a target's address is made only when its index is inside its
   list, compared unsigned as [element] compares one, and the prefetch of
   an address outside its list is skipped; a skipped one goes on with the
   body. Nothing here can stop the program. A list's items and count are
   the loop's hoisted ones when it has them, else read here afresh. *)
and prefetch env fr b (targets : Lookahead.target list) =
  let one = Llvm.const_int env.i64 1 in
  let handle key =
    match List.assoc_opt key fr.hoisted with
    | Some cached -> cached
    | None ->
        let list = value_of env fr b key in
        let tag = handle_field env and count_tag = if List_handle.on () then handle_field env else count_field env in
        (List_handle.items ~tag env.ctx b list, List_handle.count ~tag:count_tag env.ctx b list)
  in
  let skip = block env fr in
  (* The address [offset] bytes into the element at [index] of the list at
     [key], when the index is inside it; else on to [skip]. *)
  let inside key index stride offset =
    let items, count = handle key in
    let at = Llvm.build_sub index one "" b in
    let next = block env fr in
    ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ult at count "" b) next skip b);
    Llvm.position_at_end next b;
    let bytes = Llvm.build_add (Llvm.build_mul at (Llvm.const_int env.i64 stride) "" b) (Llvm.const_int env.i64 offset) "" b in
    Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items [| bytes |] "" b
  in
  let rec value (v : Lookahead.value) =
    match v with
    | Lookahead.Const (k, t) -> Llvm.const_of_int64 (lltype env t) k true
    | Read (x, t) -> value_of env fr b { Expr.node = Expr.Local x; ty = t }
    | Add (l, r) -> Llvm.build_add (value l) (value r) "" b
    | Mul (l, r) -> Llvm.build_mul (value l) (value r) "" b
    | Neg v -> Llvm.build_neg (value v) "" b
    | Math (fn, t, args) -> math env b fn t (List.map value args)
    | Convert (v, t) ->
        let x = value v in
        let to_ = lltype env t in
        let width ty = Llvm.integer_bitwidth ty in
        if width (Llvm.type_of x) < width to_ then Llvm.build_sext x to_ "" b
        else if width (Llvm.type_of x) > width to_ then Llvm.build_trunc x to_ "" b
        else x
    | Load { list; index; stride; offset; ty } ->
        let index = value index in
        (* Packed elements put a member at any byte (lowering.md L5). *)
        let load = Llvm.build_load (lltype env ty) (inside list index stride offset) "" b in
        Llvm.set_alignment 1 load;
        load
  in
  let fetch = prefetch_intrinsic env in
  List.iter
    (fun (t : Lookahead.target) ->
      let index = value t.index in
      let address = inside t.list index t.stride 0 in
      let i32 = Llvm.const_int (Llvm.i32_type env.ctx) in
      ignore (Llvm.build_call (snd fetch) (fst fetch) [| address; i32 0; i32 3; i32 1 |] "" b))
    targets;
  ignore (Llvm.build_br skip b);
  Llvm.position_at_end skip b

and stat env fr b (s : Stat.t) =
  match s with
  | Stat.Let { id; value = { Expr.node = Expr.Call _ | Expr.Call_value _; ty } as value }
    when returning env ty = Address ->
      ignore (call ~into:(slot env fr id (lltype env ty)) env fr b value)
  | Stat.Let { id; value } -> (
      match expr env fr b value with
      | Some v -> ignore (Llvm.build_store v (slot env fr id (Llvm.type_of v)) b)
      | None -> ())
  | Stat.Assign { place; value } -> (
      match (expr env fr b value, Hashtbl.find_opt fr.locals place.Expr.local) with
      | Some v, Some (slot, _) ->
          let base = if place.Expr.deref then Llvm.build_load env.ptr slot "" b else slot in
          let target, _ =
            List.fold_left
              (fun (p, t) i ->
                match t with
                | Ty.Struct ts -> (Llvm.build_struct_gep (lltype env t) p i (if is_unaligned p then unaligned_name else "") b, List.nth ts i)
                | Ty.Packed (Ty.Struct ts) -> (Llvm.build_struct_gep (lltype env t) p i unaligned_name b, List.nth ts i)
                | _ -> Diagnostic.bug "codegen: a member path through something not a struct")
              (base, place.Expr.ty) place.Expr.path
          in
          let store = Llvm.build_store v target b in
          (* A store into a local's own slot is the frame's. *)
          if place.Expr.deref || place.Expr.path <> [] then ignore (access env value.Expr.ty store)
      | _ -> ())
  | Stat.Switch { value; cases } ->
      let v = value_of env fr b value in
      let tag =
        match value.Expr.ty with
        | Ty.Sum ts when Option.is_some (Ty.byte_niche ts) ->
            (* The case a byte-niche sum holds: another case's when its spare
               byte holds one of their values, else the one with a payload. *)
            let n = Option.get (Ty.byte_niche ts) in
            let i32 = Llvm.i32_type env.ctx and i8 = Llvm.i8_type env.ctx in
            let tmp = alloca env fr (Llvm.type_of v) in
            ignore (Llvm.build_store v tmp b);
            let byte = Llvm.build_load i8 (byte_at env b tmp n.at) "" b in
            let rank = Llvm.build_zext (Llvm.build_sub byte (Llvm.const_int i8 n.first) "" b) i32 "" b in
            let other = Llvm.build_icmp Llvm.Icmp.Ult rank (Llvm.const_int i32 n.count) "" b in
            let past = Llvm.build_zext (Llvm.build_icmp Llvm.Icmp.Uge rank (Llvm.const_int i32 n.case) "" b) i32 "" b in
            Llvm.build_select other (Llvm.build_add rank past "" b) (Llvm.const_int i32 n.case) "" b
        | _ -> Llvm.build_extractvalue v 0 "" b
      in
      let tag =
        match value.Expr.ty with
        | Ty.Sum ts when Ty.niche ts ->
            Llvm.build_zext (Llvm.build_icmp Llvm.Icmp.Ne tag (Llvm.const_int (Llvm.i32_type env.ctx) 0) "" b) (Llvm.i32_type env.ctx) "" b
        | _ -> tag
      in
      let after = block env fr and otherwise = block env fr in
      let sw = Llvm.build_switch tag otherwise (List.length cases) b in
      List.iter
        (fun (i, body) ->
          let case = block env fr in
          Llvm.add_case sw (Llvm.const_int (Llvm.type_of tag) i) case;
          Llvm.position_at_end case b;
          stats env fr b body;
          if not (has_terminator b) then ignore (Llvm.build_br after b))
        cases;
      (* A tag is always one of the cases. *)
      Llvm.position_at_end otherwise b;
      ignore (Llvm.build_unreachable b);
      Llvm.position_at_end after b
  | Stat.Eval e -> ignore (expr env fr b e)
  | Stat.Return e -> (
      (* The value is read before its arenas are drained: a result passed
         by address is written to the caller's slot first, by a call
         straight into it when the value is one. *)
      let ret, ret_passing = fr.ret in
      let v =
        match (ret_passing, fr.sret, e.Expr.node) with
        | Address, Some dest, (Expr.Call _ | Expr.Call_value _) ->
            ignore (call ~into:dest env fr b e);
            None
        | Address, Some dest, _ ->
            Option.iter (fun v -> ignore (Llvm.build_store v dest b)) (expr env fr b e);
            None
        | Words n, _, _ -> Option.map (packed_words env fr b n) (expr env fr b e)
        | _ -> expr env fr b e
      in
      Option.iter (Pool_cache.flush env.ctx b) !Pool_cache.current;
      drain env fr b 0;
      match v with
      | Some v when ret <> Ty.Void -> ignore (Llvm.build_ret v b)
      | _ -> ignore (Llvm.build_ret_void b))
  | Stat.Scope { id; body } ->
      let frame = Frames.layout ~handles:(Walks.holds_handle (walks env)) fr.symbol id body in
      Hashtbl.iter (Hashtbl.replace fr.offsets) frame.Frames.offsets;
      if frame.Frames.size <= 4096 && light id body then begin
        let space = alloca env fr (Llvm.array_type (Llvm.i8_type env.ctx) frame.Frames.size) in
        Llvm.set_alignment 16 space;
        Hashtbl.replace fr.arenas id space;
        stats env fr b body
      end
      else
      let arena = enter env fr b frame.Frames.size in
      Hashtbl.replace fr.arenas id arena;
      Held_spills.entered arena
        (match Llvm.instr_end (Llvm.insertion_block b) with Llvm.After i -> Some i | Llvm.At_start _ -> None);
      let handled = fr.handled and spawning = fr.spawning in
      fr.open_ <- arena :: fr.open_;
      if frame.Frames.handles then fr.handled <- arena :: fr.handled;
      if frame.Frames.spawns then fr.spawning <- arena :: fr.spawning;
      stats env fr b body;
      if not (has_terminator b) then drain_scope env fr b arena;
      fr.open_ <- List.tl fr.open_;
      fr.handled <- handled;
      fr.spawning <- spawning
  | Stat.Hold { id; scope; value = { Expr.node = Expr.Call _ | Expr.Call_value _; ty } as value; layout = l }
    when returning env ty = Address ->
      let slot = held_slot env fr b scope id ~bytes:(fst (size_align ty)) ~layout:l (lltype env ty) in
      ignore (call ~into:slot env fr b value);
      hold env fr b slot l;
      Hashtbl.replace fr.locals id (slot, lltype env ty)
  | Stat.Hold { id; scope; value; layout = l } -> (
      match expr env fr b value with
      | None -> ()
      | Some v ->
          (* The slot is listed before it is written, since listing it only
             takes its address: the write is then the last LLVM sees before
             what follows, and it knows the value there, a new list's empty
             header included. A large value is written first, so its load
             and its store stay next to each other for Big_moves. *)
          let slot = held_slot env fr b scope id ~bytes:(fst (size_align value.Expr.ty)) ~layout:l (Llvm.type_of v) in
          if fst (size_align value.Expr.ty) >= large then begin
            ignore (Llvm.build_store v slot b);
            hold env fr b slot l
          end
          else begin
            hold env fr b slot l;
            ignore (Llvm.build_store v slot b)
          end;
          Hashtbl.replace fr.locals id (slot, Llvm.type_of v))
  | Stat.Reserve { id; scope; ty = t; layout = l } ->
      let slot = held_slot env fr b scope id ~bytes:(fst (size_align t)) ~layout:l (lltype env t) in
      hold env fr b slot l;
      zero env b slot (fst (size_align t));
      Hashtbl.replace fr.locals id (slot, lltype env t)
  | Stat.Place { address; value; layout = l } -> (
      let p = value_of env fr b address in
      match expr env fr b value with Some v -> place env b value.Expr.ty p v l | None -> ())
  | Stat.Store { address; value } -> (
      let p = value_of env fr b address in
      match expr env fr b value with
      | Some v -> ignore (access env value.Expr.ty (Llvm.build_store v p b))
      | None -> ())
  | Stat.Overwrite { address; value; layout = l; setters } -> (
      let p = value_of env fr b address in
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let incoming = spill env fr b v in
          let n x = Llvm.const_int env.i64 x in
          let size = n (fst (size_align value.Expr.ty)) in
          let fn =
            if setters then Cgt.Runtime.Overwrite_settled
            else if Walks.holds_handle (walks env) l then Cgt.Runtime.Overwrite_handles
            else Cgt.Runtime.Overwrite
          in
          ignore (call_runtime env b fn [| p; incoming; size; layout env l |]))
  | Stat.If { cond; body } ->
      let c = value_of env fr b cond in
      let taken = block env fr and after = block env fr in
      ignore (Llvm.build_cond_br c taken after b);
      Llvm.position_at_end taken b;
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br after b);
      Llvm.position_at_end after b
  | Stat.While { cond; body } ->
      (* A worker (control-flow.md §3.7): the condition, which calls the
         step, is read at the top of each pass, so a step that returns
         false leaves at once and the body runs only between steps. *)
      let top = block env fr and taken = block env fr and after = block env fr in
      ignore (Llvm.build_br top b);
      Llvm.position_at_end top b;
      let c = value_of env fr b cond in
      ignore (Llvm.build_cond_br c taken after b);
      Llvm.position_at_end taken b;
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br top b);
      Llvm.position_at_end after b
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = value_of env fr b count in
      let looped = looped_pushes body in
      List.iter
        (fun (id, stride) ->
          let list = value_of env fr b { Expr.node = Expr.Address id; ty = Ty.Ptr } in
          let tag = handle_field env in
          (* Making room keeps the count (runtime/list.c), so an optimized
             build reads it before, where LLVM knows it, as after a list is
             made, and keeps it in a local the loop's pushes step: the
             loop's checks make each push conditional, which keeps LICM
             from promoting the count itself. A plain build reads it again
             at each push. *)
          let short = match Llvm.int64_of_const n with Some c -> Int64.compare c 64L <= 0 | None -> false in
          let count = if env.version && not short then Some (List_handle.count ~tag env.ctx b list) else None in
          let f, fty = runtime env Cgt.Runtime.List_room in
          ignore (Llvm.build_call fty f [| list; Llvm.const_int env.i64 (Int64.to_int stride); n |] "" b);
          Hashtbl.replace fr.runs id (Room max_int);
          Option.iter
            (fun count ->
              let items = List_handle.items ~tag env.ctx b list in
              let counter = alloca env fr env.i64 in
              ignore (Llvm.build_store count counter b);
              Hashtbl.replace fr.kept id (items, counter))
            count)
        looped;
      Fun.protect ~finally:(fun () -> List.iter (fun (id, _) -> Hashtbl.remove fr.runs id; Hashtbl.remove fr.kept id) looped) @@ fun () ->
      let lists, names = invariant_lists ~own:fr.own body in
      let ranges = ranged body lists names in
      let twice = unrolled ~listed:(listed env) body in
      (* Experimental (Lookahead): what an optimized build fetches ahead. *)
      let fetched = if env.version then Lookahead.targets body names else [] in
      let counted ?(fetch = true) trips =
        let saved = fr.hoisted in
        let hoisted =
          List.fold_left
            (fun hoisted (a : Expr.t) ->
              let tag = handle_field env and count_tag = if List_handle.on () then handle_field env else count_field env in
              (* The address [a] names before the loop, never checked: an
                 element of a list read before the loop, at an index the
                 loop does not change, is the element when the index is in
                 range, else a zeroed one, whose every list's checks stop
                 the program where the element's own would; a member of an
                 element is the member of that. *)
              let rec address (a : Expr.t) =
                match a.Expr.node with
                | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ outer; index; ({ Expr.node = Expr.Int bytes; _ } as stride) ] } ->
                    let items, count =
                      (* This loop's lists, then an enclosing loop's. *)
                      match List.assoc_opt outer (hoisted @ saved) with
                      | Some c -> c
                      | None ->
                          let l = address outer in
                          (List_handle.items ~tag env.ctx b l, List_handle.count ~tag:count_tag env.ctx b l)
                    in
                    let index = value_of env fr b index and stride = value_of env fr b stride in
                    let offset = Llvm.build_sub index (Llvm.const_int env.i64 1) "" b in
                    let inside = Llvm.build_icmp Llvm.Icmp.Ult offset count "" b in
                    let room = Llvm.array_type env.i64 ((max (Int64.to_int bytes) 24 + 7) / 8) in
                    let empty = alloca env fr room in
                    ignore (Llvm.build_store (Llvm.const_null room) empty b);
                    let at = Llvm.build_gep (Llvm.i8_type env.ctx) items [| Llvm.build_mul offset stride "" b |] "" b in
                    Llvm.build_select inside at empty "" b
                | Expr.Offset ({ base; _ } as o) when Loop_shapes.through_element base ->
                    let p = address base in
                    let id = min_int + Hashtbl.length fr.locals in
                    let s = slot env fr id env.ptr in
                    ignore (Llvm.build_store p s b);
                    let v = value_of env fr b { a with Expr.node = Expr.Offset { o with base = { base with Expr.node = Expr.Local id } } } in
                    Hashtbl.remove fr.locals id;
                    v
                | _ -> value_of env fr b a
              in
              (* In an optimized build, a list an enclosing loop read before
                 it is that read, which lets LLVM see an inner loop's bound
                 and the count read before it are one value. Elsewhere,
                 holding it across the inner loops costs more than reading
                 it again (tests/perf entities, plain: +2.9%). *)
              match (if env.version then List.assoc_opt a saved else None) with
              | Some c -> hoisted @ [ (a, c) ]
              | None ->
                  let list = address a in
                  hoisted @ [ (a, (List_handle.items ~tag env.ctx b list, List_handle.count ~tag:count_tag env.ctx b list)) ])
            [] lists
        in
        fr.hoisted <- hoisted @ saved;
        Hashtbl.iter (Hashtbl.replace fr.names) names;
        let loop () =
        let i = alloca env fr env.i64 in
        ignore (Llvm.build_store (Llvm.const_int env.i64 0) i b);
        let head = block env fr and step = block env fr and after = block env fr in
        ignore (Llvm.build_br head b);
        Llvm.position_at_end head b;
        let current = Llvm.build_load env.i64 i "" b in
        let test = Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt current n "" b) step after b in
        Option.iter (weigh env test) trips;
        Llvm.position_at_end step b;
        if fetch && fetched <> [] then prefetch env fr b fetched;
        fr.loops <- fr.loops + 1;
        stats env fr b body;
        fr.loops <- fr.loops - 1;
        if not (has_terminator b) then begin
          let current = Llvm.build_load env.i64 i "" b in
          (* Below the count, so it cannot wrap. *)
          let next = Llvm.build_nsw_add current (Llvm.const_int env.i64 1) "" b in
          ignore (Llvm.build_store next i b);
          let back = Llvm.build_br head b in
          if twice then Llvm.set_metadata back (Llvm.mdkind_id env.ctx "llvm.loop") (unroll_twice env)
          else
            (* A loop of a constant count from 2 to [unrolled_whole] is
               unrolled whole, as C's `#pragma unroll` asks: LLVM's own
               threshold leaves a body with a branch in it, such as a
               Huffman decoder's leaf test, a loop. *)
            match Llvm.int64_of_const n with
            | Some c when Int64.compare c 2L >= 0 && Int64.compare c (Int64.of_int unrolled_whole) <= 0 ->
                Llvm.set_metadata back (Llvm.mdkind_id env.ctx "llvm.loop")
                  (Llvm_extra.loop_id env.ctx [| Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "llvm.loop.unroll.full" |] |])
            | _ -> ()
        end;
        Llvm.position_at_end after b
        in
        (if ranges = [] then loop ()
         else begin
           (* Each index's first and last value, one less than each compared
              unsigned with the list's count, as [element] checks one. *)
           let one = Llvm.const_int env.i64 1 in
           let last_pass = Llvm.build_sub n one "" b in
           let fits =
             List.fold_left
               (fun ok (_, key, a, first) ->
                 let count = snd (List.assoc key fr.hoisted) in
                 let first = Option.get (expr env fr b first) in
                 let last = Llvm.build_add first (Llvm.build_mul (Llvm.const_int env.i64 a) last_pass "" b) "" b in
                 let inside v = Llvm.build_icmp Llvm.Icmp.Ult (Llvm.build_sub v one "" b) count "" b in
                 Llvm.build_and ok (Llvm.build_and (inside first) (inside last) "" b) "" b)
               (Llvm.const_int (Llvm.i1_type env.ctx) 1)
               ranges
           in
           let fast = block env fr and slow = block env fr and joined = block env fr in
           ignore (Llvm.build_cond_br fits fast slow b);
           Llvm.position_at_end fast b;
           let outer = fr.unchecked in
           fr.unchecked <- List.map (fun (e, _, _, _) -> e) ranges @ outer;
           loop ();
           fr.unchecked <- outer;
           ignore (Llvm.build_br joined b);
           Llvm.position_at_end slow b;
           loop ();
           ignore (Llvm.build_br joined b);
           Llvm.position_at_end joined b
         end);
        fr.hoisted <- saved
      in
      (* A loop that can leave early is a search: its count is a ceiling
         it seldom reaches, so it is weighted as going round a few times,
         and IRCE leaves it whole (docs/design/lowering.md, "The passes"). *)
      if env.version && Loop_shapes.searches body then counted (Some short_trips)
      else if (not env.version) || fr.loops > 0 || not (versioned ~symbol:fr.symbol body) then counted None
      else begin
        (* A loop no other loop holds is emitted twice, for a count of at
           least [long_loop] and for a smaller one, each weighted by how often
           it goes round (docs/design/lowering.md, "The passes"). *)
        let long = block env fr and short = block env fr and joined = block env fr in
        let at_least = Llvm.build_icmp Llvm.Icmp.Sge n (Llvm.const_int env.i64 long_loop) "" b in
        (* Taking the long copy is weighted as rare, so the short copy is
           what falls through from the test; the long copy's own weights
           still make its body hot. Weighting it common, or not at all,
           costs langbench's `fannkuch` 1.5% more instructions. *)
        unlikely env (Llvm.build_cond_br at_least long short b);
        List.iter
          (fun (start, trips) ->
            Llvm.position_at_end start b;
            counted ~fetch:(trips <> short_trips) (Some trips);
            ignore (Llvm.build_br joined b))
          [ (long, long_trips); (short, short_trips) ];
        Llvm.position_at_end joined b
      end
  | Stat.Leave label ->
      let exit, depth = Hashtbl.find fr.labels label in
      drain env fr b depth;
      ignore (Llvm.build_br exit b)
  | Stat.Spawn { task; scope; thunk; frame; args; dest; layout = l; island } ->
      (* The arguments run first, in order; then the frame is made, filled,
         and handed to the pool with where its result goes. *)
      let values = List.map (expr env fr b) args in
      let n x = Llvm.const_int env.i64 x in
      let header = frame_slot env fr b scope task in
      zero env b header Frames.task;
      let at = byte_at env b header Frames.task in
      let t = lltype env frame in
      List.iteri
        (fun i v ->
          Option.iter
            (fun v -> ignore (Llvm.build_store v (Llvm.build_struct_gep t at (i + 1) "" b) b))
            v)
        values;
      Option.iter
        (fun (i : Expr.island) ->
          let field = Llvm.build_struct_gep t at i.Expr.field "" b in
          Option.iter
            (fun copy -> ignore (Llvm.build_store (Llvm.build_struct_gep t at copy "" b) field b))
            i.Expr.copy;
          ignore
            (call_runtime env b Cgt.Runtime.Island
               [| field; n i.Expr.size; layout env i.Expr.value_layout; n (if Option.is_some i.Expr.copy then 1 else 0) |]))
        island;
      ignore (Llvm.build_store at (slot env fr task env.ptr) b);
      let result = match frame with Ty.Struct (r :: _) -> r | _ -> Ty.Void in
      let home, bytes =
        match dest with
        | Some id ->
            let size = fst (size_align result) in
            let s = frame_slot env fr b scope id in
            zero env b s size;
            hold env fr b s l;
            Hashtbl.replace fr.locals id (s, lltype env result);
            (s, size)
        | None -> (at, 0)
      in
      let f, _ = Hashtbl.find env.funcs thunk in
      ignore (call_runtime env b Cgt.Runtime.Spawn [| at; f; home; layout env l; n bytes |])
  | Stat.Join task ->
      let at = Llvm.build_load env.ptr (fst (Hashtbl.find fr.locals task)) "" b in
      ignore (call_runtime env b Cgt.Runtime.Join [| at |])

(* ---------------------------------------------------------------------- *)
(* Functions and programs                                                 *)
(* ---------------------------------------------------------------------- *)

(* A parameter passed by address is the caller's place or a fresh slot of the
   caller's, which the attributes promise the callee only reads. Lowering
   never writes a parameter's own slot: a borrow is read-only (memory.md
   §2.9), and a `^T` parameter is held in a slot of the body's own before it
   is moved on. So one that does is an invariant broken, not a program to
   build. *)
let unwritten env (f : Func.t) addressed =
  let bad id = Diagnostic.bug (Printf.sprintf "codegen: `%s` writes its parameter %%%d, passed by address" f.Func.symbol id) in
  let rec stat (s : Stat.t) =
    (match s with
    | Stat.Assign { place; _ } when (not place.Expr.deref) && List.mem place.Expr.local addressed ->
        bad place.Expr.local
    | _ -> ());
    let es, bodies = Cgt.Traverse.stat_parts s in
    List.iter expr es;
    List.iter (List.iter stat) bodies
  and expr (e : Expr.t) =
    (match e.Expr.node with
    | Expr.Take { address = { Expr.node = Expr.Address id; _ }; layout = l }
      when List.mem id addressed && Option.is_some (Walks.vacater (walks env) l) ->
        bad id
    | _ -> ());
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.iter expr es;
    List.iter (List.iter stat) bodies
  in
  if addressed <> [] then List.iter stat f.Func.body

let func env (f : Func.t) =
  Held_spills.start ();
  (* Experimental: an optimized build's loops over independent walks. *)
  let f = if env.version then Interleave.func f else f in
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  let a = Hashtbl.find env.abis f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let sret = match snd a.ret with Address -> Some (Llvm.param fn 0) | Itself | Words _ -> None in
  let fr =
    {
      fn;
      symbol = f.Func.symbol;
      locals = Hashtbl.create 8;
      labels = Hashtbl.create 8;
      arenas = Hashtbl.create 4;
      open_ = [];
      handled = [];
      spawning = [];
      offsets = Hashtbl.create 8;
      ret = a.ret;
      sret;
      loops = 0;
      runs = Hashtbl.create 4;
      hoisted = [];
      own = own_lists f.Func.params f.Func.body;
      names = Hashtbl.create 8;
      unchecked = [];
      kept = Hashtbl.create 4;
    }
  in
  (* A parameter passed as itself is stored into a slot like any other
     local, and one passed as words is put back together in one. One
     passed by address is read in place: its pointer is its slot. *)
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  let next = ref (if Option.is_some sret then 1 else 0) in
  let param () =
    let p = Llvm.param fn !next in
    incr next;
    p
  in
  List.iter2
    (fun (id, t) (_, passing) ->
      match passing with
      | Itself -> ignore (Llvm.build_store (param ()) (slot env fr id (lltype env t)) b)
      | Address -> Hashtbl.replace fr.locals id (param (), lltype env t)
      | Words n ->
          let s = alloca env fr (Llvm.array_type env.i64 n) in
          for i = 0 to n - 1 do
            let at = Llvm.build_in_bounds_gep env.i64 s [| Llvm.const_int env.i64 i |] "" b in
            ignore (Llvm.build_store (param ()) at b)
          done;
          Hashtbl.replace fr.locals id (s, lltype env t))
    kept a.params;
  unwritten env f (List.filter_map (fun ((id, _), (_, p)) -> if p = Address then Some id else None) (List.combine kept a.params));
  (Pool_cache.current :=
     match if Pool_cache.on () then Pool_cache.pool_locals f else [] with
     | p :: _ as ids ->
         let handle = Llvm.build_load env.ptr (fst (Hashtbl.find fr.locals p)) "" b in
         Some (Pool_cache.start env.ctx b ~alloca:(alloca env fr) ids handle)
     | [] -> None);
  stats env fr b f.Func.body;
  Held_spills.run env.ctx fn;
  Pool_cache.current := None;
  if not (has_terminator b) then
    ignore
      (if f.Func.ret = Ty.Void || Option.is_some sret then Llvm.build_ret_void b
       else Llvm.build_unreachable b);
  unaligned fn
