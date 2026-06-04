(* The CST's job is to represent what was parsed, not what's valid. *)

type expr =
  | IntLit of string
  | FloatLit of string
  | StrLit of string
  | Ident of string
  | Op of { left: expr; right: expr; operator: string }
  | Parenthized of expr
  | FuncCall of func_call

and func_call = {
  callee: expr;
  args: expr list 
}

type type_expr =
  | SimpleType of string
  | FuncType of { params: type_expr list; ret_type: type_expr }
  | MethType of { params: type_expr list; ret_type: type_expr; is_mut: bool }

type param = {
  name: string;
  type_: type_expr
}

type stat =
  | ExprStat of expr

type body =
  | Scope of stat list

type decl =
  | FuncDecl of { name: string; params: param list; ret_type: type_expr; body: body }

type package = {
  decls: decl list
}
