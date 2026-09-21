let () =
  if Array.length Sys.argv <> 2 then begin
    prerr_endline "usage: parser_accept SOURCE";
    exit 2
  end;
  match Cst.parse "<parser-syntax-test>" Sys.argv.(1) with
  | Ok _ -> ()
  | Error message ->
      prerr_string message;
      exit 1
