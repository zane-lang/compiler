(* The CST's job is to represent what was parsed, not what's valid. *)

type operator =
  | Add
  | Sub
  | Mul
  | Div
  | Eq
  | LessEq
  | MoreEq
  | Less
  | More

type expr =
  | IntLit           of string
  | FloatLit         of string
  | StrLit           of string
  | BoolLit          of bool
  | Ident            of string
  | QualifiedIdent   of string * string
  | Op               of { left: expr; right: expr; operator: operator }
  | Flip             of expr
  | Parenthized      of expr
  | FuncCall         of func_call
  | FuncLambda       of func_lambda
  | MethLambda       of meth_lambda

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
  | QualifiedType of string * string
  | FuncType of {
      params: type_expr list;
      ret_type: type_expr
    }
  | MethType of {
      this_type: type_expr;
      params: type_expr list;
      ret_type: type_expr;
      is_mut: bool
    }

and param = {
  name: string;
  type_: type_expr
}

and cond_block = {
  cond: expr;
  block: stat list
}

and cond_seq = {
  if_: cond_block;
  elifs_: cond_block list;
  else_: stat list option;
}

and stat =
  | FuncCallStat of func_call
  | DeclStat of decl
  | AbortStat of expr
  | RetStat of expr
  | ResolveStat of expr
  | CondSeq of cond_seq

and body =
  | Scope of stat list
  | RetShorthand of expr

and ret_type =
  | SafeRet of type_expr
  | AbortRet of type_expr * type_expr

and func_lambda = {
  params: param list;
  ret_type: ret_type;
  body: body
}

and meth_lambda = {
  this_type: type_expr;
  params: param list;
  ret_type: ret_type;
  is_mut: bool;
  body: body
}

and decl =
  | FuncDecl of { name: string; func: func_lambda }
  | MethDecl of { name: string; func: meth_lambda }
  | VarDecl of { name: string; type_: type_expr; value: expr }
  | ConstructorDecl of  { name: string; type_: type_expr; args: expr list }

type package = {
  decls: decl list
}
