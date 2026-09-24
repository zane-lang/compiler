(* Every type expression written inside a body, for a pass that asks a
   question of all of them without caring where each one sits.

   Semantics is the first to need this: whether a verb's `n
   @concepts$Integer` parameter is generic turns on whether any type in the
   verb, its body included, writes `n` where a number goes
   (docs/semantics.md §9). A body writes types in a local declaration and in
   a lambda's signature, and those can sit anywhere an expression or a block
   can. *)

open Nodes

let rec block acc (b : Block.t) = List.fold_left stat acc b.Block.stats

and stat acc (s : Stat.t) =
  match s.Stat.node with
  | Stat.VerbCall c | Stat.Spawn c -> verb_call acc c
  | Stat.Decl d -> decl acc d
  | Stat.Assign { target; value } -> expr (expr acc target) value
  | Stat.Abort e | Stat.Ret e | Stat.Resolve e -> expr acc e

(* A body declares symbols and nothing else; any other declaration there is
   an error semantics reports, so it has no types worth collecting. *)
and decl acc (d : Decl.t) =
  match d.Decl.node with
  | Decl.Var { type_; value; _ } -> expr (type_ :: acc) value
  | _ -> acc

and expr acc (e : Expr.t) =
  match e.Expr.node with
  | Expr.IntLit _ | Expr.DecimalLit _ | Expr.StrLit _ | Expr.BoolLit _ | Expr.NameExpr _
  | Expr.TypeMember _ | Expr.TypeValue _ ->
      acc
  | Expr.CollectionLit items -> List.fold_left expr acc items
  | Expr.DotAccess { target; abort_handle; _ } -> handle (expr acc target) abort_handle
  | Expr.Subscript { target; args } -> List.fold_left expr (expr acc target) args
  | Expr.Ref inner -> expr acc inner
  | Expr.Init fields -> List.fold_left field_arg acc fields
  | Expr.MapLit entries -> List.fold_left (fun acc (k, v) -> expr (expr acc k) v) acc entries
  | Expr.Spawn c | Expr.VerbCall c -> verb_call acc c
  | Expr.Match m ->
      let acc = List.fold_left expr acc m.Match_expr.scrutinees in
      let acc = List.fold_left (fun acc (a : Match_arm.t) -> block acc a.Match_arm.body) acc m.Match_expr.arms in
      handle acc m.Match_expr.abort_handle
  | Expr.FuncLambda l ->
      block (ret_type (List.fold_left param acc l.Func_lambda.params) l.Func_lambda.ret_type) l.Func_lambda.body
  | Expr.MethLambda l ->
      let acc = l.Meth_lambda.this_type :: acc in
      block (ret_type (List.fold_left param acc l.Meth_lambda.params) l.Meth_lambda.ret_type) l.Meth_lambda.body

and verb_call acc (c : Verb_call.t) =
  match c.Verb_call.node with
  | Verb_call.Call { callee; args; abort_handle; _ } ->
      handle (List.fold_left call_arg (expr acc callee) args) abort_handle
  | Verb_call.Constructor { args; abort_handle; _ } -> (
      handle
        (match args.Constructor_args.node with
        | Constructor_args.Positional ps -> List.fold_left call_arg acc ps
        | Constructor_args.Fields fs -> List.fold_left field_arg acc fs)
        abort_handle)
  | Verb_call.Op { left; right; abort_handle; _ } -> handle (expr (expr acc left) right) abort_handle
  | Verb_call.Flip { value; abort_handle } -> handle (expr acc value) abort_handle

and call_arg acc (a : Call_arg.t) =
  match a.Call_arg.node with Call_arg.Value e -> expr acc e | Call_arg.Block b -> block acc b

and field_arg acc (f : Field_arg.t) = expr acc f.Field_arg.value

and handle acc = function None -> acc | Some (h : Abort_handle.t) -> block acc h.Abort_handle.body

and param acc (p : Param.t) =
  match p.Param.type_.Param_type.node with Param_type.Concrete t -> t :: acc | _ -> acc

and ret_type acc (r : Ret_type.t) =
  match r.Ret_type.node with
  | Ret_type.Safe t -> t :: acc
  | Ret_type.Abort { ok; abort } -> abort :: ok :: acc

let type_exprs_of_block b = List.rev (block [] b)
let type_exprs_of_expr e = List.rev (expr [] e)
