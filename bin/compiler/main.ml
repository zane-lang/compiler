let () =
  let tree = Tree_graph.Fields ("hi", Tree_graph.StringMap.of_list [
    ("child1", Tree_graph.Fields ("hi", Tree_graph.StringMap.of_list [
      ("child1", Tree_graph.Leaf "bye");
      ("child2", Tree_graph.Leaf "see ya")
    ]));
    ("child2", Tree_graph.Children ("hello", [Tree_graph.Leaf "see ya"]))
  ]) in
  print_endline (Tree_graph.render tree)
