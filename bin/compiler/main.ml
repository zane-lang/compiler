let () =
  let tree = Tree_graph.Fields ("editors", Tree_graph.StringMap.of_list [
    ("constraints", Tree_graph.Fields ("required languages", Tree_graph.StringMap.of_list [
      ("cpp", Tree_graph.Leaf "full");
      ("yacc", Tree_graph.Leaf "ts only")
    ]));
    ("candidates", Tree_graph.Children ("closest", [Tree_graph.Fields ("required languages", Tree_graph.StringMap.of_list [
      ("cpp", Tree_graph.Leaf "full");
      ("yacc", Tree_graph.Leaf "ts only")
    ]); Tree_graph.Leaf "zed"]))
  ]) in
  print_endline (Tree_graph.render tree)
