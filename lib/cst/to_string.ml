let rec expr_to_string = function
  | Nodes.IntLiteral s -> s
  | Nodes.FloatLiteral s -> s
  | Nodes.StringLiteral s -> "\"" ^ s ^ "\""
  | Nodes.Add (e1, e2) -> expr_to_string e1 ^ " + " ^ expr_to_string e2
  | Nodes.Sub (e1, e2) -> expr_to_string e1 ^ " - " ^ expr_to_string e2
  | Nodes.Mul (e1, e2) -> expr_to_string e1 ^ " * " ^ expr_to_string e2
  | Nodes.Div (e1, e2) -> expr_to_string e1 ^ " / " ^ expr_to_string e2
  | Nodes.Parenthized e -> "(" ^ expr_to_string e ^ ")"

and type_to_string = function
  | Nodes.Simple s -> s
  | Nodes.FunctionType { params; ret_type } ->
    "(" ^ String.concat ", " (List.map type_to_string params) ^ ") " ^ type_to_string ret_type
  | Nodes.MethodType { params; ret_type; is_mut } ->
    (if is_mut then "mut " else "") ^
    "(" ^ String.concat ", " (List.map type_to_string params) ^ ") " ^ type_to_string ret_type

and param_to_string { Nodes.name; type_ } =
  name ^ " " ^ type_to_string type_

and decl_to_string = function
  | Nodes.FunctionDecl { name; params; ret } ->
    name ^ " ("
    ^ String.concat ", " (List.map param_to_string params)
    ^ ") " ^ type_to_string ret

let to_string { Nodes.decl } =
  String.concat "\n" (List.map decl_to_string decl)
