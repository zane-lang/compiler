let () =
  if Array.length Sys.argv <> 2 then begin
    prerr_endline "usage: parser_accept SOURCE";
    exit 2
  end;
  match Cst.parse "<parser-syntax-test>" Sys.argv.(1) with
  | Ok _ -> ()
  | Error diagnostic ->
      prerr_string (Diagnostic.render ~source:Sys.argv.(1) diagnostic);
      exit 1
