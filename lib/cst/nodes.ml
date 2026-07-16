(* The CST's job is to represent what was parsed, not what's valid. *)

(* ---------------------------------------------------------------------- *)
(* Leaf types: no back-references into the recursive core, so they live    *)
(* outside the [module rec] chain as ordinary modules.                     *)
(* ---------------------------------------------------------------------- *)

module Operator = struct
  type t =
    | Add
    | Sub
    | Mul
    | Div
    | Eq
    | LessEq
    | MoreEq
    | Less
    | More
end

module Type_axis = struct
  type t = Value | Reference
end

module Name_type = struct
  type t =
    | Ident of string
    | Qualified of { package : string; ident : string }
end

module Generic_param_type = struct
  type t = Type | Number
end

module Generic_param = struct
  type t = {
    name : string;
    type_ : Generic_param_type.t;
  }
end

(* ---------------------------------------------------------------------- *)
(* Recursive core. Every node is its own module with a [t], so the         *)
(* constructor names no longer need disambiguating suffixes:               *)
(*   FuncCallStat -> Stat.VerbCall,  FuncDecl -> Decl.Func,                 *)
(*   NormalType   -> Type_expr.Normal,  SafeRet -> Ret_type.Safe, ...       *)
(* The [: sig .. end = Name] wrapper is required for recursive modules.     *)
(* ---------------------------------------------------------------------- *)

module Name_expr = struct
  type t =
    | Ident of string
    | Qualified of { package : string; ident : string }
end

module rec Expr : sig
  type t =
    | IntLit of string
    | FloatLit of string
    | StrLit of string
    | BoolLit of bool
    | NameExpr of Name_expr.t
    | DotAccess of { target : t; field : string }
    | ConstructorCall of { type_ : Name_type.t; args : t list }
    | Parenthized of t
    | VerbCall of Verb_call.t
    | FuncLambda of Func_lambda.t
    | MethLambda of Meth_lambda.t
end = Expr

and Abort_handle : sig
  type t =
    | Shorthand of Expr.t
    | Longhand of { binder: string option; body: Body.t }
end = Abort_handle

(* needs grouping because then we can unify the abort handling *)
and Verb_call : sig
  type t =
    | Func        of { callee: Expr.t; args: Expr.t list; abort_handle: Abort_handle.t option; }
    | Meth        of { callee: Expr.t; this: Expr.t; args: Expr.t list; abort_handle: Abort_handle.t option; }
    | Constructor of { name_type: Name_type.t; args: Expr.t list; abort_handle: Abort_handle.t option; }
    | Op          of { op: Operator.t; left: Expr.t; right: Expr.t; abort_handle: Abort_handle.t option; }
    | Flip        of { value: Expr.t; abort_handle: Abort_handle.t option; }
end = Verb_call

and Body_field : sig
  type t = {
    name : string;
    type_ : Type_expr.t;
  }
end = Body_field

and Mould : sig
  type t =
    | Struct of Body_field.t list
    | Variant of Body_field.t list
    | Enum of string list
    | Tuple of Type_expr.t list
end = Mould

and Moulded : sig
  type t = {
    mould : Mould.t;
    axis : Type_axis.t;
  }
end = Moulded

and Generic_arg : sig
  type t =
    | Type of Type_expr.t
    | Number of string
end = Generic_arg

and Verb_type : sig
  type t =
    | Func of {
        params: Param_type.t list;
        ret_type: Ret_type.t
      }
    | Meth of {
        this_type: Type_expr.t;
        params: Param_type.t list;
        ret_type: Ret_type.t;
        is_mut: bool
      }
end = Verb_type

and Type_expr : sig
  type t =
    | Normal of { name : Name_type.t; generics : Generic_arg.t list }
    | Call of Verb_type.t
end = Type_expr

and Param_type : sig
  type t =
    | Normal of Type_expr.t
    | Generic of Generic_param_type.t
end = Param_type

and Param : sig
  type t = {
    name : string;
    type_ : Param_type.t;
  }
end = Param

and Cond_block : sig
  type t = {
    cond : Expr.t;
    block : Stat.t list;
  }
end = Cond_block

and Cond_seq : sig
  type t = {
    if_ : Cond_block.t;
    elifs_ : Cond_block.t list;
    else_ : Stat.t list option;
  }
end = Cond_seq

and Loop : sig
  type t = {
    start : Expr.t option;
    end_ : Expr.t;
    binder : string;
    body : Stat.t list;
  }
end = Loop

and Stat : sig
  type t =
    | VerbCall of Verb_call.t
    | Decl of Decl.t
    | Abort of Expr.t
    | Ret of Expr.t
    | Resolve of Expr.t
    | CondSeq of Cond_seq.t
    | Loop of Loop.t
end = Stat

and Body : sig
  type t =
    | Shorthand of Expr.t
    | Longhand of Stat.t list
end = Body

and Ret_type : sig
  type t =
    | Safe of Type_expr.t
    | Abort of { ok : Type_expr.t; abort : Type_expr.t }
end = Ret_type

and Func_lambda : sig
  type t = {
    params : Param.t list;
    ret_type : Ret_type.t;
    body : Body.t;
  }
end = Func_lambda

and Meth_lambda : sig
  type t = {
    this_type : Type_expr.t;
    params : Param.t list;
    ret_type : Ret_type.t;
    is_mut : bool;
    body : Body.t;
  }
end = Meth_lambda

and Type_or_moulded : sig
  type t =
    | Raw of Type_expr.t
    | Moulded of Moulded.t
end = Type_or_moulded

and Verb_decl : sig
  type t =
    | Func of {
        name : string;
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Body.t;
      }
    | Meth of {
        name : string;
        this_type : Type_expr.t;
        params : Param.t list;
        ret_type : Ret_type.t;
        is_mut : bool;
        body : Body.t;
      }
    | Op of {
        op : Operator.t;
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Body.t;
      }
    | Constructor of {
        type_ : Name_type.t;
        params : Param.t list;
        body : Body.t;
      }
    | Flip of {
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Body.t;
      }
end = Verb_decl

and Decl : sig
  type t =
    | Var of { name : string; type_ : Type_expr.t; value : Expr.t }
    | VarShorthand of { name : string; constructor : Name_type.t; args : Expr.t list }
    | Type of {
        name : string;
        params : Generic_param.t list;
        value : Type_or_moulded.t;
      }
    | Alias of {
        name : string;
        params : Generic_param.t list;
        value : Type_expr.t;
      }
    | Verb of Verb_decl.t
end = Decl

(* ---------------------------------------------------------------------- *)
(* Root + helpers. These are not part of the recursion, so they stay out   *)
(* of the [module rec] block and just reference the modules above.         *)
(* ---------------------------------------------------------------------- *)

module Package = struct
  type t = { decls : Decl.t list }
end

let func_type_of_lambda (x : Func_lambda.t) : Type_expr.t =
  Type_expr.Call
    (Verb_type.Func {
        params = List.map (fun (p : Param.t) -> p.Param.type_) x.Func_lambda.params;
        ret_type = x.Func_lambda.ret_type;
      })

let meth_type_of_lambda (x : Meth_lambda.t) : Type_expr.t =
  Type_expr.Call
    (Verb_type.Meth {
        this_type = x.Meth_lambda.this_type;
        params = List.map (fun (p : Param.t) -> p.Param.type_) x.Meth_lambda.params;
        ret_type = x.Meth_lambda.ret_type;
        is_mut = x.Meth_lambda.is_mut;
      })
