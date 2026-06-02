let () =
    let input = "3 + 4 * 2 - 1" in
    let cst = Cst.parse input in
    let output = Cst.string_of_expr(cst) in
    print_endline output
