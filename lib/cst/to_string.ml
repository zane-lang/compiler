let rec to_string = function
    | Nodes.Int n -> string_of_int n
    | Nodes.Add (e1, e2) -> "(" ^ to_string e1 ^ " + " ^ to_string e2 ^ ")"
    | Nodes.Sub (e1, e2) -> "(" ^ to_string e1 ^ " - " ^ to_string e2 ^ ")"
    | Nodes.Mul (e1, e2) -> "(" ^ to_string e1 ^ " * " ^ to_string e2 ^ ")"
    | Nodes.Div (e1, e2) -> "(" ^ to_string e1 ^ " / " ^ to_string e2 ^ ")"
