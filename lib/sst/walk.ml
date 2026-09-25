(* Every type expression and every call written inside a body, for a pass that
   asks a question of all of them without caring where each one sits.

   Semantics is the first to need this: whether a verb's `n
   @concepts$Integer` parameter is generic turns on whether the verb writes
   `n` where a number goes -- in a type, or as the argument to another verb's
   number parameter (docs/semantics.md §9). A body writes types in a local
   declaration and in a lambda's signature, and calls anywhere an expression
   or a block can sit.

   One fold serves both: [visitor] says what to do at a type expression and at
   a call, and the walk reaches every one of each. *)

open Nodes

type 'a visitor = {
  type_expr : 'a -> Type_expr.t -> 'a;
  (* Called before the call's own arguments are walked. *)
  call : 'a -> Verb_call.t -> 'a;
}

let rec block v acc (b : Block.t) = List.fold_left (stat v) acc b.Block.stats

and stat v acc (s : Stat.t) =
  match s.Stat.node with
  | Stat.VerbCall c | Stat.Spawn c -> verb_call v acc c
  | Stat.Decl d -> decl v acc d
  | Stat.Assign { target; value } -> expr v (expr v acc target) value
  | Stat.Abort e | Stat.Ret e | Stat.Resolve e -> expr v acc e

(* A body declares symbols and nothing else; any other declaration there is
   an error semantics reports, so it has nothing worth collecting. *)
and decl v acc (d : Decl.t) =
  match d.Decl.node with
  | Decl.Var { type_; value; _ } -> expr v (v.type_expr acc type_) value
  | _ -> acc

and expr v acc (e : Expr.t) =
  match e.Expr.node with
  | Expr.IntLit _ | Expr.DecimalLit _ | Expr.StrLit _ | Expr.BoolLit _ | Expr.NameExpr _
  | Expr.TypeMember _ | Expr.TypeValue _ ->
      acc
  | Expr.CollectionLit items -> List.fold_left (expr v) acc items
  | Expr.DotAccess { target; abort_handle; _ } -> handle v (expr v acc target) abort_handle
  | Expr.Subscript { target; args } -> List.fold_left (expr v) (expr v acc target) args
  | Expr.Ref inner -> expr v acc inner
  | Expr.Init fields -> List.fold_left (field_arg v) acc fields
  | Expr.MapLit entries -> List.fold_left (fun acc (k, x) -> expr v (expr v acc k) x) acc entries
  | Expr.Spawn c | Expr.VerbCall c -> verb_call v acc c
  | Expr.Match m ->
      let acc = List.fold_left (expr v) acc m.Match_expr.scrutinees in
      let acc =
        List.fold_left (fun acc (a : Match_arm.t) -> block v acc a.Match_arm.body) acc m.Match_expr.arms
      in
      handle v acc m.Match_expr.abort_handle
  | Expr.FuncLambda l ->
      let acc = List.fold_left (param v) acc l.Func_lambda.params in
      block v (ret_type v acc l.Func_lambda.ret_type) l.Func_lambda.body
  | Expr.MethLambda l ->
      let acc = v.type_expr acc l.Meth_lambda.this_type in
      let acc = List.fold_left (param v) acc l.Meth_lambda.params in
      block v (ret_type v acc l.Meth_lambda.ret_type) l.Meth_lambda.body

and verb_call v acc (c : Verb_call.t) =
  let acc = v.call acc c in
  match c.Verb_call.node with
  | Verb_call.Call { callee; args; abort_handle; _ } ->
      handle v (List.fold_left (call_arg v) (expr v acc callee) args) abort_handle
  | Verb_call.Constructor { args; abort_handle; _ } ->
      handle v
        (match args.Constructor_args.node with
        | Constructor_args.Positional ps -> List.fold_left (call_arg v) acc ps
        | Constructor_args.Fields fs -> List.fold_left (field_arg v) acc fs)
        abort_handle
  | Verb_call.Op { left; right; abort_handle; _ } -> handle v (expr v (expr v acc left) right) abort_handle
  | Verb_call.Flip { value; abort_handle } -> handle v (expr v acc value) abort_handle

and call_arg v acc (a : Call_arg.t) =
  match a.Call_arg.node with Call_arg.Value e -> expr v acc e | Call_arg.Block b -> block v acc b

and field_arg v acc (f : Field_arg.t) = expr v acc f.Field_arg.value

and handle v acc = function None -> acc | Some (h : Abort_handle.t) -> block v acc h.Abort_handle.body

and param v acc (p : Param.t) =
  match p.Param.type_.Param_type.node with Param_type.Concrete t -> v.type_expr acc t | _ -> acc

and ret_type v acc (r : Ret_type.t) =
  match r.Ret_type.node with
  | Ret_type.Safe t -> v.type_expr acc t
  | Ret_type.Abort { ok; abort } -> v.type_expr (v.type_expr acc ok) abort

let collect_types = { type_expr = (fun acc t -> t :: acc); call = (fun acc _ -> acc) }
let collect_calls = { type_expr = (fun acc _ -> acc); call = (fun acc c -> c :: acc) }

let type_exprs_of_block b = List.rev (block collect_types [] b)
let type_exprs_of_expr e = List.rev (expr collect_types [] e)
let calls_of_block b = List.rev (block collect_calls [] b)
let calls_of_expr e = List.rev (expr collect_calls [] e)
