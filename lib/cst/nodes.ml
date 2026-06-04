type expr =
  | IntLiteral of string
  | FloatLiteral of string
  | StringLiteral of string
  | Ident of string
  | Operator of {left: expr; right: expr; operator: string}
  | Parenthized of expr

type type_expr =
  | Simple of string
  | FunctionType of { params: type_expr list; ret_type: type_expr }
  | MethodType of { params: type_expr list; ret_type: type_expr; is_mut: bool }

type param = {
  name: string;
  type_: type_expr
}

type statement =
  | FunctionCall of { callee: expr; args: expr list; }

type body =
  | Scope of statement list

type decl =
  | FunctionDecl of { name: string; params: param list; ret_type: type_expr; body: body }

type package = {
  decls: decl list
}
