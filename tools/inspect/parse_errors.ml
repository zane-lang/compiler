let () =
  let path = Sys.argv.(1) in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let package, diagnostics = Cst.parse_recovering path source in
  List.iter (fun d -> print_endline (Diagnostic.render ~source d)) diagnostics;
  Printf.printf "%d diagnostic(s), %d declaration(s) kept\n" (List.length diagnostics)
    (List.length package.Cst.Nodes.Package.decls);
  exit (if diagnostics = [] then 0 else 1)
