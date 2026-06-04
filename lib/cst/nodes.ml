type expr =
  | IntLiteral of string
  | FloatLiteral of string
  | StringLiteral of string
  | Add of expr * expr
  | Sub of expr * expr
  | Mul of expr * expr
  | Div of expr * expr
  | Parenthized of expr

type type_expr =
  | Simple of string
  | FunctionType of { params: type_expr list; ret_type: type_expr }
  | MethodType of { params: type_expr list; ret_type: type_expr; is_mut: bool }

type param = {
  name: string;
  type_: type_expr
}

type decl =
  | FunctionDecl of { name: string; params: param list; ret_type: type_expr }

type package = {
  decls: decl list
}
