(* The CGT as an LLVM module (docs/lowering.md L1, L2). Every CGT function is
   one LLVM function and every CGT type one LLVM type; nothing is decided
   here that the tree has not already said. *)

open Cgt.Nodes

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  (* A string view is passed to the runtime as its two halves, which is how C
     receives a pointer and a length. *)
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  funcs : (string, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
}

let lltype env (t : Ty.t) =
  match t with
  | Ty.Void -> Llvm.void_type env.ctx
  | Ty.I1 -> Llvm.i1_type env.ctx
  | Ty.I64 -> env.i64
  | Ty.F64 -> Llvm.double_type env.ctx
  | Ty.View -> Llvm.struct_type env.ctx [| env.ptr; env.i64 |]

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
        | "zane_print" -> Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.i64 |]
        | "zane_divide_by_zero" -> Llvm.function_type (Llvm.void_type env.ctx) [||]
        | _ -> failwith ("codegen: unknown runtime function " ^ name)
      in
      let f = Llvm.declare_function name fty env.m in
      Hashtbl.replace env.funcs name (f, fty);
      (f, fty)

(* A string literal is constant bytes the module owns, with no terminator. *)
let text env s =
  let bytes = Llvm.const_string env.ctx s in
  let g = Llvm.define_global "zane.text" bytes env.m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  Llvm.set_unnamed_addr true g;
  Llvm.const_struct env.ctx [| g; Llvm.const_int env.i64 (String.length s) |]

(* What a function being built keeps: its slots, and the exit block of each
   expansion it is inside. *)
type frame = {
  fn : Llvm.llvalue;
  locals : (int, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  labels : (int, Llvm.llbasicblock) Hashtbl.t;
  ret : Ty.t;
}

(* Every local is a stack slot in the entry block (L3); LLVM's `mem2reg`
   promotes the ones that can live in registers. *)
let alloca env fr t =
  let top = Llvm.builder_at env.ctx (Llvm.instr_begin (Llvm.entry_block fr.fn)) in
  Llvm.build_alloca t "" top

let slot env fr id t =
  let s = alloca env fr t in
  Hashtbl.replace fr.locals id (s, t);
  s

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
  | Expr.Int i -> Some (Llvm.const_of_int64 env.i64 i true)
  | Expr.Float f -> Some (Llvm.const_float (Llvm.double_type env.ctx) f)
  | Expr.Bool v -> Some (Llvm.const_int (Llvm.i1_type env.ctx) (if v then 1 else 0))
  | Expr.Text s -> Some (text env s)
  | Expr.Unit -> None
  | Expr.Local id ->
      Option.map (fun (slot, t) -> Llvm.build_load t slot "" b) (Hashtbl.find_opt fr.locals id)
  | Expr.Call { fn; args } ->
      let f, fty = Hashtbl.find env.funcs fn in
      let args = Array.of_list (List.filter_map (expr env fr b) args) in
      let v = Llvm.build_call fty f args "" b in
      if e.Expr.ty = Ty.Void then None else Some v
  | Expr.Runtime { fn; args } ->
      let f, fty = runtime env fn in
      let args =
        List.concat_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env fr b a) with
            | Ty.View, Some v ->
                let bytes = Llvm.build_extractvalue v 0 "" b in
                let length = Llvm.build_extractvalue v 1 "" b in
                [ bytes; length ]
            | _, Some v -> [ v ]
            | _, None -> [])
          args
      in
      ignore (Llvm.build_call fty f (Array.of_list args) "" b);
      None
  | Expr.Binary { op; left; right } -> (
      match (expr env fr b left, expr env fr b right) with
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
      Hashtbl.replace fr.labels label exit;
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
  | Stat.Assign { id; value } -> (
      match (expr env fr b value, Hashtbl.find_opt fr.locals id) with
      | Some v, Some (s, _) -> ignore (Llvm.build_store v s b)
      | _ -> ())
  | Stat.Eval e -> ignore (expr env fr b e)
  | Stat.Return e -> (
      match expr env fr b e with
      | Some v when fr.ret <> Ty.Void -> ignore (Llvm.build_ret v b)
      | _ -> ignore (Llvm.build_ret_void b))
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
  | Stat.Leave label -> ignore (Llvm.build_br (Hashtbl.find fr.labels label) b)

let func env (f : Func.t) =
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let fr = { fn; locals = Hashtbl.create 8; labels = Hashtbl.create 8; ret = f.Func.ret } in
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
    { ctx; m; ptr = Llvm.pointer_type ctx; i64 = Llvm.i64_type ctx; funcs = Hashtbl.create 32 }
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
