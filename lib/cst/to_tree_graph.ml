open Tree_graph

(* =================================================== *)
(* rule: helpers return raw nodes, never self-wrap     *)
(* ---                                                 *)
(* a helper like name_type_to_node returns the Node    *)
(* for its value directly, it never calls group on     *)
(* its own output, even if that means the result       *)
(* looks "unlabeled" on its own.                       *)
(*                                                     *)
(*   let name_type_to_node x = match x with            *)
(*     | Ident s -> Leaf s                             *)
(*     | Qualified { .. } -> Leaf (...)                *)
(*     (* no group "name_type" (...) here *)           *)
(*                                                     *)
(* labeling is the caller's decision, not the callee's *)
(* the same value can be grouped under different names *)
(* depending on where it's used (a "type" field here,  *)
(* a "constructor" field there) or left ungrouped      *)
(* entirely if it's just one entry among fields [...]. *)
(* if a helper pre-wraps its own result, that decision *)
(* is made once and for all callers, even the ones     *)
(* that wanted a different label or no label at all.   *)
(* =================================================== *)

let name_type_to_node (x: Nodes.Name_type.t) = match x with
  | Ident s -> Leaf s
  | Qualified { package; ident } -> Leaf (package ^ "$" ^ ident)
  | Intrinsic { package; ident } -> Leaf ("@" ^ package ^ "$" ^ ident)

let name_expr_to_node (x: Nodes.Name_expr.t) = match x with
  | Ident s -> Leaf s
  | Qualified { package; ident } -> Leaf (package ^ "$" ^ ident)
  | Intrinsic { package; ident } -> Leaf ("@" ^ package ^ "$" ^ ident)

let rec concept_to_node (x: Nodes.Concept.t) = match x with
  | Type -> Leaf "Type"
  | Number -> Leaf "Number"

and param_type_to_node (x: Nodes.Param_type.t) = match x with
  | Concrete x -> type_to_node x
  | Concept x -> concept_to_node x

and verb_type_to_node (x: Nodes.Verb_type.t) = match x with
  | Func { params; ret_type } ->
      fields [
        ("param", map_seq param_type_to_node params);
        ("type",  ret_to_node ret_type);
      ]
  | Meth { this_type; params; ret_type; is_mut } ->
      fields [
        ("this_type", type_to_node this_type);
        ("param",     map_seq param_type_to_node params);
        ("type",      ret_to_node ret_type);
        ("is_mut",    Leaf (string_of_bool is_mut));
      ]

and body_field_to_node (x: Nodes.Body_field.t) =
  fields [
    ("name", Leaf x.name);
    ("type", type_to_node x.type_);
  ]

and mould_to_node (x: Nodes.Mould.t) = match x with
  | Struct x -> group "struct" (map_seq body_field_to_node x)
  | Variant x -> group "variant" (map_seq body_field_to_node x)
  | Enum x -> group "enum" (map_seq (fun x -> Leaf x) x)
  | Tuple x -> group "tuple" (map_seq type_to_node x)

and generic_arg_to_node (x: Nodes.Generic_arg.t) = match x with
  | Type x -> type_to_node x
  | Number x -> group "number" (Leaf x)
  | Inferred x -> group "param" (param_to_node x)

and type_to_node (x: Nodes.Type_expr.t) = match x with
  | Verb x -> verb_type_to_node x
  | Parenthesized x -> group "parenthesized" (type_to_node x)
  | Path { name; generics } ->
      fields [
        ("qualifier", name_type_to_node name);
        ("args", map_seq generic_arg_to_node generics);
      ]

and abort_field abort_handle =
  ("abort", Option.fold ~none:(Leaf "none") ~some:abort_handle_to_node abort_handle)

and verb_call_to_node (x: Nodes.Verb_call.t) = match x with
  | Func { callee; args; abort_handle } ->
      group "func_call" (fields [
        ("callee", expr_to_node callee);
        ("args", map_seq expr_to_node args);
        abort_field abort_handle;
      ])
  | Meth { callee; this; args; abort_handle; is_mut } ->
      group "meth_call" (fields [
        ("callee", expr_to_node callee);
        ("this", expr_to_node this);
        ("args", map_seq expr_to_node args);
        ("is_mut", Leaf (string_of_bool is_mut));
        abort_field abort_handle;
      ])
  | Constructor { name_type; args; abort_handle } ->
      group "ctor_call" (fields [
        ("type", name_type_to_node name_type);
        ("args", map_seq expr_to_node args);
        abort_field abort_handle;
      ])
  | Op { op; left; right; abort_handle } ->
      group "op_call" (fields [
        ("op", Leaf (op_to_name op));
        ("left", expr_to_node left);
        ("right", expr_to_node right);
        abort_field abort_handle;
      ])
  | Flip { value; abort_handle } ->
      group "flip_call" (fields [
        ("value", expr_to_node value);
        abort_field abort_handle;
      ])

and expr_to_node (x: Nodes.Expr.t) = match x with
  | IntLit x   -> Leaf x
  | FloatLit x -> Leaf x
  | StrLit x   -> Leaf x
  | BoolLit x  -> Leaf (string_of_bool x)
  | NameExpr x -> name_expr_to_node x
  | DotAccess { target; field } ->
      group "dot_access" (fields [
        ("target", expr_to_node target);
        ("field", Leaf field);
      ])
  | Ref x ->
      group "ref" (expr_to_node x)
  | Parenthized x ->
      group "parenthized" (expr_to_node x)
  | FuncLambda x ->
      group "func_lambda" (func_lambda_to_node x)
  | MethLambda x ->
      group "meth_lambda" (meth_lambda_to_node x)
  | VerbCall x ->
      verb_call_to_node x

and op_to_name (x: Nodes.Operator.t) = match x with
  | Add     -> "+"
  | Sub     -> "-"
  | Mul     -> "*"
  | Div     -> "/"
  | Eq      -> "=="
  | LessEq  -> "<="
  | MoreEq  -> ">="
  | Less    -> "<"
  | More    -> ">"

and abort_handle_to_node (x: Nodes.Abort_handle.t) = match x with
  | Longhand { binder; body } ->
      let fs = [("body", body_to_node body)] in
      let fs = match binder with
        | Some b -> ("binder", Leaf b) :: fs
        | None   -> fs
      in
      group "longhand" (fields fs)
  | Shorthand x -> group "shorthand" (expr_to_node x)

and param_to_node (x: Nodes.Param.t) =
  fields [
    ("name", Leaf x.name);
    ("type", param_type_to_node x.type_);
  ]

and params_to_node (x: Nodes.Param.t list) =
  map_seq param_to_node x

and elif_to_fields (x: Nodes.Cond_block.t) =
  fields [
    ("cond", expr_to_node x.cond);
    ("block", map_seq stat_to_node x.block);
  ]

(* The optional fields below are appended in source order rather than consed
   onto the front, so the list reads the way the construct does. *)
and cond_seq_to_node (x: Nodes.Cond_seq.t) =
  let else_ = match x.else_ with
    | Some x -> [("else", fields [("block", map_seq stat_to_node x)])]
    | None   -> []
  in
  fields ([
    ("if", fields [
      ("cond", expr_to_node x.if_.cond);
      ("block", map_seq stat_to_node x.if_.block);
    ]);
    ("elif", map_seq elif_to_fields x.elifs_);
  ] @ else_)

and loop_to_node (x: Nodes.Loop.t) =
  let start = match x.start with
    | Some x -> [("start", expr_to_node x)]
    | None   -> []
  in
  let fs = start @ [
    ("stats", map_seq stat_to_node x.body);
    ("end", expr_to_node x.end_);
    ("binder", Leaf x.binder);
  ] in
  fields fs

and stat_to_node (x: Nodes.Stat.t) = match x with
  | VerbCall x -> verb_call_to_node x
  | Decl x     -> decl_to_node x
  | Abort x    -> group "abort_stat"   (expr_to_node x)
  | Ret x      -> group "ret_stat"     (expr_to_node x)
  | Resolve x  -> group "resolve_stat" (expr_to_node x)
  | CondSeq x  -> cond_seq_to_node x
  | Loop x     -> group "loop" (loop_to_node x)

and body_to_node (x: Nodes.Body.t) = match x with
  | Longhand x ->
      group "scope" (fields [
        ("stat", map_seq stat_to_node x);
      ])
  | Shorthand x ->
      group "ret_shorthand" (expr_to_node x)

and ret_to_node (x: Nodes.Ret_type.t) = match x with
  | Safe ret -> type_to_node ret
  | Abort { ok; abort } ->
      fields [
        ("safe_type",  type_to_node ok);
        ("abort_type", type_to_node abort);
      ]
  | Parenthesized ret -> group "parenthesized" (ret_to_node ret)

and func_lambda_to_node (x: Nodes.Func_lambda.t) =
  fields [
    ("param",    params_to_node x.params);
    ("ret_type", ret_to_node x.ret_type);
    ("body",     body_to_node x.body);
  ]

and meth_lambda_to_node (x: Nodes.Meth_lambda.t) =
  fields [
    ("this_type", type_to_node x.this_type);
    ("param",     params_to_node x.params);
    ("ret_type",  ret_to_node x.ret_type);
    ("body",      body_to_node x.body);
    ("is_mut",    Leaf (string_of_bool x.is_mut));
  ]

and type_axis_to_node (x: Nodes.Type_axis.t) = match x with
  | Value -> Leaf "value"
  | Reference -> Leaf "reference"

and moulded_to_node (x: Nodes.Moulded.t) =
  fields [
    ("mould", mould_to_node x.mould);
    ("type_axis", type_axis_to_node x.axis);
  ]

and type_or_moulded_to_node (x: Nodes.Type_or_moulded.t) = match x with
  | Raw x -> type_to_node x
  | Moulded x -> moulded_to_node x

and decl_to_node (x: Nodes.Decl.t) = match x with
  | Var { name; type_; value } ->
      group "var_decl" (fields [
        ("name",  Leaf name);
        ("type",  type_to_node type_);
        ("value", expr_to_node value);
      ])
  | VarShorthand { name; constructor; args } ->
      group "var_decl_shorthand" (fields [
        ("name", Leaf name);
        ("type", name_type_to_node constructor);
        ("args", map_seq expr_to_node args);
      ])
  | Type x ->
      group "type_decl" (fields [
        ("name",   Leaf x.name);
        ("params", map_seq generic_param_to_node x.params);
        ("value",  type_or_moulded_to_node x.value);
      ])
  | Alias x ->
      group "alias_decl" (fields [
        ("name",   Leaf x.name);
        ("params", map_seq generic_param_to_node x.params);
        ("value",  type_to_node x.value);
      ])
  | Verb x -> verb_decl_to_node x

and verb_decl_to_node (x: Nodes.Verb_decl.t) = match x with
  | Func x ->
      group "func_decl" (fields [
        ("name",     Leaf x.name);
        ("param",    params_to_node x.params);
        ("ret_type", ret_to_node x.ret_type);
        ("body",     body_to_node x.body);
      ])
  | Meth x ->
      group "meth_decl" (fields [
        ("name",      Leaf x.name);
        ("this_type", type_to_node x.this_type);
        ("param",     params_to_node x.params);
        ("ret_type",  ret_to_node x.ret_type);
        ("body",      body_to_node x.body);
        ("is_mut",    Leaf (string_of_bool x.is_mut));
      ])
  | Constructor x ->
      group "ctor_decl" (fields [
        ("type",  name_type_to_node x.type_);
        ("param", params_to_node x.params);
        ("body",  body_to_node x.body);
      ])
  | Op x ->
      group "op_decl" (fields [
        ("op",       Leaf (op_to_name x.op));
        ("param",    params_to_node x.params);
        ("ret_type", ret_to_node x.ret_type);
        ("body",     body_to_node x.body);
      ])
  | Flip x ->
      group "flip_decl" (fields [
        ("param",    params_to_node x.params);
        ("ret_type", ret_to_node x.ret_type);
        ("body",     body_to_node x.body);
      ])

and generic_param_to_node (x: Nodes.Generic_param.t) =
  fields [
    ("name", Leaf x.name);
    ("type", concept_to_node x.type_);
  ]

let to_node ({ decls }: Nodes.Package.t) =
  group "package" (fields [
    ("declarations", map_seq decl_to_node decls);
  ])
