(* A parser-only driver, so grammar tests do not require the LLVM backend. *)
let () =
  let source = In_channel.input_all stdin in
  match Cst.parse "<grammar-test>" source with
  | Ok _ -> ()
  | Error _ -> exit 1
