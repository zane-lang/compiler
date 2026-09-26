(* The CGT as an LLVM module (docs/lowering.md L1, L2). Every CGT function is
   one LLVM function and every CGT type one LLVM type; nothing is decided
   here that the tree has not already said. *)

open Cgt.Nodes

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  funcs : (string, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  (* Each layout the program uses, as one constant table. *)
  layouts : (Layout.t, Llvm.llvalue) Hashtbl.t;
}

let size_align = Ty.size_align
let words = Ty.words

let rec lltype env (t : Ty.t) =
  match t with
  | Ty.Void -> Llvm.void_type env.ctx
  | Ty.I1 -> Llvm.i1_type env.ctx
  | Ty.I32 -> Llvm.i32_type env.ctx
  | Ty.I64 -> env.i64
  | Ty.F64 -> Llvm.double_type env.ctx
  | Ty.Text -> Llvm.struct_type env.ctx [| Llvm.i32_type env.ctx; env.ptr; env.i64; env.i64 |]
  | Ty.Ptr -> env.ptr
  | Ty.Struct ts -> Llvm.struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Sum ts -> (
      let tag = Llvm.i32_type env.ctx in
      match words ts with
      | 0 -> Llvm.struct_type env.ctx [| tag |]
      | n -> Llvm.struct_type env.ctx [| tag; Llvm.array_type env.i64 n |])

(* A `Unit` member takes no room, but keeps its index. *)
and stored env t = if t = Ty.Void then Llvm.struct_type env.ctx [||] else lltype env t

(* `Unit` has no storage, so a `Unit` parameter passes nothing. *)
let fn_type env params ret =
  let kept = List.filter (fun t -> t <> Ty.Void) params in
  Llvm.function_type (lltype env ret) (Array.of_list (List.map (lltype env) kept))

(* The runtime's functions, declared the first time a call needs one. *)
let runtime env name =
  match Hashtbl.find_opt env.funcs name with
  | Some f -> f
  | None ->
      let fty =
        match name with
        | "zane_print" -> Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr |]
        | "zane_text_join" ->
            Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr; env.ptr |]
        | "zane_text_equal" -> Llvm.function_type env.i64 [| env.ptr; env.ptr |]
        | "zane_divide_by_zero" -> Llvm.function_type (Llvm.void_type env.ctx) [||]
        | "zane_scope_enter" -> Llvm.function_type env.i64 [||]
        | "zane_slot" -> Llvm.function_type env.ptr [| env.i64; env.i64; env.i64; env.ptr |]
        | "zane_mint" -> Llvm.function_type (Llvm.i32_type env.ctx) [| env.ptr |]
        | "zane_resolve" -> Llvm.function_type env.ptr [| Llvm.i32_type env.ctx |]
        | "zane_terminal" ->
            Llvm.function_type (Llvm.i32_type env.ctx) [| Llvm.i32_type env.ctx |]
        | "zane_arrive" | "zane_vacate" ->
            Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr |]
        | "zane_overwrite" ->
            Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr; env.i64; env.ptr |]
        | "zane_scope_drain" -> Llvm.function_type (Llvm.void_type env.ctx) [| env.i64 |]
        | _ -> failwith ("codegen: unknown runtime function " ^ name)
      in
      let f = Llvm.declare_function name fty env.m in
      Hashtbl.replace env.funcs name (f, fty);
      (f, fty)

(* A layout as the runtime reads it: a count, then per position its kind,
   its offset, its size, and its tag conditions as a count and (offset, tag)
   pairs. *)
let layout env (l : Layout.t) =
  match Hashtbl.find_opt env.layouts l with
  | Some g -> g
  | None ->
      let words =
        List.length l
        :: List.concat_map
             (fun (p : Layout.position) ->
               let kind = match p.kind with Layout.Host -> 0 | Layout.Text -> 1 in
               [ kind; p.offset; p.size; List.length p.tags ]
               @ List.concat_map (fun (o, t) -> [ o; t ]) p.tags)
             l
      in
      let table =
        Llvm.const_array env.i64 (Array.of_list (List.map (Llvm.const_int env.i64) words))
      in
      let g = Llvm.define_global "zane.layout" table env.m in
      Llvm.set_linkage Llvm.Linkage.Private g;
      Llvm.set_global_constant true g;
      Hashtbl.replace env.layouts l g;
      g

(* A string literal is constant bytes the module owns, with no terminator.
   Its instance starts untethered, and owns no block. *)
let text env s =
  let bytes = Llvm.const_string env.ctx s in
  let g = Llvm.define_global "zane.text" bytes env.m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  Llvm.set_unnamed_addr true g;
  let n = Llvm.const_int env.i64 in
  Llvm.const_struct env.ctx
    [| Llvm.const_int (Llvm.i32_type env.ctx) 0; g; n (String.length s); n 0 |]

(* What a function being built keeps: its slots, the exit block of each
   expansion it is inside with how many arenas were open when it began, and
   the arenas open where it is building, innermost first (L8). *)
type frame = {
  fn : Llvm.llvalue;
  locals : (int, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  labels : (int, Llvm.llbasicblock * int) Hashtbl.t;
  arenas : (int, Llvm.llvalue) Hashtbl.t;
  mutable open_ : Llvm.llvalue list;
  ret : Ty.t;
}

let call_runtime env b name args =
  let f, fty = runtime env name in
  Llvm.build_call fty f args "" b

(* Drain the arenas opened since [depth] were open, innermost first: what a
   way out of them does before it jumps. *)
let drain env fr b depth =
  List.iteri
    (fun i arena ->
      if i < List.length fr.open_ - depth then
        ignore (call_runtime env b "zane_scope_drain" [| arena |]))
    fr.open_

(* Every local is a stack slot in the entry block (L3); LLVM's `mem2reg`
   promotes the ones that can live in registers. *)
let alloca env fr t =
  let top = Llvm.builder_at env.ctx (Llvm.instr_begin (Llvm.entry_block fr.fn)) in
  Llvm.build_alloca t "" top

let slot env fr id t =
  let s = alloca env fr t in
  Hashtbl.replace fr.locals id (s, t);
  s

(* A value stored where its address can be passed. *)
let spill env fr b v =
  let p = alloca env fr (Llvm.type_of v) in
  ignore (Llvm.build_store v p b);
  p

let has_terminator b =
  match Llvm.block_terminator (Llvm.insertion_block b) with Some _ -> true | None -> false

let block env fr = Llvm.append_block env.ctx "" fr.fn

(* Integer division by zero has no result, and neither has the one quotient
   an `i64` cannot hold; LLVM leaves both undefined. The first stops the
   program (docs/lowering.md §9), and the second wraps, as `+` and `*` do. *)
let divide env fr b l r =
  let zero = Llvm.const_int env.i64 0 in
  let minus_one = Llvm.const_int env.i64 (-1) in
  let fails = block env fr and ok = block env fr in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Eq r zero "" b) fails ok b);
  Llvm.position_at_end fails b;
  let f, fty = runtime env "zane_divide_by_zero" in
  ignore (Llvm.build_call fty f [||] "" b);
  ignore (Llvm.build_unreachable b);
  Llvm.position_at_end ok b;
  let negating = Llvm.build_icmp Llvm.Icmp.Eq r minus_one "" b in
  let divisor = Llvm.build_select negating (Llvm.const_int env.i64 1) r "" b in
  let quotient = Llvm.build_sdiv l divisor "" b in
  Llvm.build_select negating (Llvm.build_sub zero l "" b) quotient "" b

let binary env fr b (op : Expr.binop) (t : Ty.t) l r =
  match (t, op) with
  | Ty.I64, Expr.Add -> Llvm.build_add l r "" b
  | Ty.I64, Expr.Mul -> Llvm.build_mul l r "" b
  | Ty.I64, Expr.Div -> divide env fr b l r
  | (Ty.I64 | Ty.I1), Expr.Eq -> Llvm.build_icmp Llvm.Icmp.Eq l r "" b
  | Ty.I64, Expr.Less -> Llvm.build_icmp Llvm.Icmp.Slt l r "" b
  | Ty.F64, Expr.Add -> Llvm.build_fadd l r "" b
  | Ty.F64, Expr.Mul -> Llvm.build_fmul l r "" b
  | Ty.F64, Expr.Div -> Llvm.build_fdiv l r "" b
  | Ty.F64, Expr.Eq -> Llvm.build_fcmp Llvm.Fcmp.Oeq l r "" b
  | Ty.F64, Expr.Less -> Llvm.build_fcmp Llvm.Fcmp.Olt l r "" b
  | Ty.I1, Expr.Add -> Llvm.build_or l r "" b
  | Ty.I1, Expr.Mul -> Llvm.build_and l r "" b
  | _ ->
      failwith
        (Printf.sprintf "codegen: no `%s` on %s" (Expr.binop_to_string op) (Ty.to_string t))

let rec expr env fr b (e : Expr.t) : Llvm.llvalue option =
  match e.Expr.node with
  | Expr.Int i -> Some (Llvm.const_of_int64 (lltype env e.Expr.ty) i true)
  | Expr.Offset { base; within; path } ->
      let base = Option.get (expr env fr b base) in
      let at, _ =
        List.fold_left
          (fun (p, t) i ->
            match t with
            | Ty.Struct ts -> (Llvm.build_struct_gep (lltype env t) p i "" b, List.nth ts i)
            (* A sum's payload room holds case [i]'s payload. *)
            | Ty.Sum ts when List.nth ts i = Ty.Void -> (p, Ty.Void)
            | Ty.Sum ts -> (Llvm.build_struct_gep (lltype env t) p 1 "" b, List.nth ts i)
            | _ -> failwith "codegen: an offset through something not a struct")
          (base, within) path
      in
      Some at
  | Expr.Mint p -> Some (call_runtime env b "zane_mint" [| Option.get (expr env fr b p) |])
  | Expr.Resolve t -> Some (call_runtime env b "zane_resolve" [| Option.get (expr env fr b t) |])
  | Expr.Terminal t ->
      Some (call_runtime env b "zane_terminal" [| Option.get (expr env fr b t) |])
  | Expr.Take { address; layout = l } -> (
      let p = Option.get (expr env fr b address) in
      match e.Expr.ty with
      | Ty.Void -> None
      | t ->
          let v = Llvm.build_load (lltype env t) p "" b in
          ignore (call_runtime env b "zane_vacate" [| p; layout env l |]);
          Some v)
  | Expr.Float f -> Some (Llvm.const_float (Llvm.double_type env.ctx) f)
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
  | Expr.Runtime { fn; args } -> (
      let f, fty = runtime env fn in
      let args =
        List.filter_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env fr b a) with
            | Ty.Text, Some v -> Some (spill env fr b v)
            | _, v -> v)
          args
      in
      match e.Expr.ty with
      | Ty.Void ->
          ignore (Llvm.build_call fty f (Array.of_list args) "" b);
          None
      | Ty.Text ->
          let t = lltype env Ty.Text in
          let out = alloca env fr t in
          ignore (Llvm.build_call fty f (Array.of_list (out :: args)) "" b);
          Some (Llvm.build_load t out "" b)
      | _ -> Some (Llvm.build_call fty f (Array.of_list args) "" b))
  | Expr.Binary { op; left; right } -> (
      (* The left operand's instructions come first. *)
      let l = expr env fr b left in
      match (l, expr env fr b right) with
      | Some l, Some r -> Some (binary env fr b op left.Expr.ty l r)
      | _ -> failwith "codegen: an operand has no value")
  | Expr.Flip value -> (
      match (value.Expr.ty, expr env fr b value) with
      | Ty.I64, Some v -> Some (Llvm.build_neg v "" b)
      | Ty.F64, Some v -> Some (Llvm.build_fneg v "" b)
      | Ty.I1, Some v -> Some (Llvm.build_not v "" b)
      | _ -> failwith "codegen: `~` on a value it does not flip")
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
                | _ -> failwith "codegen: a member path through something not a struct")
              (base, place.Expr.ty) place.Expr.path
          in
          ignore (Llvm.build_store v target b)
      | _ -> ())
  | Stat.Switch { value; cases } ->
      let v = Option.get (expr env fr b value) in
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
      let arena = call_runtime env b "zane_scope_enter" [||] in
      Hashtbl.replace fr.arenas id arena;
      fr.open_ <- arena :: fr.open_;
      stats env fr b body;
      if not (has_terminator b) then ignore (call_runtime env b "zane_scope_drain" [| arena |]);
      fr.open_ <- List.tl fr.open_
  | Stat.Host { id; scope; value; layout = l } -> (
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let size, align = size_align value.Expr.ty in
          let n x = Llvm.const_int env.i64 x in
          let arena = Hashtbl.find fr.arenas scope in
          let table = if l = [] then Llvm.const_null env.ptr else layout env l in
          let slot = call_runtime env b "zane_slot" [| arena; n size; n align; table |] in
          ignore (Llvm.build_store v slot b);
          (* The anchors the host brings follow it here (memory.md §4.5). *)
          if l <> [] then ignore (call_runtime env b "zane_arrive" [| slot; table |]);
          Hashtbl.replace fr.locals id (slot, Llvm.type_of v))
  | Stat.Store { address; value } -> (
      let p = Option.get (expr env fr b address) in
      match expr env fr b value with Some v -> ignore (Llvm.build_store v p b) | None -> ())
  | Stat.Overwrite { address; value; layout = l } -> (
      let p = Option.get (expr env fr b address) in
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let incoming = alloca env fr (Llvm.type_of v) in
          ignore (Llvm.build_store v incoming b);
          let size = Llvm.const_int env.i64 (fst (size_align value.Expr.ty)) in
          ignore (call_runtime env b "zane_overwrite" [| p; incoming; size; layout env l |]))
  | Stat.If { cond; body } ->
      let c = Option.get (expr env fr b cond) in
      let taken = block env fr and after = block env fr in
      ignore (Llvm.build_cond_br c taken after b);
      Llvm.position_at_end taken b;
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br after b);
      Llvm.position_at_end after b
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = Option.get (expr env fr b count) in
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

let func env (f : Func.t) =
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let fr =
    {
      fn;
      locals = Hashtbl.create 8;
      labels = Hashtbl.create 8;
      arenas = Hashtbl.create 4;
      open_ = [];
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
   since that is the name the runtime calls (L16). *)
let program (p : Program.t) =
  let ctx = Llvm.create_context () in
  let m = Llvm.create_module ctx "zane" in
  let env =
    {
      ctx;
      m;
      ptr = Llvm.pointer_type ctx;
      i64 = Llvm.i64_type ctx;
      funcs = Hashtbl.create 32;
      layouts = Hashtbl.create 8;
    }
  in
  List.iter
    (fun (f : Func.t) ->
      let fty = fn_type env (List.map snd f.Func.params) f.Func.ret in
      let name = if f.Func.symbol = p.Program.entry then "zane_main" else f.Func.symbol in
      let fn = Llvm.define_function name fty m in
      if name <> "zane_main" then Llvm.set_linkage Llvm.Linkage.Internal fn;
      Hashtbl.replace env.funcs f.Func.symbol (fn, fty))
    p.Program.funcs;
  List.iter (func env) p.Program.funcs;
  (match Llvm_analysis.verify_module m with
  | Some problem -> failwith ("codegen built an invalid module: " ^ problem)
  | None -> ());
  m
