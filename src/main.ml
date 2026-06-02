let rec string_of_expr = function
    | Ast.Int n -> string_of_int n
    | Ast.Add (e1, e2) -> "(" ^ string_of_expr e1 ^ " + " ^ string_of_expr e2 ^ ")"
    | Ast.Sub (e1, e2) -> "(" ^ string_of_expr e1 ^ " - " ^ string_of_expr e2 ^ ")"
    | Ast.Mul (e1, e2) -> "(" ^ string_of_expr e1 ^ " * " ^ string_of_expr e2 ^ ")"
    | Ast.Div (e1, e2) -> "(" ^ string_of_expr e1 ^ " / " ^ string_of_expr e2 ^ ")"

let () =
    let input = "3 + 4 * (2 - 1)" in
    let lexbuf = Sedlexing.Utf8.from_string input in
    let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
    try
        let result = MenhirLib.Convert.Simplified.traditional2revised Parser.prog tokenizer in
        print_endline ("Parsed: " ^ string_of_expr result)
    with
        | Sedlexing.MalFormed | Sedlexing.InvalidCodepoint _ ->
        print_endline "Lexing error: Invalid character"
        | Parser.Error ->
        print_endline "Parsing error: Invalid syntax"
