open Tree_graph

let rec type_to_node (x: Nodes.type_expr) = match x with
  | SimpleType s              -> Leaf s
  | QualifiedType (pkg, type_) -> Leaf (pkg ^ "$" ^ type_)
  | FuncType { params; ret_type } ->
      fields [
        ("param", map_seq type_to_node params);
        ("type",  type_to_node ret_type);
      ]
  | MethType { this_type; params; ret_type; is_mut } ->
      fields [
        ("this_type", type_to_node this_type);
        ("param",     map_seq type_to_node params);
        ("type",      type_to_node ret_type);
        ("is_mut",    Leaf (string_of_bool is_mut));
      ]

and expr_to_node (x: Nodes.expr) = match x with
  | IntLit x              -> Leaf x
  | FloatLit x                  -> Leaf x
  | StrLit x                    -> Leaf x
  | BoolLit x                   -> Leaf (string_of_bool x)
  | Ident x                     -> Leaf x
  | QualifiedIdent (pkg, name)  -> Leaf (pkg ^ "$" ^ name)
  | Op x ->
      fields [
        (op_to_name x.operator, fields [
          ("left",  expr_to_node x.left);
          ("right", expr_to_node x.right);
        ]);
      ]
  | Flip x ->
      group "flip" (expr_to_node x)
  | Parenthized x ->
      group "parenthized" (expr_to_node x)
  | FuncCall x ->
      func_call_to_node x
  | FuncLambda x ->
      group "func_lambda" (func_lambda_to_node x)
  | MethLambda x ->
      group "meth_lambda" (meth_lambda_to_node x)

and op_to_name (x : Nodes.operator) = match x with
  | Add     -> "+"
  | Sub     -> "-"
  | Mul     -> "*"
  | Div     -> "/"
  | Eq      -> "=="
  | LessEq  -> "<="
  | MoreEq  -> ">="
  | Less    -> "<"
  | More    -> ">"

and abort_handle_to_node (x : Nodes.abort_handle) = match x with
  | AbortBody x      -> body_to_node x
  | AbortShorthand x -> expr_to_node x

and func_call_to_node x = match x with
  | SafeCall x ->
      group "function_call" (fields [
        ("callee", expr_to_node x.callee);
        ("args",   map_seq expr_to_node x.args);
      ])
  | AbortCall x ->
      let fs = [
        ("callee",       expr_to_node x.callee);
        ("args",         map_seq expr_to_node x.args);
        ("handle_block", abort_handle_to_node x.handle_block);
      ] in
      let fs = match x.binder with
        | Some b -> ("binder", Leaf b) :: fs
        | None   -> fs
      in
      group "function_call" (fields fs)

and param_to_node (x : Nodes.param) =
  fields [
    ("name", Leaf x.name);
    ("type", type_to_node x.type_);
  ]

and params_to_node (x : Nodes.param list) =
  map_seq param_to_node x

and stat_to_node (x : Nodes.stat) = match x with
  | FuncCallStat x -> func_call_to_node x
  | DeclStat x     -> decl_to_node x
  | AbortStat x    -> group "abort_stat"   (expr_to_node x)
  | RetStat x      -> group "ret_stat"     (expr_to_node x)
  | ResolveStat x  -> group "resolve_stat" (expr_to_node x)

and body_to_node (x : Nodes.body) = match x with
  | Scope scope ->
      group "scope" (fields [
        ("stat", map_seq stat_to_node scope);
      ])
  | RetShorthand x ->
      group "ret_shorthand" (expr_to_node x)

and ret_to_node (x : Nodes.ret_type) = match x with
  | SafeRet ret -> type_to_node ret
  | AbortRet (ret_type, abort_type) ->
      fields [
        ("safe_type",  type_to_node ret_type);
        ("abort_type", type_to_node abort_type);
      ]

and func_lambda_to_node (x : Nodes.func_lambda) =
  fields [
    ("param",    params_to_node x.params);
    ("ret_type", ret_to_node x.ret_type);
    ("body",     body_to_node x.body);
  ]

and meth_lambda_to_node (x : Nodes.meth_lambda) =
  fields [
    ("this_type", type_to_node x.this_type);
    ("param",     params_to_node x.params);
    ("ret_type",  ret_to_node x.ret_type);
    ("body",      body_to_node x.body);
    ("is_mut",    Leaf (string_of_bool x.is_mut));
  ]

and decl_to_node (x: Nodes.decl) = match x with
  | FuncDecl x ->
      group "func_decl" (fields [
        ("name", Leaf x.name);
        ("func", func_lambda_to_node x.func);
      ])
  | MethDecl x ->
      group "meth_decl" (fields [
        ("name", Leaf x.name);
        ("func", meth_lambda_to_node x.func);
      ])
  | VarDecl { name; type_; value } ->
      group "var_decl" (fields [
        ("name",  Leaf name);
        ("type",  type_to_node type_);
        ("value", expr_to_node value);
      ])
  | ConstructorDecl { name; type_; args } ->
      group "constructor_decl" (fields [
        ("name", Leaf name);
        ("type", type_to_node type_);
        ("args", map_seq expr_to_node args);
      ])

let to_node ({ Nodes.decls } : Nodes.package) =
  group "package" (fields [
    ("declarations", map_seq decl_to_node decls);
  ])
