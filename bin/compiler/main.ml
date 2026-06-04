let map1 = Tree_graph.StringMap.of_list [
  ("name", Tree_graph.Leaf "hi");
  ("type", Tree_graph.Leaf "Int");
] in
let map2 = Tree_graph.StringMap.of_list [
  ("name", Tree_graph.Leaf "a");
  ("type", Tree_graph.Leaf "Bool");
] in

let root = Tree_graph.Group {
  title = "package";
  body = Tree_graph.Fields (Tree_graph.StringMap.of_list [
    ("params", Tree_graph.Children [Tree_graph.Fields map1; Tree_graph.Fields map2]);
    ("ret_type", Tree_graph.Leaf "Void");
    ("sub_data", Tree_graph.Group {
      title = "package";
      body = Tree_graph.Group {
        title = "package";
        body = Tree_graph.Leaf "bla" 
      }
    });
  ])
} in

Tree_graph.render root
