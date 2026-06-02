type type_expr =
  | Simple of string
  | Generic of { name: string; args: string list }
  | Function of { params: type_expr list; ret_type: type_expr }
  | Method of { params: type_expr list; ret_type: type_expr; is_mut: bool }

type decl =
  | Function of { name: string; params: type_expr list; ret: type_expr }

type expr =
  | Int of int
  | Add of expr * expr
  | Sub of expr * expr
  | Mul of expr * expr
  | Div of expr * expr
