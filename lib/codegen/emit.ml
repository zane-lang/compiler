(* The CGT as an LLVM module (docs/design/lowering.md L1, L2). Every CGT function is
   one LLVM function and every CGT type one LLVM type; nothing is decided
   here that the tree has not already said. *)

open Cgt.Nodes

external set_ordering : Llvm.llvalue -> bool -> unit = "zane_set_ordering"

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  funcs : (string, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  globals : (string, Llvm.llvalue) Hashtbl.t;
  (* The walks of each layout the program names that lists a position. *)
  mutable walks : Walks.known option;
}

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

let size_align = Ty.size_align
let words = Ty.words

let rec lltype env (t : Ty.t) =
  match t with
  | Ty.Void -> Llvm.void_type env.ctx
  | Ty.I1 -> Llvm.i1_type env.ctx
  | Ty.I32 -> Llvm.i32_type env.ctx
  | Ty.I64 -> env.i64
  | Ty.F32 -> Llvm.float_type env.ctx
  | Ty.F64 -> Llvm.double_type env.ctx
  | Ty.Handle -> Llvm.struct_type env.ctx [| env.ptr; env.i64; env.i64 |]
  | Ty.Ptr -> env.ptr
  | Ty.Struct ts -> Llvm.struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Sum ts -> (
      let tag = Llvm.i32_type env.ctx in
      match words ts with
      | 0 -> Llvm.struct_type env.ctx [| tag |]
      | n -> Llvm.struct_type env.ctx [| tag; Llvm.array_type env.i64 n |])
  | Ty.Array (t, n) -> Llvm.array_type (stored env t) n

(* A `Unit` member takes no room, but keeps its index. *)
and stored env t = if t = Ty.Void then Llvm.struct_type env.ctx [||] else lltype env t

(* `Unit` has no storage, so a `Unit` parameter passes nothing. *)
let fn_type env params ret =
  let kept = List.filter (fun t -> t <> Ty.Void) params in
  Llvm.function_type (lltype env ret) (Array.of_list (List.map (lltype env) kept))

(* ---------------------------------------------------------------------- *)
(* The runtime and its layouts                                            *)
(* ---------------------------------------------------------------------- *)

(* The runtime's functions, declared the first time a call needs one, with
   the signature [Cgt.Runtime] gives each. *)
let runtime env fn =
  let name = Cgt.Runtime.name fn in
  match Hashtbl.find_opt env.funcs name with
  | Some f -> f
  | None ->
      let abi = function
        | Cgt.Runtime.Void -> Llvm.void_type env.ctx
        | Cgt.Runtime.I32 -> Llvm.i32_type env.ctx
        | Cgt.Runtime.I64 -> env.i64
        | Cgt.Runtime.F32 -> Llvm.float_type env.ctx
        | Cgt.Runtime.F64 -> Llvm.double_type env.ctx
        | Cgt.Runtime.Ptr -> env.ptr
      in
      let ret, params = Cgt.Runtime.signature fn in
      let fty = Llvm.function_type (abi ret) (Array.of_list (List.map abi params)) in
      let f = Llvm.declare_function name fty env.m in
      (* An index out of range stops the program, so the path to it is cold
         and nothing follows it. *)
      if fn = Cgt.Runtime.Out_of_range then
        List.iter
          (fun a -> Llvm.add_function_attr f (Llvm.create_enum_attr env.ctx a 0L) Llvm.AttrIndex.Function)
          [ "noreturn"; "cold"; "nounwind" ];
      Hashtbl.replace env.funcs name (f, fty);
      (f, fty)

let walks env = Option.get env.walks

(* A layout's table of walks, or none when it lists nothing. *)
let layout env (l : Layout.t) = Walks.table (walks env) l
let listed env (l : Layout.t) = Walks.listed (walks env) l

(* A string literal is constant bytes the module owns, with no terminator,
   and owns no block. *)
let text env s =
  let bytes = Llvm.const_string env.ctx s in
  let g = Llvm.define_global "zane.text" bytes env.m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  Llvm.set_unnamed_addr true g;
  let n = Llvm.const_int env.i64 in
  Llvm.const_struct env.ctx [| g; n (String.length s); n 0 |]

(* ---------------------------------------------------------------------- *)
(* Frames and slots                                                       *)
(* ---------------------------------------------------------------------- *)

(* What a function being built keeps: its symbol, its slots, the exit
   block of each expansion it is inside with how many arenas were open when
   it began, each open arena's record, the arenas open where it is building,
   innermost first (L8), and where in its arena's frame each slot is. *)
type frame = {
  fn : Llvm.llvalue;
  symbol : string;
  locals : (int, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  labels : (int, Llvm.llbasicblock * int) Hashtbl.t;
  arenas : (int, Llvm.llvalue) Hashtbl.t;
  mutable open_ : Llvm.llvalue list;
  offsets : (int, int) Hashtbl.t;
  ret : Ty.t;
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

let field env b t p offset = Llvm.build_load t (byte_at env b p offset) "" b
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

(* A branch that is almost never taken, as LLVM's branch weights say it, so
   its code is laid out away from the path that is. *)
let unlikely env br =
  let i32 = Llvm.i32_type env.ctx in
  let weights =
    Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "branch_weights"; Llvm.const_int i32 1; Llvm.const_int i32 2000 |]
  in
  Llvm.set_metadata br (Llvm.mdkind_id env.ctx "prof") weights

(* Offsets into a scope's record and a context, as runtime/zane_internal.h
   asserts them. *)
let record_context = 152
and record_depth = 160
and record_outer = 168
and record_skip = 176
and record_tasks = 184
and record_mappings = 192
and context_frontier = 0
and context_top = 8
and context_limit = 16

(* A scope opens with a frame of [size] bytes (Frames), and its record's
   address names it. While no call this thread's context spawned is out,
   nothing else can reach the context, so the code places the frame itself:
   the record goes at the frontier, which moves past the frame, and links to
   the scope around it and to the one it skips to (runtime/zane_internal.h).
   A frame larger than the guard after the range is checked against the
   range's end first; a smaller one that does not fit faults in the guard.
   Otherwise the runtime places it under the context's lock. *)
let enter env fr b size =
  let ptr = env.ptr and i64 = env.i64 in
  let outer = Llvm.build_load ptr (open_scope env) "" b in
  let inline = block env fr and shared = block env fr and opened = block env fr in
  ignore
    (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ne outer (Llvm.const_null ptr) "" b) inline shared b);
  Llvm.position_at_end inline b;
  let c = field env b ptr outer record_context in
  let m = field env b ptr c context_frontier in
  let past = byte_at env b m size in
  if size > Frames.guard then begin
    let limit = field env b ptr c context_limit in
    let over = Llvm.build_icmp Llvm.Icmp.Ugt past limit "" b in
    let stop = block env fr and fits = block env fr in
    unlikely env (Llvm.build_cond_br over stop fits b);
    Llvm.position_at_end stop b;
    ignore (call_runtime env b Cgt.Runtime.Too_deep [||]);
    ignore (Llvm.build_unreachable b);
    Llvm.position_at_end fits b
  end;
  set_field env b past c context_frontier;
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
  Llvm.build_phi [ (m, inline_end); (placed, shared) ] "" b

(* A scope drains (L8). One that spawned nothing and has no dynamic chunk,
   while its context is this thread's alone and drains are not checked, has
   nothing to wait for or give back but its frame, so the code moves the
   frontier back to its record itself. Otherwise the runtime drains it. *)
let drain_scope env fr b m =
  let ptr = env.ptr in
  let null = Llvm.const_null ptr in
  let innermost = Llvm.build_icmp Llvm.Icmp.Eq (Llvm.build_load ptr (open_scope env) "" b) m "" b in
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
  let plain =
    Llvm.build_and
      (Llvm.build_and (empty (field env b ptr m record_tasks)) (empty (field env b ptr m record_mappings)) "" b)
      unchecked "" b
  in
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
   value arrives, so the drain can return them (runtime/slot.c). *)
let hold env fr b slot l =
  if listed env l then begin
    let on =
      Llvm.build_icmp Llvm.Icmp.Ne
        (Llvm.build_load (Llvm.i32_type env.ctx) (checking env) "" b)
        (Llvm.const_int (Llvm.i32_type env.ctx) 0)
        "" b
    in
    let listing = block env fr and after = block env fr in
    ignore (Llvm.build_cond_br on listing after b);
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

(* A value moved into a fresh place: stored, and the blocks it owns that the
   place's region outlives move into it (memory.md §3.5). *)
let place env b p v l =
  ignore (Llvm.build_store v p b);
  if listed env l then ignore (call_runtime env b Cgt.Runtime.Arrive [| p; layout env l |])

(* A value stored where its address can be passed. *)
let spill env fr b v =
  let p = alloca env fr (Llvm.type_of v) in
  ignore (Llvm.build_store v p b);
  p

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
    | Ty.Ptr | Ty.Handle -> true
    | Ty.Struct ts | Ty.Sum ts -> List.exists names_block ts
    | Ty.Array (t, _) -> names_block t
    | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> false
  in
  if size_align t <> (8, 8) then `Runtime
  else if names_block t then `Acquire
  else `Unordered

(* The address of a list's or an array's element, counted from 1, checked
   against its count here rather than in the runtime, so LLVM sees the count,
   the index and the address the way it sees any arithmetic. Only an index
   outside calls the runtime, which stops the program (§9). One unsigned
   compare of the index less one covers both ends. *)
let element env fr b fn args =
  let base, index, count, stride =
    match (fn, args) with
    | Cgt.Runtime.List_at, [ list; index; stride ] ->
        let header = Llvm.struct_type env.ctx [| env.ptr; env.i64; env.i64 |] in
        let field i t = Llvm.build_load t (Llvm.build_struct_gep header list i "" b) "" b in
        (field 0 env.ptr, index, field 1 env.i64, stride)
    | Cgt.Runtime.Array_at, [ array; index; count; stride ] -> (array, index, count, stride)
    | _ -> Diagnostic.bug "codegen: an element address with the wrong arguments"
  in
  let offset = Llvm.build_sub index (Llvm.const_int env.i64 1) "" b in
  let outside = Llvm.build_icmp Llvm.Icmp.Uge offset count "" b in
  let stop = block env fr and inside = block env fr in
  ignore (Llvm.build_cond_br outside stop inside b);
  Llvm.position_at_end stop b;
  let f, fty = runtime env Cgt.Runtime.Out_of_range in
  ignore (Llvm.build_call fty f [||] "" b);
  ignore (Llvm.build_unreachable b);
  Llvm.position_at_end inside b;
  let bytes = Llvm.build_nsw_mul offset stride "" b in
  Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) base [| bytes |] "" b

(* ---------------------------------------------------------------------- *)
(* Arithmetic                                                             *)
(* ---------------------------------------------------------------------- *)

(* LLVM leaves an integer division by zero undefined, and the one quotient an
   integer cannot hold too. The first gives zero and the second wraps, as `+`
   and `*` do (operators.md §2.6); the divisor is replaced in both, so the
   [sdiv] itself never sees either. *)
let divide b l r =
  let t = Llvm.type_of l in
  let zero = Llvm.const_int t 0 in
  let by_zero = Llvm.build_icmp Llvm.Icmp.Eq r zero "" b in
  let negating = Llvm.build_icmp Llvm.Icmp.Eq r (Llvm.const_int t (-1)) "" b in
  let replaced = Llvm.build_or by_zero negating "" b in
  let divisor = Llvm.build_select replaced (Llvm.const_int t 1) r "" b in
  let quotient = Llvm.build_sdiv l divisor "" b in
  let quotient = Llvm.build_select negating (Llvm.build_sub zero l "" b) quotient "" b in
  Llvm.build_select by_zero zero quotient "" b

(* A scalar converted from [from] to [into] (Cgt.Nodes.Scalar). A float
   truncated to an integer saturates (types.md §2.9): a NaN gives zero, and
   one whose integer part the target cannot hold gives the target's nearest
   end. [fptosi] is poison outside the bounds, and the selects never pick it
   there. *)
let convert env b (from : Ty.t) (into : Ty.t) v =
  let target = lltype env into in
  let is_float = function Ty.F32 | Ty.F64 -> true | _ -> false in
  match (is_float from, is_float into) with
  | false, false ->
      if Scalar.bits from < Scalar.bits into then Llvm.build_sext v target "" b
      else if Scalar.bits from > Scalar.bits into then Llvm.build_trunc v target "" b
      else v
  | false, true -> Llvm.build_sitofp v target "" b
  | true, true -> (
      match (from, into) with
      | Ty.F32, Ty.F64 -> Llvm.build_fpext v target "" b
      | Ty.F64, Ty.F32 -> Llvm.build_fptrunc v target "" b
      | _ -> v)
  | true, false ->
      let source = Llvm.type_of v in
      let lower, inclusive, upper = Scalar.truncation ~from into in
      let above =
        Llvm.build_fcmp
          (if inclusive then Llvm.Fcmp.Oge else Llvm.Fcmp.Ogt)
          v (Llvm.const_float source lower) "" b
      in
      let below = Llvm.build_fcmp Llvm.Fcmp.Olt v (Llvm.const_float source upper) "" b in
      let nan = Llvm.build_fcmp Llvm.Fcmp.Uno v v "" b in
      let least, most = Scalar.ends into in
      let truncated = Llvm.build_fptosi v target "" b in
      let high = Llvm.build_select below truncated (Llvm.const_of_int64 target most true) "" b in
      let saturated = Llvm.build_select above high (Llvm.const_of_int64 target least true) "" b in
      Llvm.build_select nan (Llvm.const_int target 0) saturated "" b

let binary b (op : Expr.binop) (t : Ty.t) l r =
  match (t, op) with
  | (Ty.I64 | Ty.I32), Expr.Add -> Llvm.build_add l r "" b
  | (Ty.I64 | Ty.I32), Expr.Mul -> Llvm.build_mul l r "" b
  | (Ty.I64 | Ty.I32), Expr.Div -> divide b l r
  | (Ty.I64 | Ty.I32 | Ty.I1), Expr.Eq -> Llvm.build_icmp Llvm.Icmp.Eq l r "" b
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
      let at, _ =
        List.fold_left
          (fun (p, t) i ->
            match t with
            | Ty.Struct ts -> (Llvm.build_struct_gep (lltype env t) p i "" b, List.nth ts i)
            (* A sum's payload room holds case [i]'s payload. *)
            | Ty.Sum ts when List.nth ts i = Ty.Void -> (p, Ty.Void)
            | Ty.Sum ts -> (Llvm.build_struct_gep (lltype env t) p 1 "" b, List.nth ts i)
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
          (match snapshot_read t with
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
      | t, Some p -> Some (Llvm.build_load (lltype env t) p "" b))
  | Expr.Record members ->
      Some
        (List.fold_left
           (fun v (i, m) ->
             match expr env fr b m with Some x -> Llvm.build_insertvalue v x i "" b | None -> v)
           (Llvm.undef (lltype env e.Expr.ty))
           members)
  | Expr.Member { value; index } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | _, Some v -> Some (Llvm.build_extractvalue v index "" b))
  | Expr.Case { index; payload } ->
      let t = lltype env e.Expr.ty in
      let tmp = alloca env fr t in
      let tag = Llvm.build_struct_gep t tmp 0 "" b in
      ignore (Llvm.build_store (Llvm.const_int (Llvm.i32_type env.ctx) index) tag b);
      (match expr env fr b payload with
      | Some p -> ignore (Llvm.build_store p (Llvm.build_struct_gep t tmp 1 "" b) b)
      | None -> ());
      Some (Llvm.build_load t tmp "" b)
  | Expr.Payload { value; _ } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | t, Some v ->
          let sum = Llvm.type_of v in
          let tmp = alloca env fr sum in
          ignore (Llvm.build_store v tmp b);
          Some (Llvm.build_load (lltype env t) (Llvm.build_struct_gep sum tmp 1 "" b) "" b))
  | Expr.Call { fn; args } ->
      let f, fty = Hashtbl.find env.funcs fn in
      let args = Array.of_list (List.filter_map (expr env fr b) args) in
      let v = Llvm.build_call fty f args "" b in
      if e.Expr.ty = Ty.Void then None else Some v
  | Expr.Call_value { fn; args } ->
      (* The function's type is its arguments' and its result's, which the
         tree gives, as for a direct call. *)
      let f = value_of env fr b fn in
      let fty = fn_type env (List.map (fun (a : Expr.t) -> a.Expr.ty) args) e.Expr.ty in
      let args = Array.of_list (List.filter_map (expr env fr b) args) in
      let v = Llvm.build_call fty f args "" b in
      if e.Expr.ty = Ty.Void then None else Some v
  | Expr.Runtime { fn = (Cgt.Runtime.List_at | Cgt.Runtime.Array_at) as fn; args } ->
      Some (element env fr b fn (List.filter_map (expr env fr b) args))
  | Expr.Runtime { fn; args } -> (
      let f, fty = runtime env fn in
      let args =
        List.filter_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env fr b a) with
            | Ty.Handle, Some v -> Some (spill env fr b v)
            | _, v -> v)
          args
      in
      match e.Expr.ty with
      | Ty.Void ->
          ignore (Llvm.build_call fty f (Array.of_list args) "" b);
          None
      | Ty.Handle ->
          let t = lltype env Ty.Handle in
          let out = alloca env fr t in
          ignore (Llvm.build_call fty f (Array.of_list (out :: args)) "" b);
          Some (Llvm.build_load t out "" b)
      | _ -> Some (Llvm.build_call fty f (Array.of_list args) "" b))
  | Expr.Binary { op; left; right } -> (
      (* The left operand's instructions come first. *)
      let l = expr env fr b left in
      match (l, expr env fr b right) with
      | Some l, Some r -> Some (binary b op left.Expr.ty l r)
      | _ -> Diagnostic.bug "codegen: an operand has no value")
  | Expr.Flip value -> (
      match (value.Expr.ty, expr env fr b value) with
      | (Ty.I64 | Ty.I32), Some v -> Some (Llvm.build_neg v "" b)
      | (Ty.F64 | Ty.F32), Some v -> Some (Llvm.build_fneg v "" b)
      | Ty.I1, Some v -> Some (Llvm.build_not v "" b)
      | _ -> Diagnostic.bug "codegen: `~` on a value it does not flip")
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

and stats env fr b body = List.iter (fun s -> if not (has_terminator b) then stat env fr b s) body

and stat env fr b (s : Stat.t) =
  match s with
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
                | Ty.Struct ts -> (Llvm.build_struct_gep (lltype env t) p i "" b, List.nth ts i)
                | _ -> Diagnostic.bug "codegen: a member path through something not a struct")
              (base, place.Expr.ty) place.Expr.path
          in
          ignore (Llvm.build_store v target b)
      | _ -> ())
  | Stat.Switch { value; cases } ->
      let v = value_of env fr b value in
      let tag = Llvm.build_extractvalue v 0 "" b in
      let after = block env fr and otherwise = block env fr in
      let sw = Llvm.build_switch tag otherwise (List.length cases) b in
      List.iter
        (fun (i, body) ->
          let case = block env fr in
          Llvm.add_case sw (Llvm.const_int (Llvm.i32_type env.ctx) i) case;
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
      (* The value is read before its arenas are drained. *)
      let v = expr env fr b e in
      drain env fr b 0;
      match v with
      | Some v when fr.ret <> Ty.Void -> ignore (Llvm.build_ret v b)
      | _ -> ignore (Llvm.build_ret_void b))
  | Stat.Scope { id; body } ->
      let frame = Frames.layout fr.symbol id body in
      Hashtbl.iter (Hashtbl.replace fr.offsets) frame.Frames.offsets;
      let arena = enter env fr b frame.Frames.size in
      Hashtbl.replace fr.arenas id arena;
      fr.open_ <- arena :: fr.open_;
      stats env fr b body;
      if not (has_terminator b) then drain_scope env fr b arena;
      fr.open_ <- List.tl fr.open_
  | Stat.Hold { id; scope; value; layout = l } -> (
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let slot = frame_slot env fr b scope id in
          ignore (Llvm.build_store v slot b);
          hold env fr b slot l;
          Hashtbl.replace fr.locals id (slot, Llvm.type_of v))
  | Stat.Reserve { id; scope; ty = t; layout = l } ->
      let slot = frame_slot env fr b scope id in
      zero env b slot (fst (size_align t));
      hold env fr b slot l;
      Hashtbl.replace fr.locals id (slot, lltype env t)
  | Stat.Place { address; value; layout = l } -> (
      let p = value_of env fr b address in
      match expr env fr b value with Some v -> place env b p v l | None -> ())
  | Stat.Store { address; value } -> (
      let p = value_of env fr b address in
      match expr env fr b value with Some v -> ignore (Llvm.build_store v p b) | None -> ())
  | Stat.Overwrite { address; value; layout = l } -> (
      let p = value_of env fr b address in
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let incoming = spill env fr b v in
          let n x = Llvm.const_int env.i64 x in
          let size = n (fst (size_align value.Expr.ty)) in
          ignore (call_runtime env b Cgt.Runtime.Overwrite [| p; incoming; size; layout env l |]))
  | Stat.If { cond; body } ->
      let c = value_of env fr b cond in
      let taken = block env fr and after = block env fr in
      ignore (Llvm.build_cond_br c taken after b);
      Llvm.position_at_end taken b;
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br after b);
      Llvm.position_at_end after b
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = value_of env fr b count in
      let i = alloca env fr env.i64 in
      ignore (Llvm.build_store (Llvm.const_int env.i64 0) i b);
      let head = block env fr and step = block env fr and after = block env fr in
      ignore (Llvm.build_br head b);
      Llvm.position_at_end head b;
      let current = Llvm.build_load env.i64 i "" b in
      ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt current n "" b) step after b);
      Llvm.position_at_end step b;
      stats env fr b body;
      if not (has_terminator b) then begin
        let current = Llvm.build_load env.i64 i "" b in
        ignore (Llvm.build_store (Llvm.build_add current (Llvm.const_int env.i64 1) "" b) i b);
        ignore (Llvm.build_br head b)
      end;
      Llvm.position_at_end after b
  | Stat.Leave label ->
      let exit, depth = Hashtbl.find fr.labels label in
      drain env fr b depth;
      ignore (Llvm.build_br exit b)
  | Stat.Spawn { task; scope; thunk; frame; args; dest; layout = l } ->
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

let func env (f : Func.t) =
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let fr =
    {
      fn;
      symbol = f.Func.symbol;
      locals = Hashtbl.create 8;
      labels = Hashtbl.create 8;
      arenas = Hashtbl.create 4;
      open_ = [];
      offsets = Hashtbl.create 8;
      ret = f.Func.ret;
    }
  in
  (* A parameter is stored into a slot like any other local. *)
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  List.iteri
    (fun i (id, t) -> ignore (Llvm.build_store (Llvm.param fn i) (slot env fr id (lltype env t)) b))
    kept;
  stats env fr b f.Func.body;
  if not (has_terminator b) then
    ignore (if f.Func.ret = Ty.Void then Llvm.build_ret_void b else Llvm.build_unreachable b)

(* The program's module. Its entry is named `zane_main` whatever its symbol,
   since that is the name the runtime calls (L16). A function other objects
   link against keeps its symbol in theirs too, and one a stamped
   dependency's objects define is only declared, or has an
   [available_externally] body that LLVM can inline but never emits
   (docs/design/separate-compilation.md); the rest are local to this one. *)
(* The size of the range each context reserves for its frames, the main
   context's and each spawned call's, when the root manifest gives none
   (memory.md §3.1, dependencies.md §2.1). *)
let default_fixed_region = 256 lsl 20
let default_spawned_fixed_region = 8 lsl 20

let program ?(fixed_region = default_fixed_region) ?(spawned_fixed_region = default_spawned_fixed_region)
    (p : Program.t) =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "zane" in
  let env =
    {
      ctx;
      m;
      ptr = Llvm.pointer_type ctx;
      i64 = Llvm.i64_type ctx;
      funcs = Hashtbl.create 32;
      globals = Hashtbl.create 8;
      walks = None;
    }
  in
  env.walks <-
    Some
      (Walks.create
         { Walks.ctx; m; ptr = env.ptr; i64 = env.i64; runtime = runtime env }
         p.Program.layouts);
  List.iter
    (fun (g : Global.t) ->
      let v = Llvm.define_global g.Global.symbol (Llvm.const_null (stored env g.Global.ty)) m in
      (match g.Global.linkage with
      | Cgt.Nodes.Linkage.Local -> Llvm.set_linkage Llvm.Linkage.Internal v
      | Cgt.Nodes.Linkage.Shared -> Llvm.set_linkage Llvm.Linkage.Link_once_odr v
      | Cgt.Nodes.Linkage.Exported | Cgt.Nodes.Linkage.Imported -> ()
      | Cgt.Nodes.Linkage.Available -> Diagnostic.bug "an optimization-only global");
      Hashtbl.replace env.globals g.Global.symbol v)
    p.Program.globals;
  List.iter
    (fun (f : Func.t) ->
      let fty = fn_type env (List.map snd f.Func.params) f.Func.ret in
      let entry = Some f.Func.symbol = p.Program.entry in
      let name = if entry then "zane_main" else f.Func.symbol in
      let fn =
        match f.Func.linkage with
        | Cgt.Nodes.Linkage.Imported -> Llvm.declare_function name fty m
        | _ -> Llvm.define_function name fty m
      in
      (match f.Func.linkage with
      | _ when entry -> ()
      | Cgt.Nodes.Linkage.Local -> Llvm.set_linkage Llvm.Linkage.Internal fn
      | Cgt.Nodes.Linkage.Exported | Cgt.Nodes.Linkage.Imported -> ()
      | Cgt.Nodes.Linkage.Available -> Llvm.set_linkage Llvm.Linkage.Available_externally fn
      | Cgt.Nodes.Linkage.Shared -> Llvm.set_linkage Llvm.Linkage.Link_once_odr fn);
      Hashtbl.replace env.funcs f.Func.symbol (fn, fty))
    p.Program.funcs;
  List.iter
    (fun (f : Func.t) -> if f.Func.linkage <> Cgt.Nodes.Linkage.Imported then func env f)
    p.Program.funcs;
  (* The module with the program's entry also says how large each context's
     range is, which the runtime reads when it makes one. *)
  if Option.is_some p.Program.entry then
    List.iter
      (fun (name, size) ->
        let g = Llvm.define_global name (Llvm.const_int env.i64 size) m in
        Llvm.set_global_constant true g)
      [ ("zane_fixed_region", fixed_region); ("zane_spawned_fixed_region", spawned_fixed_region) ];
  Walks.finish (walks env);
  (* A function whose locals take more than a page of machine stack touches
     each page in turn as it takes them, so a stack that runs out faults in
     the page that guards it, which the runtime reports, rather than past
     it in whatever lies below. *)
  let probe = Llvm.create_string_attr ctx "probe-stack" "inline-asm" in
  Llvm.iter_functions
    (fun f -> if not (Llvm.is_declaration f) then Llvm.add_function_attr f probe Llvm.AttrIndex.Function)
    m;
  (match Llvm_analysis.verify_module m with
  | Some problem -> Diagnostic.bug ("codegen built an invalid module: " ^ problem)
  | None -> ());
  m
