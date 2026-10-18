(* A parser-only driver, so grammar tests do not require the LLVM backend.
   It refuses a program the way zanec does: exit 1 with the diagnostic on
   stderr, which tests/parser/syntax_test.py's rejection check requires. *)
let () =
  let source = In_channel.input_all stdin in
  match Cst.parse "<grammar-test>" source with
  | Ok _ -> ()
  | Error diagnostic ->
      prerr_string (Diagnostic.render ~source diagnostic);
      exit 1
