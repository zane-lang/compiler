(* The CST's job is to represent what was parsed, not what's valid. *)

(* ---------------------------------------------------------------------- *)
(* Leaf types: no back-references into the recursive core, so they live   *)
(* outside the [module rec] chain as ordinary modules.                    *)
(* ---------------------------------------------------------------------- *)

(* Short-circuiting keywords, kept apart from Operator.t because they are not
   overloadable and do not evaluate both sides. *)
module Logic_op = struct
  type t =
    | And
    | Or
end

module Operator = struct
  type t =
    | Add
    | Sub
    | Mul
    | Div
    | Eq
    | NotEq
    | LessEq
    | MoreEq
    | Less
    | More
end

module Type_axis = struct
  type t = Value | Reference
end

(* How a statement disagreed with the rules about where it ends.

   All three are decided by the statement's tail, which the grammar cannot see
   at the point it has to choose, so they are recorded on the statement and
   read back afterwards rather than rejected in an action. *)
module Statement_defect = struct
  type t =
    (* Ends in `}`, which closes it, and carries a `;` that marks nothing. *)
    | Stray_semicolon
    (* Does not end in `}`, so nothing else closes it. *)
    | Missing_semicolon
    (* A trailing argument's `}` closes the call and the statement together, so
       nothing may continue it -- `run() { } + Int(1)` writes an operand after
       the statement has already ended. The parenthesized form, `(run() { })
       + Int(1)`, is how that value is continued. *)
    | Continued_trailing_argument
end

module Name_type = struct
  type t =
    | Ident of string
    | Qualified of { package : string; ident : string }
    (* intrinsic namespace, spelled @package$Ident, e.g. @primitives$I32 *)
    | Intrinsic of { package : string; ident : string }
end

module Constructor_name = struct
  type t = {
    type_ : Name_type.t;
    member : string option;
  }
end

module Concept = struct
  type t = Type | Number
end

(* One name taken from a package. The casing class is kept rather than
   recomputed, because an `as` alias must preserve it: a value may not be
   renamed to a type-shaped name, or the reverse. *)
module Import_member = struct
  type t = {
    name : string;
    is_type : bool;
  }
end

(* What an import writes after `import` is what the file writes at the use
   site, so the form is the declaration rather than a detail of it. An alias
   belongs only to the two forms that name a single thing to rename: a list has
   no single name, and the whole-package `pkg$` form qualifies nothing. Those
   two combinations are therefore unrepresentable here rather than rejected
   later. *)
module Import = struct
  type t =
    (* import pkg           -> pkg$member
       import pkg as alias  -> alias$member *)
    | Package of { package : string; alias : string option }
    (* import pkg$member           -> member
       import pkg$member as alias  -> alias *)
    | Member of {
        package : string;
        member : Import_member.t;
        alias : Import_member.t option;
      }
    (* import pkg$[memberA, memberB] -> memberA, memberB *)
    | Members of { package : string; members : Import_member.t list }
    (* import pkg$ -> every accessible member, unqualified *)
    | All of { package : string }
end

module Generic_param = struct
  type t = {
    name : string;
    type_ : Concept.t;
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
    (* intrinsic namespace, spelled @package$ident, e.g. @funcs$strToI32 *)
    | Intrinsic of { package : string; ident : string }
end

module rec Expr : sig
  type t =
    | IntLit of string
    | FloatLit of string
    | StrLit of string
    | BoolLit of bool
    | CollectionLit of t list
    | NameExpr of Name_expr.t
    | TypeMember of { type_ : Name_type.t; member : string }
    | DotAccess of { target : t; field : string }
    | Subscript of { target : t; args : t list }
    | Ref of t
    | Parenthized of t
    | Init of Field_arg.t list
    (* A `{ }` body of `;`-terminated `key, value` entries. Never empty: an
       empty `{ }` in a value position is a block, so the two never compete. *)
    | MapLit of (t * t) list
    | MethodTarget of { callee : t; this : t; is_mut : bool }
    | Pipe of {
        callee : t;
        value : t;
        abort_handle : Abort_handle.t option;
      }
    | Spawn of Verb_call.t
    | Match of Match_expr.t
    | VerbCall of Verb_call.t
    | Logic of { op : Logic_op.t; left : t; right : t }
    | FuncLambda of Func_lambda.t
    | MethLambda of Meth_lambda.t
end = Expr

and Abort_handle : sig
  type t =
    | Shorthand of Expr.t
    | Longhand of { binder: string option; body: Body.t }
end = Abort_handle

and Field_arg : sig
  type t = {
    name : string;
    value : Expr.t option;
  }
end = Field_arg

(* An argument written at a call site. A block argument is a run of statements
   the callee runs, and it is spelled here rather than in [Expr.t] because it is
   never a value: the grammar admits one only in an argument position. *)
and Call_arg : sig
  type t =
    | Value of Expr.t
    | Block of Statement.t list
end = Call_arg

and Constructor_args : sig
  type t =
    | Positional of Call_arg.t list
    | Fields of Field_arg.t list
end = Constructor_args

(* needs grouping because then we can unify the abort handling

   [trailing] records whether the call's last argument was written after the
   `)` rather than inside it. The two spellings mean the same call, so nothing
   downstream of the parser reads it, but they do not end the same way: a
   trailing argument's `}` closes the statement, which decides whether a `;`
   follows and forbids an abort handler after it. That is surface information,
   and a CST that could not tell the two apart could not apply either rule. *)
and Verb_call : sig
  type t =
    | Func        of { callee: Expr.t; args: Call_arg.t list; abort_handle: Abort_handle.t option; trailing: bool; }
    | Meth        of { callee: Expr.t; this: Expr.t; args: Call_arg.t list; abort_handle: Abort_handle.t option; is_mut: bool; trailing: bool; }
    | Constructor of { name: Constructor_name.t; args: Constructor_args.t; abort_handle: Abort_handle.t option; }
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
    | NumberRef of string
    | Inferred of Param.t
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
    | Path of { name : Name_type.t; generics : Generic_arg.t list }
    | Guest of t
    | Verb of Verb_type.t
    | Parenthesized of t
end = Type_expr

and Param_type : sig
  type t =
    | Concrete of Type_expr.t
    | Concept of Concept.t
    | InferredType of { name : string; concept : Concept.t }
end = Param_type

and Param : sig
  type t = {
    name : string;
    type_ : Param_type.t;
  }
end = Param

and Constructor_field : sig
  type t = {
    name : string;
    type_ : Param_type.t;
    default : Expr.t option;
  }
end = Constructor_field

and Constructor_params : sig
  type t =
    | Positional of Param.t list
    | Fields of Constructor_field.t list
end = Constructor_params

and Match_pattern : sig
  type t = {
    binder : string option;
    cases : string list;
  }
end = Match_pattern

and Match_arm : sig
  type t = {
    patterns : Match_pattern.t list;
    body : Body.t;
  }
end = Match_arm

and Match_expr : sig
  type t = {
    scrutinees : Expr.t list;
    arms : Match_arm.t list;
    abort_handle : Abort_handle.t option;
  }
end = Match_expr

and Stat : sig
  type t =
    | VerbCall of Verb_call.t
    | Spawn of Verb_call.t
    | Decl of Decl.t
    | Assign of { target : Expr.t; value : Expr.t }
    | Abort of Expr.t
    | Ret of Expr.t
    | Resolve of Expr.t
end = Stat

(* A statement together with what its terminator turned out to be.

   Whether a `;` was needed is decided by the statement's own tail, which the
   grammar cannot see at the point it has to choose: it accepts either
   spelling, and a mismatch is recorded here rather than raised.

   Recorded, because the parser is GLR and a semantic action runs on every
   live branch -- including the branch that reads `ran Bool = if(ready)` as a
   whole statement, one token before the `{` that continues it. Raising there
   ends the parse rather than that branch, so a valid program dies on a
   reading it was never going to keep. What reaches the finished tree is what
   was really parsed, so the check runs over that instead. *)
and Statement : sig
  type t = {
    stat : Stat.t;
    (* [None] when the statement is well formed. Otherwise how it is not, and
       where to point. *)
    defect : (Statement_defect.t * Lexing.position) option;
  }
end = Statement

and Body : sig
  type t =
    | Shorthand of Expr.t
    | Longhand of Statement.t list
end = Body

and Ret_type : sig
  type t =
    | Safe of Type_expr.t
    | Abort of { ok : Type_expr.t; abort : Type_expr.t }
    | Parenthesized of t
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
        type_ : Type_expr.t;
        member : string option;
        params : Constructor_params.t;
        body : Body.t;
        is_implicit : bool;
      }
    | Subscript of {
        this_type : Type_expr.t;
        params : Param.t list;
        value : Expr.t;
      }
    | Flip of {
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Body.t;
      }
end = Verb_decl

and Decl : sig
  type t =
    | Package of string
    | Import of Import.t
    | Var of { name : string; type_ : Type_expr.t; value : Expr.t }
    | VarShorthand of { name : string; constructor : Constructor_name.t; args : Constructor_args.t }
    | Type of {
        name : string;
        params : Generic_param.t list;
        value : Type_or_moulded.t;
      }
    | Alias of {
        name : string;
        params : Generic_param.t list;
        value : Type_or_moulded.t;
      }
    | EnumMap of {
        enum : Type_expr.t;
        property : string;
        type_ : Type_expr.t;
        entries : (string * Expr.t) list;
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
  Type_expr.Verb
    (Verb_type.Func {
        params = List.map (fun (p : Param.t) -> p.Param.type_) x.Func_lambda.params;
        ret_type = x.Func_lambda.ret_type;
      })

let meth_type_of_lambda (x : Meth_lambda.t) : Type_expr.t =
  Type_expr.Verb
    (Verb_type.Meth {
        this_type = x.Meth_lambda.this_type;
        params = List.map (fun (p : Param.t) -> p.Param.type_) x.Meth_lambda.params;
        ret_type = x.Meth_lambda.ret_type;
        is_mut = x.Meth_lambda.is_mut;
      })
