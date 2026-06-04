(* The CST's job is to represent what was parsed, not what's valid. *)

type expr =
  | IntLiteral of string
  | FloatLiteral of string
  | StringLiteral of string
  | Ident of string
  | Operator of { left: expr; right: expr; operator: string }
  | Parenthized of expr
  | FunctionCall of function_call

and function_call = {
  callee: expr;
  args: expr list 
}

type type_expr =
  | SimpleType of string
  | FunctionType of { params: type_expr list; ret_type: type_expr }
  | MethodType of { params: type_expr list; ret_type: type_expr; is_mut: bool }

type param = {
  name: string;
  type_: type_expr
}

type statement =
  | ExprStatement of expr

type body =
  | Scope of statement list

type decl =
  | FunctionDecl of { name: string; params: param list; ret_type: type_expr; body: body }

type package = {
  decls: decl list
}
