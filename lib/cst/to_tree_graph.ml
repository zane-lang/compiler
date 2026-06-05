let rec type_to_node = function
  | Nodes.SimpleType s -> Tree_graph.Leaf s
  | Nodes.FuncType { params; ret_type }
      -> Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("param", Tree_graph.Sequence (List.map type_to_node params));
        ("type", type_to_node ret_type);
      ])
  | Nodes.MethType { params; ret_type; is_mut }
      -> Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("param", Tree_graph.Sequence (List.map type_to_node params));
        ("type", type_to_node ret_type);
        ("is_mut", Tree_graph.Leaf (string_of_bool is_mut));
      ])

and expr_to_node (x: Nodes.expr) = match x with
  | Nodes.IntLit x   -> Tree_graph.Leaf x
  | Nodes.FloatLit x -> Tree_graph.Leaf x
  | Nodes.StrLit x   -> Tree_graph.Leaf x
  | Nodes.Ident x    -> Tree_graph.Leaf x
  | Nodes.Op x
      -> Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("left", expr_to_node x.left);
        ("right", expr_to_node x.right);
        ("op", Tree_graph.Leaf x.operator);
      ])
  | Nodes.Parenthized x
      -> Tree_graph.Group {
        title = "Parenthized";
        body = expr_to_node x
      }
  | Nodes.FuncCall x -> func_call_to_node x

and func_call_to_node x =
  Tree_graph.Group {
    title = "function_call";
    body = Tree_graph.Fields (
      Tree_graph.StringMap.of_list [
        ("callee", expr_to_node x.callee);
        ("arg", Tree_graph.Sequence (List.map expr_to_node x.args));
      ]
    )
  }

and param_to_node (x: Nodes.param) =
  Tree_graph.Fields (Tree_graph.StringMap.of_list [
    ("name", Tree_graph.Leaf x.name);
    ("type", type_to_node x.type_);
  ])

and params_to_node (x: Nodes.param list) =
  Tree_graph.Sequence (List.map param_to_node x)

and statement_to_node (x: Nodes.stat) = match x with
  | Nodes.FuncCallStat x -> func_call_to_node x
  | Nodes.DeclStat x -> decl_to_node x

and body_to_node (x: Nodes.body) = match x with
  | Nodes.Scope scope
      -> Tree_graph.Group {
        title = "scope";
        body = Tree_graph.Group {
          title = "statement";
          body = Tree_graph.Sequence (List.map statement_to_node scope)
        }
      }

and decl_to_node = function
  | Nodes.FuncDecl { name; params; ret_type; body }
      -> Tree_graph.Group {
        title = "func_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("param", params_to_node params);
            ("ret_type", type_to_node ret_type);
            ("body", body_to_node body);
          ]
        )
      }
  | Nodes.MethDecl { name; params; ret_type; body; is_mut }
      -> Tree_graph.Group {
        title = "method_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("param", params_to_node params);
            ("ret_type", type_to_node ret_type);
            ("body", body_to_node body);
            ("is_mut ", Tree_graph.Leaf (string_of_bool is_mut));
          ]
        )
      }
  | Nodes.VarDecl { name; type_; value }
      -> Tree_graph.Group {
        title = "var_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("name", Tree_graph.Leaf name);
            ("type", type_to_node type_);
            ("value", expr_to_node value);
          ]
        )
      }
  | Nodes.ConstructorDecl { name; type_; args }
      -> Tree_graph.Group {
        title = "constructor_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("name", Tree_graph.Leaf name);
            ("type", type_to_node type_);
            ("args", Tree_graph.Sequence (List.map expr_to_node args));
          ]
        )
      }

let to_node ({ Nodes.decls }: Nodes.package) =
  Tree_graph.Group { title = "package"; body = Tree_graph.Fields (Tree_graph.StringMap.of_list [
      ("declarations", Tree_graph.Sequence (List.map decl_to_node decls))
    ])
  }
