(* What a call site needs to know about a verb: the same record whether the
   verb was declared in a package or supplied by an intrinsic namespace, so
   overload resolution is one procedure for both (functions.md §5).

   Pass 4 builds one of these per verb declaration (docs/semantics.md §3);
   [Intrinsics] builds the rest. *)

(* Which declaration a call resolved to. An intrinsic has no declaration, so
   it is named by its spelling, `@controlflow$branch`. *)
type owner = Declared of int | Intrinsic of string

(* Where a verb was declared, which is what the home-package rules compare
   against: a package, or the intrinsic namespace that supplies it. *)
type home = Package of string | Namespace of string

type kind =
  | Function
  | Method
  | Operator
  | Flip
  | Constructor of { implicit : bool; member : string option; fields : bool }
  | Subscript

type param = {
  name : string;
  ty : Ty.t;
  (* For an explicit `T Type` or `n Number` value parameter: the generic
     parameter the argument binds (generics.md §5.3). The argument is then a
     type or a number rather than a value of [ty]. *)
  binds : Ty.param option;
  (* A field-constructor entry with an initializer, which a call may omit
     (types.md §3.3). *)
  has_default : bool;
}

type t = {
  owner : owner;
  (* How a diagnostic names it: `first`, `+`, `Span.point`, `@primitives$Int`. *)
  name : string;
  home : home;
  kind : kind;
  (* Every type and number parameter the signature introduces, inline or as
     an explicit value parameter. *)
  generics : Ty.param list;
  (* The subject comes first for a method and a subscript, as functions.md
     §2.6 desugars it. *)
  params : param list;
  ret : Ty.t;
  abort : Ty.t option;
  is_mut : bool;
}

let home_to_string = function Package p -> p | Namespace n -> "@" ^ n

let is_method s = match s.kind with Method | Subscript -> true | _ -> false

let is_implicit s =
  match s.kind with Constructor { implicit; _ } -> implicit | _ -> false

let has_block_param s =
  List.exists
    (fun p -> match p.ty with Ty.Concept (Ty.Block _) -> true | _ -> false)
    s.params

let to_string s =
  let param (p : param) =
    match p.binds with
    | Some b -> (
        p.name ^ match b.Ty.kind with Ty.Type_kind -> " Type" | Ty.Number_kind -> " Number")
    | None ->
        let this_ = if is_method s && p.name = "this" then "this " else "" in
        this_ ^ Ty.to_string p.ty
  in
  let list ps = String.concat ", " (List.map param ps) in
  let mut_ = if s.is_mut then " mut" else "" in
  match (s.kind, s.params) with
  (* A constructor's name is its return type, and a subscript writes none
     (functions.md §2.9): each is printed the way it is declared. *)
  | Constructor { implicit; fields; _ }, ps ->
      (if implicit then "implicit " else "")
      ^ s.name
      ^
      if fields then
        "{"
        ^ String.concat "; "
            (List.map
               (fun (p : param) ->
                 p.name ^ " " ^ param p ^ if p.has_default then " = ..." else "")
               ps)
        ^ "}"
      else "(" ^ list ps ^ ")"
  | Subscript, this_ :: ps ->
      "(" ^ param this_ ^ ")[" ^ list ps ^ "]"
      ^ (match s.ret with Ty.Error -> "" | t -> " => " ^ Ty.to_string t)
  | _, ps -> Ty.ret_to_string s.ret s.abort ^ " " ^ s.name ^ "(" ^ list ps ^ ")" ^ mut_
