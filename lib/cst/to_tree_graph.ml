let rec type_to_node = function
  | Nodes.Simple s -> Tree_graph.Leaf s
  | Nodes.FunctionType { params; ret_type } ->
      Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("param", Tree_graph.Sequence (List.map type_to_node params));
        ("type", type_to_node ret_type);
      ])
  | Nodes.MethodType { params; ret_type; is_mut } ->
      Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("param", Tree_graph.Sequence (List.map type_to_node params));
        ("type", type_to_node ret_type);
        ("is_mut", Tree_graph.Leaf (string_of_bool is_mut));
      ])

and expr_to_node (x: Nodes.expr) = match x with
  | Nodes.IntLiteral x -> Tree_graph.Leaf x
  | Nodes.FloatLiteral x -> Tree_graph.Leaf x
  | Nodes.StringLiteral x -> Tree_graph.Leaf x
  | Nodes.Ident x -> Tree_graph.Leaf x
  | Nodes.Operator x ->
      Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("left", expr_to_node x.left);
        ("right", expr_to_node x.right);
        ("op", Tree_graph.Leaf x.operator);
      ])
  | Nodes.Parenthized x ->
      Tree_graph.Group {
        title = "Parenthized";
        body = expr_to_node x
      }

and param_to_node (x: Nodes.param) =
  Tree_graph.Fields (Tree_graph.StringMap.of_list [
    ("name", Tree_graph.Leaf x.name);
    ("type", type_to_node x.type_);
  ])

and params_to_node (x: Nodes.param list) =
  Tree_graph.Sequence (List.map param_to_node x)

and statement_to_node (x: Nodes.statement) = match x with
  | Nodes.FunctionCall x ->
      Tree_graph.Group {
        title = "function_call";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("callee", expr_to_node x.callee);
            ("arg", Tree_graph.Sequence (List.map expr_to_node x.args));
          ]
        )
      }

and body_to_node (x: Nodes.body) = match x with
  | Nodes.Scope scope ->
      Tree_graph.Group {
        title = "scope";
        body = Tree_graph.Group {
          title = "statement";
          body = Tree_graph.Sequence (List.map statement_to_node scope)
        }
      }

and decl_to_node = function
  | Nodes.FunctionDecl { name; params; ret_type; body } ->
      Tree_graph.Group {
        title = "function_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("param", params_to_node params);
            ("ret_type", type_to_node ret_type);
            ("body", body_to_node body);
          ]
        )
      }

let to_node ({ Nodes.decls }: Nodes.package) =
  Tree_graph.Group { title = "package"; body = Tree_graph.Fields (Tree_graph.StringMap.of_list [
      ("declarations", Tree_graph.Sequence (List.map decl_to_node decls))
    ])
  }
