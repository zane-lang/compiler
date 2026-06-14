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

and name_type =
  | SimpleType of string
  | QualifiedType of string * string

and call_type =
  | FuncType of {
      params: type_expr list;
      ret_type: ret_type
    }
  | MethType of {
      this_type: type_expr;
      params: type_expr list;
      ret_type: ret_type;
      is_mut: bool
    }

and generic_arg =
  | TypeArg of type_expr
  | NumberArg of string

and type_expr =
  | NameType of name_type
  | CallType of call_type
  | GenericType of name_type * generic_arg list

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

and generic_param =
  | TypeParam of string
  | NumberParam of string

and decl =
  | FuncDecl of {
      name: string;
      params: param list;
      ret_type: ret_type;
      body: body
    }
  | MethDecl of {
      name: string;
      this_type: type_expr;
      params: param list;
      ret_type: ret_type;
      is_mut: bool;
      body: body
    }
  | VarDecl of { name: string; type_: type_expr; value: expr }
  | VarDeclShorthand of  { name: string; type_: type_expr; args: expr list }
  | TypeDecl of { name: string; params: generic_param list option; value: type_expr }
  | AliasDecl of { name: string; params: generic_param list option; value: type_expr }

type package = {
  decls: decl list
}

let func_type_of_lambda (x: func_lambda) : type_expr =
  CallType (FuncType {
    params   = List.map (fun (p: param) -> p.type_) x.params;
    ret_type  = x.ret_type;
  })

let meth_type_of_lambda (x: meth_lambda) : type_expr =
  CallType (MethType {
    this_type = x.this_type;
    params    = List.map (fun (p: param) -> p.type_) x.params;
    ret_type  = x.ret_type;
    is_mut    = x.is_mut;
  })
