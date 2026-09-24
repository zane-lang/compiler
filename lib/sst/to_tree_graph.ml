open Tree_graph

(* The SST's counterpart to lib/cst/to_tree_graph.ml, following the same rule:
   a helper returns the node for its value and never wraps its own output, so
   labelling stays the caller's decision.

   Read side by side with that file, this one is shorter in the places a
   desugaring took an alternative away -- there is no `parenthized`, no
   `ret_shorthand`, no `var_decl_shorthand`, no `trailing`, and one call group
   instead of two. Those absences are the change, and they are easier to see
   here than anywhere else, because this rendering names every field.

   What it does not show is positions. That is the other adapter's job
   ([To_span_text]), and the two are kept apart for the same reason the CST
   keeps them apart: a structure rendering is for reading, and a span dump is
   for checking that a span points where it should. Neither answers the
   other's question. *)

let text (n : Nodes.Name.t) = n.Nodes.Name.text

let name_type_to_node (x : Nodes.Name_type.t) =
  match x.Nodes.Name_type.node with
  | Ident s -> Leaf (text s)
  | Qualified { package; ident } -> Leaf (text package ^ "$" ^ text ident)
  | Intrinsic { package; ident } -> Leaf ("@" ^ text package ^ "$" ^ text ident)

let name_expr_to_node (x : Nodes.Name_expr.t) =
  match x.Nodes.Name_expr.node with
  | Ident s -> Leaf (text s)
  | Qualified { package; ident } -> Leaf (text package ^ "$" ^ text ident)
  | Intrinsic { package; ident } -> Leaf ("@" ^ text package ^ "$" ^ text ident)

(* Five tokens, not ten, and no `'` prefix: the derived operators have been
   written out into these and the loose forms have collapsed into their
   unprefixed spelling. A `<` here may have been a `>` in the source, which is
   what the span dump is for. *)
let op_to_name (x : Nodes.Operator.t) =
  match x.Nodes.Operator.node with
  | Add -> "+"
  | Mul -> "*"
  | Div -> "/"
  | Eq -> "=="
  | Less -> "<"

let rec concept_to_node (x : Nodes.Concept.t) =
  match x.Nodes.Concept.node with Type -> Leaf "Type" | Number -> Leaf "Number"

and param_type_to_node (x : Nodes.Param_type.t) =
  match x.Nodes.Param_type.node with
  | Concrete x -> type_to_node x
  | Concept x -> concept_to_node x
  | InferredType { name; concept } ->
      fields [ ("name", Leaf (text name)); ("concept", concept_to_node concept) ]

and verb_type_to_node (x : Nodes.Verb_type.t) =
  match x.Nodes.Verb_type.node with
  | Func { params; ret_type } ->
      fields
        [
          ("param", map_seq param_type_to_node params);
          ("type", ret_to_node ret_type);
        ]
  | Meth { this_type; params; ret_type; is_mut } ->
      fields
        [
          ("this_type", type_to_node this_type);
          ("param", map_seq param_type_to_node params);
          ("type", ret_to_node ret_type);
          ("is_mut", Leaf (string_of_bool is_mut));
        ]

and body_field_to_node (x : Nodes.Body_field.t) =
  fields [ ("name", Leaf (text x.name)); ("type", type_to_node x.type_) ]

and mould_to_node (x : Nodes.Mould.t) =
  match x.Nodes.Mould.node with
  | Struct x -> group "struct" (map_seq body_field_to_node x)
  | Variant x -> group "variant" (map_seq body_field_to_node x)
  | Enum x -> group "enum" (map_seq (fun x -> Leaf (text x)) x)

and generic_arg_to_node (x : Nodes.Generic_arg.t) =
  match x.Nodes.Generic_arg.node with
  | Type x -> type_to_node x
  | Number x -> group "number" (Leaf x)
  | NumberRef x -> group "number_ref" (Leaf (text x))
  | Inferred x -> group "param" (param_to_node x)

(* No `parenthesized`: the grouping is the tree. *)
and type_to_node (x : Nodes.Type_expr.t) =
  match x.Nodes.Type_expr.node with
  | Verb x -> verb_type_to_node x
  | Guest x -> group "guest" (type_to_node x)
  | Path { name; generics } ->
      fields
        [
          ("qualifier", name_type_to_node name);
          ("args", map_seq generic_arg_to_node generics);
        ]

and abort_field abort_handle =
  ("abort", Option.fold ~none:(Leaf "none") ~some:abort_handle_to_node abort_handle)

(* Always a value now: a bare `x` was written out into `x = x`. *)
and field_arg_to_node (x : Nodes.Field_arg.t) =
  fields [ ("name", Leaf (text x.name)); ("value", expr_to_node x.value) ]

and call_arg_to_node (x : Nodes.Call_arg.t) =
  match x.Nodes.Call_arg.node with
  | Value x -> expr_to_node x
  | Block b -> group "block" (block_to_node b)

and constructor_args_to_node (x : Nodes.Constructor_args.t) =
  match x.Nodes.Constructor_args.node with
  | Positional args -> map_seq call_arg_to_node args
  | Fields args -> group "fields" (map_seq field_arg_to_node args)

(* One call group where the CST has two. `form` says whether a subject was
   written and with which marker; when one was, it is the first entry of
   `args`, which is where the method desugaring puts it. *)
and call_form_to_name (x : Nodes.Call_form.t) =
  match x with
  | Function -> "function"
  | Method { is_mut = true } -> "method!"
  | Method { is_mut = false } -> "method:"

and verb_call_to_node (x : Nodes.Verb_call.t) =
  match x.Nodes.Verb_call.node with
  | Call { callee; args; form; abort_handle } ->
      group "call"
        (fields
           [
             ("form", Leaf (call_form_to_name form));
             ("callee", expr_to_node callee);
             ("args", map_seq call_arg_to_node args);
             abort_field abort_handle;
           ])
  | Constructor { name; args; abort_handle } ->
      let fs = [ ("type", name_type_to_node name.type_) ] in
      let fs =
        match name.member with
        | Some member -> fs @ [ ("member", Leaf (text member)) ]
        | None -> fs
      in
      group "ctor_call"
        (fields
           (fs
           @ [ ("args", constructor_args_to_node args); abort_field abort_handle ]))
  | Op { op; left; right; swapped; abort_handle } ->
      group "op_call"
        (fields
           [
             ("op", Leaf (op_to_name op));
             ("left", expr_to_node left);
             ("right", expr_to_node right);
             ("swapped", Leaf (string_of_bool swapped));
             abort_field abort_handle;
           ])
  | Flip { value; abort_handle } ->
      group "flip_call"
        (fields [ ("value", expr_to_node value); abort_field abort_handle ])

(* One case, not a list: a `[ ]` group has become one arm per case. *)
and match_pattern_to_node (x : Nodes.Match_pattern.t) =
  let fs = [ ("case", Leaf (text x.case)) ] in
  let fs =
    match x.binder with
    | Some binder -> ("binder", Leaf (text binder)) :: fs
    | None -> fs
  in
  fields fs

and match_arm_to_node (x : Nodes.Match_arm.t) =
  fields
    [
      ("patterns", map_seq match_pattern_to_node x.patterns);
      ("body", block_to_node x.body);
    ]

and match_expr_to_node (x : Nodes.Match_expr.t) =
  fields
    [
      ("scrutinees", map_seq expr_to_node x.scrutinees);
      ("arms", map_seq match_arm_to_node x.arms);
      abort_field x.abort_handle;
    ]

(* No `parenthized`. *)
and expr_to_node (x : Nodes.Expr.t) =
  match x.Nodes.Expr.node with
  | IntLit x -> Leaf x
  | FloatLit x -> Leaf x
  | StrLit x -> Leaf x
  | BoolLit x -> Leaf (string_of_bool x)
  | CollectionLit x -> group "collection" (map_seq expr_to_node x)
  | NameExpr x -> name_expr_to_node x
  | TypeMember { type_; member } ->
      group "type_member"
        (fields
           [
             ("type", name_type_to_node type_); ("member", Leaf (text member));
           ])
  | TypeValue type_ ->
      group "type_value" (fields [ ("type", name_type_to_node type_) ])
  | DotAccess { target; field; abort_handle } ->
      group "dot_access"
        (fields
           [
             ("target", expr_to_node target);
             ("field", Leaf (text field));
             abort_field abort_handle;
           ])
  | Subscript { target; args } ->
      group "subscript"
        (fields
           [
             ("target", expr_to_node target);
             ("args", map_seq expr_to_node args);
           ])
  | Ref x -> group "ref" (expr_to_node x)
  | Init fields_ -> group "init" (map_seq field_arg_to_node fields_)
  | MapLit entries -> group "map_lit" (map_seq map_entry_to_node entries)
  | Spawn call -> group "spawn" (verb_call_to_node call)
  | Match match_ -> group "match" (match_expr_to_node match_)
  | FuncLambda x -> group "func_lambda" (func_lambda_to_node x)
  | MethLambda x -> group "meth_lambda" (meth_lambda_to_node x)
  | VerbCall x -> verb_call_to_node x

(* One shape: a `??` has been written out into a handler that resolves. *)
and abort_handle_to_node (x : Nodes.Abort_handle.t) =
  let fs = [ ("body", block_to_node x.body) ] in
  let fs =
    match x.binder with
    | Some b -> ("binder", Leaf (text b)) :: fs
    | None -> fs
  in
  fields fs

and param_to_node (x : Nodes.Param.t) =
  fields [ ("name", Leaf (text x.name)); ("type", param_type_to_node x.type_) ]

and params_to_node (x : Nodes.Param.t list) = map_seq param_to_node x

and constructor_field_to_node (x : Nodes.Constructor_field.t) =
  let fs =
    [ ("name", Leaf (text x.name)); ("type", param_type_to_node x.type_) ]
  in
  let fs =
    match x.default with
    | Some default -> fs @ [ ("default", expr_to_node default) ]
    | None -> fs
  in
  fields fs

and stat_to_node (x : Nodes.Stat.t) =
  match x.Nodes.Stat.node with
  | VerbCall x -> verb_call_to_node x
  | Spawn x -> group "spawn_stat" (verb_call_to_node x)
  | Decl x -> decl_to_node x
  | Assign { target; value } ->
      group "assign_stat"
        (fields
           [ ("target", expr_to_node target); ("value", expr_to_node value) ])
  | Abort x -> group "abort_stat" (expr_to_node x)
  | Ret x -> group "ret_stat" (expr_to_node x)
  | Resolve x -> group "resolve_stat" (expr_to_node x)

(* One shape: a `=> expr` body has been written out into a scope holding a
   single `return`. *)
and block_to_node (x : Nodes.Block.t) =
  group "scope" (fields [ ("stat", map_seq stat_to_node x.stats) ])

(* No `parenthesized`. *)
and ret_to_node (x : Nodes.Ret_type.t) =
  match x.Nodes.Ret_type.node with
  | Safe ret -> type_to_node ret
  | Abort { ok; abort } ->
      fields
        [ ("safe_type", type_to_node ok); ("abort_type", type_to_node abort) ]

and func_lambda_to_node (x : Nodes.Func_lambda.t) =
  fields
    [
      ("param", params_to_node x.params);
      ("ret_type", ret_to_node x.ret_type);
      ("body", block_to_node x.body);
    ]

and meth_lambda_to_node (x : Nodes.Meth_lambda.t) =
  fields
    [
      ("this_type", type_to_node x.this_type);
      ("param", params_to_node x.params);
      ("ret_type", ret_to_node x.ret_type);
      ("body", block_to_node x.body);
      ("is_mut", Leaf (string_of_bool x.is_mut));
    ]

and type_axis_to_node (x : Nodes.Type_axis.t) =
  match x.Nodes.Type_axis.node with
  | Value -> Leaf "value"
  | Reference -> Leaf "reference"

and moulded_to_node (x : Nodes.Moulded.t) =
  fields
    [ ("mould", mould_to_node x.mould); ("type_axis", type_axis_to_node x.axis) ]

and type_or_moulded_to_node (x : Nodes.Type_or_moulded.t) =
  match x.Nodes.Type_or_moulded.node with
  | Raw x -> type_to_node x
  | Moulded x -> moulded_to_node x

and import_member_to_node (x : Nodes.Import_member.t) =
  fields
    [ ("name", Leaf x.name); ("is_type", Leaf (string_of_bool x.is_type)) ]

and import_to_node (x : Nodes.Import.t) =
  match x.Nodes.Import.node with
  | Package { package; alias } ->
      let fs = [ ("package", Leaf (text package)) ] in
      let fs =
        match alias with
        | Some alias -> fs @ [ ("alias", Leaf (text alias)) ]
        | None -> fs
      in
      group "import_package" (fields fs)
  | Member { package; member; alias } ->
      let fs =
        [
          ("package", Leaf (text package));
          ("member", import_member_to_node member);
        ]
      in
      let fs =
        match alias with
        | Some alias -> fs @ [ ("alias", import_member_to_node alias) ]
        | None -> fs
      in
      group "import_member" (fields fs)
  | Members { package; members } ->
      group "import_members"
        (fields
           [
             ("package", Leaf (text package));
             ("members", map_seq import_member_to_node members);
           ])
  | All { package } ->
      group "import_all" (fields [ ("package", Leaf (text package)) ])

and map_entry_to_node (key, value) =
  fields [ ("key", expr_to_node key); ("value", expr_to_node value) ]

and enum_map_entry_to_node (member, value) =
  fields [ ("member", Leaf (text member)); ("value", expr_to_node value) ]

(* No `var_decl_shorthand`: the instantiation shorthand has been written out
   into an ordinary `var_decl` whose type is the constructor's base type. *)
and decl_to_node (x : Nodes.Decl.t) =
  match x.Nodes.Decl.node with
  | Package name -> group "package_decl" (Leaf (text name))
  | Import value -> group "import_decl" (import_to_node value)
  | Var { name; type_; value } ->
      group "var_decl"
        (fields
           [
             ("name", Leaf (text name));
             ("type", type_to_node type_);
             ("value", expr_to_node value);
           ])
  | Type x ->
      group "type_decl"
        (fields
           [
             ("name", Leaf (text x.name));
             ("params", map_seq generic_param_to_node x.params);
             ("value", type_or_moulded_to_node x.value);
           ])
  | Alias x ->
      group "alias_decl"
        (fields
           [
             ("name", Leaf (text x.name));
             ("params", map_seq generic_param_to_node x.params);
             ("value", type_or_moulded_to_node x.value);
           ])
  | EnumMap x ->
      group "enum_map_decl"
        (fields
           [
             ("enum", type_to_node x.enum);
             ("property", Leaf (text x.property));
             ("type", type_to_node x.type_);
             ("entries", map_seq enum_map_entry_to_node x.entries);
           ])
  | Verb x -> verb_decl_to_node x

and verb_decl_to_node (x : Nodes.Verb_decl.t) =
  match x.Nodes.Verb_decl.node with
  | Func x ->
      group "func_decl"
        (fields
           [
             ("name", Leaf (text x.name));
             ("param", params_to_node x.params);
             ("ret_type", ret_to_node x.ret_type);
             ("body", block_to_node x.body);
           ])
  | Meth x ->
      group "meth_decl"
        (fields
           [
             ("name", Leaf (text x.name));
             ("this_type", type_to_node x.this_type);
             ("param", params_to_node x.params);
             ("ret_type", ret_to_node x.ret_type);
             ("body", block_to_node x.body);
             ("is_mut", Leaf (string_of_bool x.is_mut));
           ])
  | Constructor x ->
      (* As in the CST: a declaration carries a full type expression because it
         may introduce generics, while a call names a plain [Name_type]. *)
      let params =
        match x.params.Nodes.Constructor_params.node with
        | Nodes.Constructor_params.Positional params -> params_to_node params
        | Nodes.Constructor_params.Fields fields_ ->
            group "fields" (map_seq constructor_field_to_node fields_)
      in
      let fs = [ ("type", type_to_node x.type_) ] in
      let fs =
        match x.member with
        | Some member -> fs @ [ ("member", Leaf (text member)) ]
        | None -> fs
      in
      let fs =
        fs
        @ [
            ("param", params);
            ("body", block_to_node x.body);
            ("is_implicit", Leaf (string_of_bool x.is_implicit));
          ]
      in
      group "ctor_decl" (fields fs)
  | Subscript x ->
      group "subscript_decl"
        (fields
           [
             ("this_type", type_to_node x.this_type);
             ("param", params_to_node x.params);
             ("value", expr_to_node x.value);
           ])
  | Op x ->
      group "op_decl"
        (fields
           [
             ("op", Leaf (op_to_name x.op));
             ("param", params_to_node x.params);
             ("ret_type", ret_to_node x.ret_type);
             ("body", block_to_node x.body);
           ])
  | Flip x ->
      group "flip_decl"
        (fields
           [
             ("param", params_to_node x.params);
             ("ret_type", ret_to_node x.ret_type);
             ("body", block_to_node x.body);
           ])

and generic_param_to_node (x : Nodes.Generic_param.t) =
  fields [ ("name", Leaf (text x.name)); ("type", concept_to_node x.type_) ]

let to_node ({ decls; _ } : Nodes.Package.t) =
  group "package" (fields [ ("declarations", map_seq decl_to_node decls) ])
