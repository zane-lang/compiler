(* The CST's job is to represent what was parsed, not what's valid. *)

(* The span type lives below the stages, in [Source], because a source
   location is not CST-specific: SST and everything after it point at the same
   text. Aliased rather than spelled out at each mention. *)
module Span = Source.Span

(* Every node carries where it was written.

   Two shapes, chosen by what the node already is. A node whose [t] is a
   variant becomes a record [{ node; span }] whose [node] is that variant; a
   node whose [t] is already a record gains a [span] field. Either way [t] is
   the spanned thing, so a reference to [Expr.t] cannot accidentally be the
   unspanned one -- the alternative, a generic [`a spanned`] wrapper applied at
   each reference site, makes that a decision to get wrong once per mention.
   This is the shape OCaml's own Parsetree uses, for the same reason.

   [Statement_defect] is the one type here that is not a node: it is a note
   about a statement rather than something written in the source, and it is
   already paired with the position it points at. It stays bare. *)

(* A name as it was written, and where.

   Every identifier in the tree is one of these rather than a bare [string],
   because a name is the thing a diagnostic most often has to point at and it
   is usually smaller than the node holding it: "no field `foo`" wants the
   `foo` in `target.foo`, and "case not covered" wants the one case name inside
   `[a, b, c]`, not the whole selector. A [string] cannot carry that, and the
   enclosing node's span is the wrong answer.

   Where a node's span is already exactly the name -- [Name_type.Ident], say --
   the two spans coincide. That is not worth a special case: a consumer that
   wants a name's position reads it off the name, whichever variant it came
   from, rather than case-splitting on whether this one happens to be
   redundant.

   Literals are not names and stay bare. [Expr.IntLit], [FloatLit], [StrLit]
   and [Generic_arg.Number] each sit in a node whose span is exactly that
   token, and none of them refers to anything a later pass resolves. *)
module Name = struct
  type t = {
    text : string;
    span : Span.t;
  }
end

(* ---------------------------------------------------------------------- *)
(* Leaf types: no back-references into the recursive core, so they live   *)
(* outside the [module rec] chain as ordinary modules.                    *)
(* ---------------------------------------------------------------------- *)

(* [is_loose] records whether the `'` prefix was written.

   A loose operator calls the same implementation as its unprefixed form and
   differs only in where it groups (operators.md §3.1), and the grouping is
   already the tree by the time this node exists -- so the flag changes nothing
   about what the expression means. It is kept because the CST's job is to
   represent what was parsed: `a '* b` and `a * b` are two different pieces of
   source, and a tree that cannot tell them apart cannot be rendered back,
   cannot report `a ''* b` against what was written, and makes the parser the
   stage that dropped the distinction. Collapsing the two is a desugaring, and
   desugaring belongs to the SST (see docs/desugaring.md §2.2 and
   docs/stages.md).

   The flag is always [false] on a declaration: §3.1 is explicit that the loose
   forms add no token to the operator vocabulary of §5.1, so there is nothing
   for a program to declare. *)
module Operator = struct
  type t = {
    node : node;
    is_loose : bool;
    span : Span.t;
  }

  and node =
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
  type t = {
    node : node;
    span : Span.t;
  }

  and node = Value | Reference
end

(* How a statement disagreed with the rules about where it ends.

   The grammar requires every statement to be closed by a `;` or by a `}`, so a
   missing terminator is a parse error and has no defect here. What it still
   admits are the two spellings below, each with a single parse, so they are
   recorded on the statement and read back afterwards rather than rejected in
   an action.

   Not a node: it records something about a statement rather than something
   written, and it already travels with the position it points at. *)
module Statement_defect = struct
  type t =
    (* Ends in `}`, which closes it, and carries a `;` that marks nothing. *)
    | Stray_semicolon
    (* A trailing argument's `}` closes the call and the statement together, so
       nothing may continue it -- `run() { } + Int(1)` writes an operand after
       the statement has already ended. The parenthesized form, `(run() { })
       + Int(1)`, is how that value is continued. *)
    | Continued_trailing_argument
end

module Name_type = struct
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Ident of Name.t
    | Qualified of { package : Name.t; ident : Name.t }
    (* intrinsic namespace, spelled @package$Ident, e.g. @primitives$I32 *)
    | Intrinsic of { package : Name.t; ident : Name.t }
end

module Constructor_name = struct
  type t = {
    type_ : Name_type.t;
    member : Name.t option;
    span : Span.t;
  }
end

module Concept = struct
  type t = {
    node : node;
    span : Span.t;
  }

  and node = Type | Number
end

(* One name taken from a package. The casing class is kept rather than
   recomputed, because an `as` alias must preserve it: a value may not be
   renamed to a type-shaped name, or the reverse. *)
module Import_member = struct
  type t = {
    name : string;
    is_type : bool;
    span : Span.t;
  }
end

(* What an import writes after `import` is what the file writes at the use
   site, so the form is the declaration rather than a detail of it. An alias
   belongs only to the two forms that name a single thing to rename: a list has
   no single name, and the whole-package `pkg$` form qualifies nothing. Those
   two combinations are therefore unrepresentable here rather than rejected
   later. *)
module Import = struct
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    (* import pkg           -> pkg$member
       import pkg as alias  -> alias$member *)
    | Package of { package : Name.t; alias : Name.t option }
    (* import pkg$member           -> member
       import pkg$member as alias  -> alias *)
    | Member of {
        package : Name.t;
        member : Import_member.t;
        alias : Import_member.t option;
      }
    (* import pkg$[memberA, memberB] -> memberA, memberB *)
    | Members of { package : Name.t; members : Import_member.t list }
    (* import pkg$ -> every accessible member, unqualified *)
    | All of { package : Name.t }
end

module Generic_param = struct
  type t = {
    name : Name.t;
    type_ : Concept.t;
    span : Span.t;
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
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Ident of Name.t
    | Qualified of { package : Name.t; ident : Name.t }
    (* intrinsic namespace, spelled @package$ident, e.g. @funcs$strToI32 *)
    | Intrinsic of { package : Name.t; ident : Name.t }
end

module rec Expr : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | IntLit of string
    | FloatLit of string
    | StrLit of string
    | BoolLit of bool
    | CollectionLit of t list
    | NameExpr of Name_expr.t
    | TypeMember of { type_ : Name_type.t; member : Name.t }
    (* A type written where a value is expected: the explicit type argument of
       generics.md §5.3, as in `Array(Int, 10000)`. Types are compile-time
       values, so a name in this position is an ordinary argument rather than a
       second kind of parameter list.

       Only a bare name may be written this way, which is why this carries a
       [Name_type.t] rather than a [Type_expr.t]: an applied `Array<Int, 4>`
       cannot be told from the start of a verb-type suffix list without
       lookahead the parser does not have. See docs/spec-divergences.md. *)
    | TypeValue of Name_type.t
    | DotAccess of { target : t; field : Name.t }
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
    | FuncLambda of Func_lambda.t
    | MethLambda of Meth_lambda.t
end = Expr

and Abort_handle : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Shorthand of Expr.t
    | Longhand of { binder: Name.t option; body: Body.t }
end = Abort_handle

and Field_arg : sig
  type t = {
    name : Name.t;
    value : Expr.t option;
    span : Span.t;
  }
end = Field_arg

(* An argument written at a call site. A block argument is a run of statements
   the callee runs, and it is spelled here rather than in [Expr.t] because it is
   never a value: the grammar admits one only in an argument position. *)
and Call_arg : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Value of Expr.t
    | Block of Statement.t list
end = Call_arg

and Constructor_args : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
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
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Func        of { callee: Expr.t; args: Call_arg.t list; abort_handle: Abort_handle.t option; trailing: bool; }
    | Meth        of { callee: Expr.t; this: Expr.t; args: Call_arg.t list; abort_handle: Abort_handle.t option; is_mut: bool; trailing: bool; }
    | Constructor of { name: Constructor_name.t; args: Constructor_args.t; abort_handle: Abort_handle.t option; trailing: bool; }
    | Op          of { op: Operator.t; left: Expr.t; right: Expr.t; abort_handle: Abort_handle.t option; }
    | Flip        of { value: Expr.t; abort_handle: Abort_handle.t option; }
end = Verb_call

and Body_field : sig
  type t = {
    name : Name.t;
    type_ : Type_expr.t;
    span : Span.t;
  }
end = Body_field

and Mould : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Struct of Body_field.t list
    | Variant of Body_field.t list
    | Enum of Name.t list
end = Mould

and Moulded : sig
  type t = {
    mould : Mould.t;
    axis : Type_axis.t;
    span : Span.t;
  }
end = Moulded

and Generic_arg : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Type of Type_expr.t
    | Number of string
    | NumberRef of Name.t
    | Inferred of Param.t
end = Generic_arg

and Verb_type : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
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
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Path of { name : Name_type.t; generics : Generic_arg.t list }
    | Guest of t
    | Verb of Verb_type.t
    | Parenthesized of t
end = Type_expr

and Param_type : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Concrete of Type_expr.t
    | Concept of Concept.t
    | InferredType of { name : Name.t; concept : Concept.t }
end = Param_type

and Param : sig
  type t = {
    name : Name.t;
    type_ : Param_type.t;
    span : Span.t;
  }
end = Param

and Constructor_field : sig
  type t = {
    name : Name.t;
    type_ : Param_type.t;
    default : Expr.t option;
    span : Span.t;
  }
end = Constructor_field

and Constructor_params : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Positional of Param.t list
    | Fields of Constructor_field.t list
end = Constructor_params

and Match_pattern : sig
  type t = {
    binder : Name.t option;
    cases : Name.t list;
    span : Span.t;
  }
end = Match_pattern

and Match_arm : sig
  type t = {
    patterns : Match_pattern.t list;
    body : Body.t;
    span : Span.t;
  }
end = Match_arm

and Match_expr : sig
  type t = {
    scrutinees : Expr.t list;
    arms : Match_arm.t list;
    abort_handle : Abort_handle.t option;
    span : Span.t;
  }
end = Match_expr

and Stat : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | VerbCall of Verb_call.t
    | Spawn of Verb_call.t
    | Decl of Decl.t
    | Assign of { target : Expr.t; value : Expr.t }
    | Abort of Expr.t
    | Ret of Expr.t
    | Resolve of Expr.t
end = Stat

(* A statement together with what its terminator turned out to be.

   The grammar closes every statement with a `;` or its own `}`, so what can
   still be wrong is a `;` after that brace, or a trailing argument's `}` with
   something written after it. Either is recorded here rather than raised.

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
    span : Span.t;
  }
end = Statement

and Body : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Shorthand of Expr.t
    | Longhand of Statement.t list
end = Body

and Ret_type : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Safe of Type_expr.t
    | Abort of { ok : Type_expr.t; abort : Type_expr.t }
    | Parenthesized of t
end = Ret_type

and Func_lambda : sig
  type t = {
    params : Param.t list;
    ret_type : Ret_type.t;
    body : Body.t;
    span : Span.t;
  }
end = Func_lambda

and Meth_lambda : sig
  type t = {
    this_type : Type_expr.t;
    params : Param.t list;
    ret_type : Ret_type.t;
    is_mut : bool;
    body : Body.t;
    span : Span.t;
  }
end = Meth_lambda

and Type_or_moulded : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Raw of Type_expr.t
    | Moulded of Moulded.t
end = Type_or_moulded

and Verb_decl : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Func of {
        name : Name.t;
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Body.t;
      }
    | Meth of {
        name : Name.t;
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
        member : Name.t option;
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
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Package of Name.t
    | Import of Import.t
    | Var of { name : Name.t; type_ : Type_expr.t; value : Expr.t }
    | VarShorthand of { name : Name.t; constructor : Constructor_name.t; args : Constructor_args.t; trailing : bool }
    | Type of {
        name : Name.t;
        params : Generic_param.t list;
        value : Type_or_moulded.t;
      }
    | Alias of {
        name : Name.t;
        params : Generic_param.t list;
        value : Type_or_moulded.t;
      }
    | EnumMap of {
        enum : Type_expr.t;
        property : Name.t;
        type_ : Type_expr.t;
        entries : (Name.t * Expr.t) list;
      }
    | Verb of Verb_decl.t
end = Decl

(* ---------------------------------------------------------------------- *)
(* Root + helpers. These are not part of the recursion, so they stay out   *)
(* of the [module rec] block and just reference the modules above.         *)
(* ---------------------------------------------------------------------- *)

module Package = struct
  type t = {
    decls : Decl.t list;
    span : Span.t;
  }
end

(* The type a lambda's own shape gives it. The written lambda is the only
   source for this type, so the type node and its parts take the lambda's
   span: nothing narrower was written for them to point at. *)
let func_type_of_lambda (x : Func_lambda.t) : Type_expr.t =
  let span = x.Func_lambda.span in
  {
    Type_expr.span;
    node =
      Type_expr.Verb
        {
          Verb_type.span;
          node =
            Verb_type.Func
              {
                params =
                  List.map (fun (p : Param.t) -> p.Param.type_)
                    x.Func_lambda.params;
                ret_type = x.Func_lambda.ret_type;
              };
        };
  }

let meth_type_of_lambda (x : Meth_lambda.t) : Type_expr.t =
  let span = x.Meth_lambda.span in
  {
    Type_expr.span;
    node =
      Type_expr.Verb
        {
          Verb_type.span;
          node =
            Verb_type.Meth
              {
                this_type = x.Meth_lambda.this_type;
                params =
                  List.map (fun (p : Param.t) -> p.Param.type_)
                    x.Meth_lambda.params;
                ret_type = x.Meth_lambda.ret_type;
                is_mut = x.Meth_lambda.is_mut;
              };
        };
  }
