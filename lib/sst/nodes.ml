(* The SST's job is to represent what the source means, once every shorthand
   has been written out.

   Where the CST answers "what was written", this tree answers "what was
   written, said one way". The rewrites that get from one to the other are
   inventoried in docs/desugaring.md; each one is a surface form collapsing
   into the longhand the spec already defines it as. Nothing here needs a type
   or a resolved name, which is the line docs/desugaring.md draws: a rewrite
   that would need either is refused and left for a later stage.

   Read against lib/cst/nodes.ml, this file is mostly the same tree with
   alternatives removed. Every place the two differ carries a comment saying
   which desugaring took the difference away, so the pair can be diffed and
   the diff explained. *)

(* The leaves that no desugaring touches, taken from the CST rather than
   copied.

   Each of these is "a name, or a spelling of one, as written", which is what
   both trees want; a copy would add a conversion function that is the identity
   in all but the module path, and those are exactly the conversions that hide
   the real ones. The ones that do not appear here are absent because they
   reach [Type_expr] or [Expr], both of which change -- so the whole recursive
   core below is redefined even where an individual node's shape is unchanged.

   The coupling this creates is the right one: if [Name_type] ever grows a
   case, a name written that way is a name the SST has to represent too. *)
module Span = Source.Span
module Name = Cst.Nodes.Name
module Name_type = Cst.Nodes.Name_type
module Name_expr = Cst.Nodes.Name_expr
module Concept = Cst.Nodes.Concept
module Type_axis = Cst.Nodes.Type_axis
module Import_member = Cst.Nodes.Import_member
module Import = Cst.Nodes.Import
module Constructor_name = Cst.Nodes.Constructor_name
module Generic_param = Cst.Nodes.Generic_param

(* The operators that can be implemented, and no others.

   operators.md §2.1 lists them; §2.3 gives the other five -- `-`, `~=`, `>`,
   `<=` and `>=` -- as fixed desugarings into this set and says they are "not
   independently implementable". [Lower] applies those desugarings, so `Sub`,
   `NotEq`, `More`, `LessEq` and `MoreEq` have nowhere left to appear.

   `~` is primitive too and is not here, for the same reason it is not in the
   CST's [Operator.t]: it is unary, and it has its own node
   ([Verb_call.Flip]).

   [is_loose] is gone as well. A loose operator "calls the same implementation
   as its unprefixed form and differs only in where it groups" (§3.1), and the
   grouping was settled before either tree existed; the CST keeps the `'`
   because it records what was written, and this tree does not because it
   records what it meant.

   The span is still the operator as written, which after a derived-operator
   rewrite is the operator the author actually typed: the `Less` in a lowered
   `a >= b` spans the `>=`. That is the rule for every synthesized node here --
   the span of the syntax it came from -- and it is what keeps a diagnostic
   about the lowered form pointing at the unlowered source. *)
module Operator = struct
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Add
    | Mul
    | Div
    | Eq
    | Less
end

(* Whether a call wrote a subject, and with which marker.

   functions.md §2.1: a method "is a verb whose first parameter is `this`", and
   §2.6 desugars `subject:method(arg)` to `method(subject, arg)`. So the SST
   has one call node and the subject is an ordinary first argument -- which is
   what the language means by it, not a flattening of it.

   What cannot go is the marker itself. `a:f(b)` and `f(a, b)` are the same
   shape after the subject moves, but they do not resolve the same way: an
   unqualified method is looked up in its subject's home package (§6.1) while a
   function is found by plain name and imports, and packages.md §3.6 is
   explicit that "methods and operators are therefore not importable members".
   A tree that recorded only [is_mut] would have made the two
   indistinguishable, so [Function] and [Method] stay apart.

   [is_mut] is the `:`/`!` distinction, which is a check rather than a
   meaning -- calling a `mut` method with `:` is illegal and the reverse too
   (§2.5) -- so it travels with the call for the pass that checks it. *)
module Call_form = struct
  type t =
    | Function
    | Method of { is_mut : bool }
end

(* ---------------------------------------------------------------------- *)
(* Recursive core.                                                        *)
(* ---------------------------------------------------------------------- *)

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
    | TypeValue of Name_type.t
    | DotAccess of { target : t; field : Name.t }
    | Subscript of { target : t; args : t list }
    | Ref of t
    (* No [Parenthized]. Parentheses "group an inner expression explicitly"
       (syntax.md §4.7) and the grouping is the tree, so the node had nothing
       left to say. The inner expression keeps its own span, which covers what
       is inside the parentheses rather than the parentheses too -- the one
       thing this rewrite loses, and nothing downstream wants it. *)
    | Init of Field_arg.t list
    | MapLit of (t * t) list
    | Spawn of Verb_call.t
    | Match of Match_expr.t
    | VerbCall of Verb_call.t
    | FuncLambda of Func_lambda.t
    | MethLambda of Meth_lambda.t
end = Expr

(* One shape, not two.

   `expr ?? fallback` "desugars to a `?` block that only resolves a default
   value" (error-handling.md §3.3), so [Lower] writes that block out and the
   `Shorthand` arm has nothing left to hold.

   [binder] stays optional because `??` writes none, and nothing in the
   expanded body reads one. Synthesizing a name to fill the slot would have
   meant inventing an identifier no source could collide with, to bind a value
   no expanded body mentions. *)
and Abort_handle : sig
  type t = {
    binder : Name.t option;
    body : Block.t;
    span : Span.t;
  }
end = Abort_handle

(* [value] is no longer optional. A bare `x` in an `init{ }` or at a
   field-constructor call site is shorthand for `x = x` (types.md §3.6 and
   §3.5), and [Lower] writes the right-hand side out. The name it synthesizes
   takes the field name's span, which is the whole of what was written. *)
and Field_arg : sig
  type t = {
    name : Name.t;
    value : Expr.t;
    span : Span.t;
  }
end = Field_arg

and Call_arg : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Value of Expr.t
    | Block of Block.t
end = Call_arg

(* Both arms stay. Turning a `Fields` call into a `Positional` one needs the
   constructor's declared field order, which is a declaration in some package,
   not syntax. *)
and Constructor_args : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Positional of Call_arg.t list
    | Fields of Field_arg.t list
end = Constructor_args

and Verb_call : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    (* One node for `f(a)`, `x:m(a)` and `x!m(a)`. When [form] is [Method] the
       subject is [args]'s first element, which is where functions.md §2.6 puts
       it. See [Call_form].

       No [trailing]. The two spellings "are the same call" (syntax.md §4.9);
       the flag existed because they do not *end* the same way, which is what
       [Cst.Statement_check] needed to decide whether a `;` belonged. That
       check has already run and passed before this tree is built. *)
    | Call of {
        callee : Expr.t;
        args : Call_arg.t list;
        form : Call_form.t;
        abort_handle : Abort_handle.t option;
      }
    | Constructor of {
        name : Constructor_name.t;
        args : Constructor_args.t;
        abort_handle : Abort_handle.t option;
      }
    (* [left] and [right] are the operands in the order they were written,
       which is the order they are evaluated in (operators.md §2.3).
       [swapped] says the operator receives them the other way round: `a > b`
       is `b < a` (§2.3), so it is a [Less] with [left] `a`, [right] `b` and
       [swapped] set -- `a` is evaluated first and passed second. *)
    | Op of {
        op : Operator.t;
        left : Expr.t;
        right : Expr.t;
        swapped : bool;
        abort_handle : Abort_handle.t option;
      }
    | Flip of {
        value : Expr.t;
        abort_handle : Abort_handle.t option;
      }
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
        params : Param_type.t list;
        ret_type : Ret_type.t;
      }
    | Meth of {
        this_type : Type_expr.t;
        params : Param_type.t list;
        ret_type : Ret_type.t;
        is_mut : bool;
      }
end = Verb_type

(* No [Parenthesized], for the reason [Expr] gives. *)
and Type_expr : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Path of { name : Name_type.t; generics : Generic_arg.t list }
    | Guest of t
    | Verb of Verb_type.t
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

(* One case, not a list.

   A `[ ]` group is "shorthand for one arm per listed case" (adt.md §5.1), and
   [Lower] writes those arms out. The reason the spec gives for the expansion
   is that each expanded arm binds the binder "at *its own* case's payload", so
   a group cannot be checked once however it is stored -- which is why this is
   an expansion rather than a set kept on the arm.

   The case's own [Name.t] keeps its own span, which is the single case name a
   "case not covered" diagnostic wants to point at. The pattern's span is the
   whole `x [a, b]` it came from, since that is the syntax that produced it. *)
and Match_pattern : sig
  type t = {
    binder : Name.t option;
    case : Name.t;
    span : Span.t;
  }
end = Match_pattern

and Match_arm : sig
  type t = {
    patterns : Match_pattern.t list;
    body : Block.t;
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

(* A run of statements, and where it was written.

   This is what the CST's [Body.t] becomes. `=> expr` "means exactly
   `{ return expr }` and adds no other behavior" (functions.md §3.4), so the
   `Shorthand` arm is written out and only the statement list is left. The
   record survives the arm because a body has a span worth keeping: "not every
   path returns" wants to point at the body, and a bare list cannot say where
   it was.

   The CST's [Statement.t] wrapper is gone too. It paired a statement with how
   its terminator disagreed with the rules, and [Cst.parse] refuses a package
   with any such disagreement -- so every one of them is [None] by the time
   this tree can exist. What goes with it is the `;`: a [Stat.t]'s span covers
   the statement, not the mark that ended it. *)
and Block : sig
  type t = {
    stats : Stat.t list;
    span : Span.t;
  }
end = Block

(* No [Parenthesized], for the reason [Expr] gives. *)
and Ret_type : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Safe of Type_expr.t
    | Abort of { ok : Type_expr.t; abort : Type_expr.t }
end = Ret_type

and Func_lambda : sig
  type t = {
    params : Param.t list;
    ret_type : Ret_type.t;
    body : Block.t;
    span : Span.t;
  }
end = Func_lambda

and Meth_lambda : sig
  type t = {
    this_type : Type_expr.t;
    params : Param.t list;
    ret_type : Ret_type.t;
    is_mut : bool;
    body : Block.t;
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
        body : Block.t;
      }
    | Meth of {
        name : Name.t;
        this_type : Type_expr.t;
        params : Param.t list;
        ret_type : Ret_type.t;
        is_mut : bool;
        body : Block.t;
      }
    | Op of {
        op : Operator.t;
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Block.t;
      }
    | Constructor of {
        type_ : Type_expr.t;
        member : Name.t option;
        params : Constructor_params.t;
        body : Block.t;
        is_implicit : bool;
      }
    (* No body: a subscript's "body **MUST** be a place expression"
       (syntax.md §3.6), so there is no `=> expr` to write out and nothing for
       a [Block.t] to hold. *)
    | Subscript of {
        this_type : Type_expr.t;
        params : Param.t list;
        value : Expr.t;
      }
    | Flip of {
        params : Param.t list;
        ret_type : Ret_type.t;
        body : Block.t;
      }
end = Verb_decl

(* One declaration form for a symbol, not two.

   `e Expr.intLit("5")` and `e Expr = Expr.intLit("5")` "declare the same
   thing" (adt.md §3.2), and syntax.md §1.1 fixes the type the symbol gets:
   the base type, "never `Vector2.diagonal` or a per-case type". [Lower] writes
   the shorthand out into [Var], so [VarShorthand] is gone.

   What the rewrite does not settle is what `Expr.intLit(...)` *is* -- a
   variant case form or a named constructor call -- because that depends on
   what `Expr` turns out to be. It does not have to: both yield the base type,
   which is all the rewrite claims. *)
and Decl : sig
  type t = {
    node : node;
    span : Span.t;
  }

  and node =
    | Package of Name.t
    | Import of Import.t
    | Var of { name : Name.t; type_ : Type_expr.t; value : Expr.t }
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

module Package = struct
  type t = {
    decls : Decl.t list;
    span : Span.t;
  }
end
