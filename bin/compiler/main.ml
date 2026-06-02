let read_file path =
    In_channel.with_open_text path In_channel.input_all

let () =
    let input = read_file "test-parser/main.zn" in
    let cst = Cst.parse input in
    let output = Cst.to_string cst in
    print_endline output
