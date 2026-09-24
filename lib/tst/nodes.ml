(* The typed syntax tree: the SST with every name resolved and every
   expression typed (docs/stages.md, docs/semantics.md §6).

   Read against lib/sst/nodes.ml. What this tree adds is a [ty] on every
   expression and a resolved reference wherever the SST held a name. What it
   takes away is every question resolution answered: which overload a call
   picked, whether `Expr.intLit(x)` is a case or a named constructor, whether
   `a.b` is a field, a case read or an enum-map read. No later stage repeats a
   lookup. *)

module Span = Source.Span

(* A symbol or parameter of the verb being checked. [id] is unique within a
   build, so two locals that share a name in different verbs stay apart. *)
module Local = struct
  type t = { id : int; name : string; ty : Ty.t; span : Span.t }
end

(* D8: a call names its callee, and the generic arguments it was instantiated
   at. *)
module Verb_ref = struct
  type t = {
    owner : Signature.owner;
    name : string;
    instance : (Ty.param * Ty.arg) list;
  }
end

(* D7: a name read as a value. *)
module Name_ref = struct
  type t =
    | Local of Local.t
    (* A package constant or lambda-variable, by declaration. *)
    | Global of { decl : int; name : string }
    (* A number parameter read in a body position (generics.md §3.5). Its
       value is known, because a body is checked per instantiation (D12). *)
    | Number_param of { name : string; value : Ty.number }
    (* `@program$console`, and the like. *)
    | Intrinsic of string
end

module rec Expr : sig
  type t = { node : node; ty : Ty.t; span : Span.t }

  and node =
    | Number_lit of string
    | Text_lit of string
    | Bool_lit of bool
    | Array_lit of t list
    | Map_lit of (t * t) list
    | Var of Name_ref.t
    (* A type written where a value goes, passed to an explicit `Type`
       parameter (generics.md §5.3). *)
    | Type_arg of Ty.t
    (* D10: the SST's [TypeMember] and [Constructor], split by what they
       turned out to be. *)
    | Enum_member of string
    | Case of { case : string; payload : t }
    | Construct of {
        ctor : Verb_ref.t;
        args : Arg.t list;
        handler : Handler.t option;
      }
    (* Field-constructor entries keep their written order, each tagged with
       the slot it fills: reordering them would reorder their evaluation. An
       entry the call omitted is filled by its default and does not appear. *)
    | Construct_fields of {
        ctor : Verb_ref.t;
        fields : Field_value.t list;
        handler : Handler.t option;
      }
    (* The SST's [DotAccess], resolved. *)
    | Field of { target : t; field : string; slot : int }
    | Case_read of { target : t; case : string; handler : Handler.t }
    | Map_read of { target : t; map : int; property : string }
    | Subscript of { target : t; impl : Verb_ref.t; args : t list }
    | Ref of t
    | Init of Field_value.t list
    | Spawn of t
    | Match of Match.t
    | Call of { callee : Verb_ref.t; args : Arg.t list; handler : Handler.t option }
    (* Calling a lambda-variable: there is no declaration to name (D8). *)
    | Call_value of { callee : t; args : Arg.t list; handler : Handler.t option }
    | Op of {
        op : Sst.Nodes.Operator.node;
        impl : Verb_ref.t;
        left : t;
        right : t;
        swapped : bool;
        handler : Handler.t option;
      }
    | Flip of { impl : Verb_ref.t; value : t; handler : Handler.t option }
    (* D9: an implicit constructor the compiler inserted at a coercion site,
       around the argument it converted and with that argument's span. *)
    | Coerce of { ctor : Verb_ref.t; value : t }
    | Lambda of Lambda.t
    (* What an expression that failed to type becomes. Its [ty] is
       [Ty.Error], and the diagnostic has already been reported (D4). *)
    | Invalid
end =
  Expr

and Arg : sig
  type t = Value of Expr.t | Block of Block.t
end =
  Arg

and Field_value : sig
  type t = { name : string; slot : int; value : Expr.t; span : Span.t }
end =
  Field_value

and Handler : sig
  type t = { binder : Local.t option; body : Block.t; span : Span.t }
end =
  Handler

and Block : sig
  type t = { stats : Stat.t list; span : Span.t }
end =
  Block

and Stat : sig
  type t = { node : node; span : Span.t }

  and node =
    | Expr of Expr.t
    | Spawn of Expr.t
    | Let of { local : Local.t; value : Expr.t }
    | Assign of { target : Expr.t; value : Expr.t }
    | Abort of Expr.t
    | Return of Expr.t
    | Resolve of Expr.t
end =
  Stat

and Pattern : sig
  type t = { binder : Local.t option; case : string; span : Span.t }
end =
  Pattern

and Arm : sig
  type t = { patterns : Pattern.t list; body : Block.t; span : Span.t }
end =
  Arm

and Match : sig
  type t = {
    scrutinees : Expr.t list;
    arms : Arm.t list;
    handler : Handler.t option;
  }
end =
  Match

and Lambda : sig
  type t = { params : Local.t list; body : Block.t }
end =
  Lambda

(* A declaration, with everything pass 3 and pass 4 resolved about it and the
   body pass 5 typed. *)
module Decl = struct
  type body =
    | Checked of { params : Local.t list; body : Block.t }
    (* A generic verb's body is checked once per instantiation (D12), so the
       declaration itself carries none; its instances do. *)
    | Per_instance

  type definition =
    | Struct of (string * Ty.t) list
    | Variant of (string * Ty.t) list
    | Enum of string list
    | Distinct of Ty.t

  type node =
    | Type of {
        name : string;
        params : Ty.param list;
        reference : bool;
        definition : definition;
      }
    | Alias of { name : string; params : Ty.param list; target : Ty.t }
    | Constant of { name : string; ty : Ty.t; value : Expr.t }
    | Verb of { signature : Signature.t; body : body }
    | Subscript of { signature : Signature.t; params : Local.t list; value : Expr.t option }
    | Enum_map of {
        enum : Ty.t;
        property : string;
        ty : Ty.t;
        entries : (string * Expr.t) list;
      }

  type t = { id : int; span : Span.t; node : node }
end

(* One body per distinct set of arguments a generic verb was called with
   (D12). *)
module Instance = struct
  type t = {
    decl : int;
    signature : Signature.t;
    args : (Ty.param * Ty.arg) list;
    params : Local.t list;
    body : Block.t;
  }
end

module Package = struct
  type t = { name : string; decls : Decl.t list }
end

module Program = struct
  type t = { packages : Package.t list; instances : Instance.t list }
end
