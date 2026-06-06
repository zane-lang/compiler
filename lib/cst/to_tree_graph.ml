open Tree_graph

let rec type_to_node = function
  | Nodes.SimpleType s              -> Leaf s
  | Nodes.QualifiedType (pkg, type_) -> Leaf (pkg ^ type_)
  | Nodes.FuncType { params; ret_type } ->
      fields [
        ("param", map_seq type_to_node params);
        ("type",  type_to_node ret_type);
      ]
  | Nodes.MethType { this_type; params; ret_type; is_mut } ->
      fields [
        ("this_type", type_to_node this_type);
        ("param",     map_seq type_to_node params);
        ("type",      type_to_node ret_type);
        ("is_mut",    Leaf (string_of_bool is_mut));
      ]

and expr_to_node (x : Nodes.expr) = match x with
  | Nodes.IntLit x                    -> Leaf x
  | Nodes.FloatLit x                  -> Leaf x
  | Nodes.StrLit x                    -> Leaf x
  | Nodes.BoolLit x                   -> Leaf (string_of_bool x)
  | Nodes.Ident x                     -> Leaf x
  | Nodes.QualifiedIdent (pkg, name)  -> Leaf (pkg ^ "$" ^ name)
  | Nodes.Op x ->
      fields [
        (op_to_name x.operator, fields [
          ("left",  expr_to_node x.left);
          ("right", expr_to_node x.right);
        ]);
      ]
  | Nodes.Parenthized x ->
      group "Parenthized" (expr_to_node x)
  | Nodes.FuncCall x ->
      func_call_to_node x
  | Nodes.FuncLambda x ->
      group "func_decl" (func_lambda_to_node x)
  | Nodes.MethLambda x ->
      group "meth_lambda" (meth_lambda_to_node x)

and op_to_name (x : Nodes.operator) = match x with
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "*"

and abort_handle_to_node (x : Nodes.abort_handle) = match x with
  | Nodes.AbortBody x      -> body_to_node x
  | Nodes.AbortShorthand x -> expr_to_node x

and func_call_to_node x = match x with
  | Nodes.SafeCall x ->
      group "function_call" (fields [
        ("callee", expr_to_node x.callee);
        ("arg",    map_seq expr_to_node x.args);
      ])
  | Nodes.AbortCall x ->
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
  | Nodes.FuncCallStat x -> func_call_to_node x
  | Nodes.DeclStat x     -> decl_to_node x
  | Nodes.AbortStat x    -> group "abort_stat"   (expr_to_node x)
  | Nodes.RetStat x      -> group "ret_stat"     (expr_to_node x)
  | Nodes.ResolveStat x  -> group "resolve_stat" (expr_to_node x)

and body_to_node (x : Nodes.body) = match x with
  | Nodes.Scope scope ->
      group "scope" (fields [
        ("stat", map_seq stat_to_node scope);
      ])
  | Nodes.RetShorthand x ->
      group "ret_shorthand" (expr_to_node x)

and ret_to_node (x : Nodes.ret_type) = match x with
  | Nodes.SafeRet ret -> type_to_node ret
  | Nodes.AbortRet (ret_type, abort_type) ->
      fields [
        ("safe_type",  type_to_node abort_type);
        ("abort_type", type_to_node ret_type);
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

and decl_to_node = function
  | Nodes.FuncDecl x ->
      group "func_decl" (fields [
        ("name", Leaf x.name);
        ("func", func_lambda_to_node x.func);
      ])
  | Nodes.MethDecl x ->
      group "func_decl" (fields [
        ("name", Leaf x.name);
        ("func", meth_lambda_to_node x.func);
      ])
  | Nodes.VarDecl { name; type_; value } ->
      group "var_decl" (fields [
        ("name",  Leaf name);
        ("type",  type_to_node type_);
        ("value", expr_to_node value);
      ])
  | Nodes.ConstructorDecl { name; type_; args } ->
      group "constructor_decl" (fields [
        ("name", Leaf name);
        ("type", type_to_node type_);
        ("args", map_seq expr_to_node args);
      ])

let to_node ({ Nodes.decls } : Nodes.package) =
  group "package" (fields [
    ("declarations", map_seq decl_to_node decls);
  ])
