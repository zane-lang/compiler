(* The CST's job is to represent what was parsed, not what's valid. *)

type expr =
  | IntLit      of string
  | FloatLit    of string
  | StrLit      of string
  | Ident       of string
  | Op          of { left: expr; right: expr; operator: string }
  | Parenthized of expr
  | FuncCall    of func_call

and safe_call = {
  callee: expr;
  args: expr list;
}

and abort_handle =
  | AbortBody of body
  | AbortShorthand of expr

and abort_call = {
  callee: expr;
  args: expr list;
  binder: string option;
  handle_block: abort_handle;
}

and func_call =
  | SafeCall of safe_call
  | AbortCall of abort_call


and type_expr =
  | SimpleType of string
  | FuncType of { params: type_expr list; ret_type: type_expr }
  | MethType of { params: type_expr list; ret_type: type_expr; is_mut: bool }

and param = {
  name: string;
  type_: type_expr
}

and stat =
  | FuncCallStat of func_call
  | DeclStat of decl
  | RetStat of expr
  | ResolveStat of expr

and body =
  | Scope of stat list

and ret_type =
  | SafeRet of type_expr
  | AbortRet of type_expr * type_expr

and decl =
  | FuncDecl of { name: string; params: param list; ret_type: ret_type; body: body }
  | MethDecl of { name: string; params: param list; ret_type: ret_type; is_mut: bool ; body: body }
  | VarDecl of { name: string; type_: type_expr; value: expr }
  | ConstructorDecl of  { name: string; type_: type_expr; args: expr list }

type package = {
  decls: decl list
}
