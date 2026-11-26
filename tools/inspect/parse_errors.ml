(* [parse_errors FILE] prints every syntax error in FILE, recovering past each
   one ([Cst.parse_recovering]), as `zanec` prints them, then on stderr how
   many declarations survived.
   [parse_errors --compare FILE] prints only whether the first diagnostic is
   the one [Cst.parse] gives. *)
let () =
  let compare_mode, path =
    match Array.to_list Sys.argv with
    | [ _; "--compare"; path ] -> (true, path)
    | [ _; path ] -> (false, path)
    | _ -> prerr_endline "usage: parse_errors [--compare] FILE"; exit 2
  in
  let source = In_channel.with_open_bin path In_channel.input_all in
  let package, diagnostics = Cst.parse_recovering path source in
  if compare_mode then
    let verdict =
      match (Cst.parse path source, diagnostics) with
      | Ok _, [] -> "same (accepted)"
      | Error d, first :: _ when d = first -> "same"
      | Error d, first :: _ ->
          "DIFFERENT\n" ^ Diagnostic.render ~source d ^ "\nvs\n" ^ Diagnostic.render ~source first
      | Ok _, _ :: _ -> "DIFFERENT (parse accepted)"
      | Error _, [] -> "DIFFERENT (recovering accepted)"
    in
    Printf.printf "%s: %s (%d diagnostic(s))\n" path verdict (List.length diagnostics)
  else (
    List.iter (fun d -> print_string (Diagnostic.render ~source d)) diagnostics;
    Printf.eprintf "%d diagnostic(s), %d declaration(s) kept\n" (List.length diagnostics)
      (List.length package.Cst.Nodes.Package.decls);
    exit (if diagnostics = [] then 0 else 1))
