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
  | InferredType { name; concept } ->
      fields [
        ("name", Leaf name);
        ("concept", concept_to_node concept);
      ]

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

and generic_arg_to_node (x: Nodes.Generic_arg.t) = match x with
  | Type x -> type_to_node x
  | Number x -> group "number" (Leaf x)
  | NumberRef x -> group "number_ref" (Leaf x)
  | Inferred x -> group "param" (param_to_node x)

and type_to_node (x: Nodes.Type_expr.t) = match x with
  | Verb x -> verb_type_to_node x
  | Guest x -> group "guest" (type_to_node x)
  | Parenthesized x -> group "parenthesized" (type_to_node x)
  | Path { name; generics } ->
      fields [
        ("qualifier", name_type_to_node name);
        ("args", map_seq generic_arg_to_node generics);
      ]

and abort_field abort_handle =
  ("abort", Option.fold ~none:(Leaf "none") ~some:abort_handle_to_node abort_handle)

(* Optional fields are appended in source order rather than consed onto the
   front, here and everywhere below, so the list reads the way the construct
   does. *)
and field_arg_to_node (x: Nodes.Field_arg.t) =
  let fs = [("name", Leaf x.name)] in
  let fs = match x.value with
    | Some value -> fs @ [("value", expr_to_node value)]
    | None -> fs
  in
  fields fs

and call_arg_to_node (x: Nodes.Call_arg.t) = match x with
  | Value x -> expr_to_node x
  | Block stats ->
      group "block" (fields [("stat", map_seq statement_to_node stats)])

and constructor_args_to_node (x: Nodes.Constructor_args.t) = match x with
  | Positional args -> map_seq call_arg_to_node args
  | Fields args -> group "fields" (map_seq field_arg_to_node args)

and verb_call_to_node (x: Nodes.Verb_call.t) = match x with
  | Func { callee; args; abort_handle; trailing } ->
      group "func_call" (fields [
        ("callee", expr_to_node callee);
        ("args", map_seq call_arg_to_node args);
        ("trailing", Leaf (string_of_bool trailing));
        abort_field abort_handle;
      ])
  | Meth { callee; this; args; abort_handle; is_mut; trailing } ->
      group "meth_call" (fields [
        ("callee", expr_to_node callee);
        ("this", expr_to_node this);
        ("args", map_seq call_arg_to_node args);
        ("is_mut", Leaf (string_of_bool is_mut));
        ("trailing", Leaf (string_of_bool trailing));
        abort_field abort_handle;
      ])
  | Constructor { name; args; abort_handle } ->
      let fs = [("type", name_type_to_node name.type_)] in
      let fs = match name.member with
        | Some member -> fs @ [("member", Leaf member)]
        | None -> fs
      in
      group "ctor_call" (fields (fs @ [
        ("args", constructor_args_to_node args);
        abort_field abort_handle;
      ]))
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

and match_pattern_to_node (x: Nodes.Match_pattern.t) =
  let fs = [("cases", map_seq (fun case -> Leaf case) x.cases)] in
  let fs = match x.binder with
    | Some binder -> ("binder", Leaf binder) :: fs
    | None -> fs
  in
  fields fs

and match_arm_to_node (x: Nodes.Match_arm.t) =
  fields [
    ("patterns", map_seq match_pattern_to_node x.patterns);
    ("body", body_to_node x.body);
  ]

and match_expr_to_node (x: Nodes.Match_expr.t) =
  fields [
    ("scrutinees", map_seq expr_to_node x.scrutinees);
    ("arms", map_seq match_arm_to_node x.arms);
    abort_field x.abort_handle;
  ]

and expr_to_node (x: Nodes.Expr.t) = match x with
  | IntLit x   -> Leaf x
  | FloatLit x -> Leaf x
  | StrLit x   -> Leaf x
  | BoolLit x  -> Leaf (string_of_bool x)
  | CollectionLit x -> group "collection" (map_seq expr_to_node x)
  | NameExpr x -> name_expr_to_node x
  | TypeMember { type_; member } ->
      group "type_member" (fields [
        ("type", name_type_to_node type_);
        ("member", Leaf member);
      ])
  | TypeValue type_ ->
      group "type_value" (fields [ ("type", name_type_to_node type_) ])
  | DotAccess { target; field } ->
      group "dot_access" (fields [
        ("target", expr_to_node target);
        ("field", Leaf field);
      ])
  | Subscript { target; args } ->
      group "subscript" (fields [
        ("target", expr_to_node target);
        ("args", map_seq expr_to_node args);
      ])
  | Ref x ->
      group "ref" (expr_to_node x)
  | Parenthized x ->
      group "parenthized" (expr_to_node x)
  | Init fields_ ->
      group "init" (map_seq field_arg_to_node fields_)
  | MapLit entries ->
      group "map_lit" (map_seq map_entry_to_node entries)
  | MethodTarget { callee; this; is_mut } ->
      group "method_target" (fields [
        ("callee", expr_to_node callee);
        ("this", expr_to_node this);
        ("is_mut", Leaf (string_of_bool is_mut));
      ])
  | Pipe { callee; value; abort_handle } ->
      group "pipe" (fields [
        ("callee", expr_to_node callee);
        ("value", expr_to_node value);
        abort_field abort_handle;
      ])
  | Spawn call ->
      group "spawn" (verb_call_to_node call)
  | Logic { op; left; right } ->
      group "logic" (fields [
        ("op", Leaf (match op with Nodes.Logic_op.And -> "and" | Or -> "or"));
        ("left", expr_to_node left);
        ("right", expr_to_node right);
      ])
  | Match match_ ->
      group "match" (match_expr_to_node match_)
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
  | NotEq   -> "~="
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

and constructor_field_to_node (x: Nodes.Constructor_field.t) =
  let fs = [
    ("name", Leaf x.name);
    ("type", param_type_to_node x.type_);
  ] in
  let fs = match x.default with
    | Some default -> fs @ [("default", expr_to_node default)]
    | None -> fs
  in
  fields fs

(* The terminator mark is not printed: a tree that reaches a consumer has
   already been checked, so every mark on it is [None]. *)
and statement_to_node (x: Nodes.Statement.t) = stat_to_node x.stat

and stat_to_node (x: Nodes.Stat.t) = match x with
  | VerbCall x -> verb_call_to_node x
  | Spawn x    -> group "spawn_stat" (verb_call_to_node x)
  | Decl x     -> decl_to_node x
  | Assign { target; value } ->
      group "assign_stat" (fields [
        ("target", expr_to_node target);
        ("value", expr_to_node value);
      ])
  | Abort x    -> group "abort_stat"   (expr_to_node x)
  | Ret x      -> group "ret_stat"     (expr_to_node x)
  | Resolve x  -> group "resolve_stat" (expr_to_node x)

and body_to_node (x: Nodes.Body.t) = match x with
  | Longhand x ->
      group "scope" (fields [
        ("stat", map_seq statement_to_node x);
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

and import_member_to_node (x: Nodes.Import_member.t) =
  fields [
    ("name", Leaf x.name);
    ("is_type", Leaf (string_of_bool x.is_type));
  ]

and import_to_node (x: Nodes.Import.t) = match x with
  | Package { package; alias } ->
      let fs = [("package", Leaf package)] in
      let fs = match alias with
        | Some alias -> fs @ [("alias", Leaf alias)]
        | None -> fs
      in
      group "import_package" (fields fs)
  | Member { package; member; alias } ->
      let fs = [
        ("package", Leaf package);
        ("member", import_member_to_node member);
      ] in
      let fs = match alias with
        | Some alias -> fs @ [("alias", import_member_to_node alias)]
        | None -> fs
      in
      group "import_member" (fields fs)
  | Members { package; members } ->
      group "import_members" (fields [
        ("package", Leaf package);
        ("members", map_seq import_member_to_node members);
      ])
  | All { package } ->
      group "import_all" (fields [("package", Leaf package)])

and map_entry_to_node (key, value) =
  fields [
    ("key", expr_to_node key);
    ("value", expr_to_node value);
  ]

and enum_map_entry_to_node (member, value) =
  fields [
    ("member", Leaf member);
    ("value", expr_to_node value);
  ]

and decl_to_node (x: Nodes.Decl.t) = match x with
  | Package name -> group "package_decl" (Leaf name)
  | Import value -> group "import_decl" (import_to_node value)
  | Var { name; type_; value } ->
      group "var_decl" (fields [
        ("name",  Leaf name);
        ("type",  type_to_node type_);
        ("value", expr_to_node value);
      ])
  | VarShorthand { name; constructor; args } ->
      let fs = [
        ("name", Leaf name);
        ("type", name_type_to_node constructor.type_);
      ] in
      let fs = match constructor.member with
        | Some member -> fs @ [("member", Leaf member)]
        | None -> fs
      in
      group "var_decl_shorthand"
        (fields (fs @ [("args", constructor_args_to_node args)]))
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
        ("value",  type_or_moulded_to_node x.value);
      ])
  | EnumMap x ->
      group "enum_map_decl" (fields [
        ("enum", type_to_node x.enum);
        ("property", Leaf x.property);
        ("type", type_to_node x.type_);
        ("entries", map_seq enum_map_entry_to_node x.entries);
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
      (* A constructor declaration carries a full type expression because it may
         introduce generics, so its "type" renders like every other Type_expr
         field. A constructor call names a plain Name_type and renders as a leaf;
         the two shapes differ because the nodes differ. *)
      let params = match x.params with
        | Nodes.Constructor_params.Positional params -> params_to_node params
        | Nodes.Constructor_params.Fields fields_ ->
            group "fields" (map_seq constructor_field_to_node fields_)
      in
      let fs = [("type", type_to_node x.type_)] in
      let fs = match x.member with
        | Some member -> fs @ [("member", Leaf member)]
        | None -> fs
      in
      let fs = fs @ [
        ("param", params);
        ("body", body_to_node x.body);
        ("is_implicit", Leaf (string_of_bool x.is_implicit));
      ] in
      group "ctor_decl" (fields fs)
  | Subscript x ->
      group "subscript_decl" (fields [
        ("this_type", type_to_node x.this_type);
        ("param", params_to_node x.params);
        ("value", expr_to_node x.value);
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
