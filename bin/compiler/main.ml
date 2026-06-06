let read_file path =
  In_channel.with_open_text path In_channel.input_all

let () =
  let input = read_file "test-parser/main.zn" in
  match Cst.parse "test-parser/main.zn" input with
  | Ok cst ->
      let output = Cst.to_node cst in
      Tree_graph.render output
  | Error message ->
      prerr_string message;
      exit 1
