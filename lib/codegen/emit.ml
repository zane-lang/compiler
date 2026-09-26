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

let rec expr env b locals (e : Expr.t) : Llvm.llvalue option =
  match e.Expr.node with
  | Expr.Int i -> Some (Llvm.const_of_int64 env.i64 i true)
  | Expr.Float f -> Some (Llvm.const_float (Llvm.double_type env.ctx) f)
  | Expr.Bool v -> Some (Llvm.const_int (Llvm.i1_type env.ctx) (if v then 1 else 0))
  | Expr.Text s -> Some (text env s)
  | Expr.Unit -> None
  | Expr.Local id -> Hashtbl.find_opt locals id
  | Expr.Call { fn; args } ->
      let f, fty = Hashtbl.find env.funcs fn in
      let args = Array.of_list (List.filter_map (expr env b locals) args) in
      let v = Llvm.build_call fty f args "" b in
      if e.Expr.ty = Ty.Void then None else Some v
  | Expr.Runtime { fn; args } ->
      let f, fty = runtime env fn in
      let args =
        List.concat_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env b locals a) with
            | Ty.View, Some v ->
                [ Llvm.build_extractvalue v 0 "" b; Llvm.build_extractvalue v 1 "" b ]
            | _, Some v -> [ v ]
            | _, None -> [])
          args
      in
      ignore (Llvm.build_call fty f (Array.of_list args) "" b);
      None

let has_terminator b =
  match Llvm.block_terminator (Llvm.insertion_block b) with Some _ -> true | None -> false

let func env (f : Func.t) =
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let locals = Hashtbl.create 8 in
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  List.iteri (fun i (id, _) -> Hashtbl.replace locals id (Llvm.param fn i)) kept;
  List.iter
    (fun (s : Stat.t) ->
      if not (has_terminator b) then
        match s with
        | Stat.Eval e -> ignore (expr env b locals e)
        | Stat.Return e -> (
            match expr env b locals e with
            | Some v when f.Func.ret <> Ty.Void -> ignore (Llvm.build_ret v b)
            | _ -> ignore (Llvm.build_ret_void b)))
    f.Func.body;
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
