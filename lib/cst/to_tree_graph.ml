let rec type_to_node = function
  | Nodes.Simple s -> Tree_graph.Leaf s
  | Nodes.FunctionType { params; ret_type } ->
      Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("params", Tree_graph.Children (List.map type_to_node params));
        ("type", type_to_node ret_type);
      ])
  | Nodes.MethodType { params; ret_type; is_mut } ->
      Tree_graph.Fields (Tree_graph.StringMap.of_list [
        ("params", Tree_graph.Children (List.map type_to_node params));
        ("type", type_to_node ret_type);
        ("is_mut", Tree_graph.Leaf (string_of_bool is_mut));
      ])

and param_to_node (x : Nodes.param) =
  Tree_graph.Fields (Tree_graph.StringMap.of_list [
    ("name", Tree_graph.Leaf x.name);
    ("type", type_to_node x.type_);
  ])

and params_to_node (x: Nodes.param list) =
  Tree_graph.Children (List.map param_to_node x)


and decl_to_node = function
  | Nodes.FunctionDecl { name; params; ret_type } ->
      Tree_graph.Group {
        title = "function_decl";
        body = Tree_graph.Fields (
          Tree_graph.StringMap.of_list [
            ("params", params_to_node params);
            ("ret_type", type_to_node ret_type);
          ]
        )
      }

let to_node ({ Nodes.decls }: Nodes.package) =
  Tree_graph.Group { title = "package"; body = Tree_graph.Fields (Tree_graph.StringMap.of_list [
      ("declarations", Tree_graph.Children (List.map decl_to_node decls))
    ])
  }
