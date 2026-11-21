(* Every name a check resolved, with what it resolved to: the index the
   language server answers "what is this name", "where is it declared" and
   "where else is it used" from (docs/design/language-server.md).

   Semantics already decides what each name means; this records the
   decision where it is made, instead of a second resolver deciding it again.
   A check records nothing unless it was asked to, so a build pays nothing
   for it. *)

module Span = Source.Span

(* What a name resolved to. Each target is declared once, and the use that
   declares it carries [declaration]. *)
type target =
  (* A declaration of a package: a type, alias, constant, verb, subscript or
     enum map, by its id. *)
  | Decl of int
  (* A field of a struct, or a case of a variant, by the type that declares
     it. *)
  | Field of Ty.type_id * string
  (* A member of an enum. *)
  | Member of Ty.type_id * string
  (* A field of a field constructor that declares its own fields, by the
     constructor's declaration id: what a label names in `Box{seed = 1}`. *)
  | Label of int * string
  (* A local or parameter of a verb, by its id. *)
  | Local of int
  (* A type or number parameter, by its id. *)
  | Param of int
  (* A package, by its identity in the build. *)
  | Package of string
  (* A type, value or operation an intrinsic namespace supplies, by its
     spelling, as `@primitives$I64`. *)
  | Intrinsic of string

type use = { span : Span.t; target : target; declaration : bool }

(* What a completion asked about, recorded where a check met the
   placeholder name the language server wrote at the cursor. *)
type probe =
  (* A member read of a value of this type: `value.placeholder`,
     `value:placeholder(...)` or `value:@namespace$placeholder(...)`, in a
     file of [package]. *)
  | Member_of of { ty : Ty.t; package : string; path : string }
  (* A member of this type itself: `Type.placeholder`. *)
  | Type_member_of of Ty.t
  (* A bare name: the locals in scope, innermost first. *)
  | Name_in of { locals : Nodes.Local.t list; package : string; path : string }
  (* A type name, bare or after an intrinsic namespace. *)
  | Type_in of { params : string list; package : string; path : string }

type t = {
  recording : bool;
  mutable uses : use list;
  (* Every local and parameter a use names, for its name and type. *)
  locals : (int, Nodes.Local.t) Hashtbl.t;
  (* The locals that are parameters of a verb or a lambda. *)
  parameters : (int, unit) Hashtbl.t;
  (* Every type and number parameter a use names. *)
  params : (int, Ty.param) Hashtbl.t;
  (* The placeholder name a completion wrote, and what the check found
     where it was written. *)
  placeholder : string option;
  mutable probes : (Span.t * probe) list;
}

let create ?placeholder recording =
  { recording; uses = []; locals = Hashtbl.create 64; parameters = Hashtbl.create 64; params = Hashtbl.create 16; placeholder; probes = [] }

(* No span was written for a node the compiler made up, and nothing can be
   asked about it. *)
let written (span : Span.t) = span.Span.start_.Lexing.pos_cnum >= 0

let add t ?(declaration = false) span target =
  if t.recording && written span then t.uses <- { span; target; declaration } :: t.uses

let local t ?declaration ?(parameter = false) ?span (l : Nodes.Local.t) =
  if t.recording then begin
    Hashtbl.replace t.locals l.Nodes.Local.id l;
    if parameter then Hashtbl.replace t.parameters l.Nodes.Local.id ();
    add t ?declaration (Option.value span ~default:l.Nodes.Local.span) (Local l.Nodes.Local.id)
  end

let param t ?declaration span (p : Ty.param) =
  if t.recording then begin
    Hashtbl.replace t.params p.Ty.id p;
    add t ?declaration span (Param p.Ty.id)
  end

(* Whether [name] is the placeholder a completion wrote. *)
let is_placeholder t name = match t.placeholder with Some p -> String.equal p name | None -> false

let probe t span p = if t.recording then t.probes <- (span, p) :: t.probes
