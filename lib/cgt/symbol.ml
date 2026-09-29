(* The names a program's verbs and types carry in the IR and the binary
   (docs/design/generics.md). A name is the declaration as written, fully
   qualified, so it is unique across the program without being encoded. The
   spelling is defined here rather than by the TST's printer, because a
   symbol is an ABI: it changes only when this module does. *)

module S = Tst.Signature
module Tty = Tst.Ty

(* An intrinsic namespace is written with `%` where the source writes `@`:
   linkers read `@` in an exported symbol as the start of a symbol version
   (`name@VERSION`), and `%` means nothing to them. *)
let namespace n = "%" ^ n

(* A type's name: its package or namespace, its name, and its arguments,
   `geometry$List<%primitives$Int>`. A symbol only ever names a concrete type,
   so a parameter or an ill-typed spot reaching here is a bug in lowering. *)
let rec ty = function
  | Tty.Named ({ Tty.package; name }, args) -> package ^ "$" ^ name ^ args_ args
  | Tty.Intrinsic { namespace = ns; name; args } -> namespace ns ^ "$" ^ name ^ args_ args
  | Tty.Guest t -> "&" ^ ty t
  | Tty.Concept c -> concept c
  | Tty.Verb v -> verb_type v
  | Tty.Param p -> invalid_arg ("Symbol.ty: the type parameter " ^ p.Tty.name ^ " is not concrete")
  | Tty.Error -> invalid_arg "Symbol.ty: an ill-typed type has no symbol"

and args_ = function [] -> "" | args -> "<" ^ String.concat ", " (List.map arg args) ^ ">"

and arg = function
  | Tty.Type t -> ty t
  | Tty.Number n -> number n

and number = function
  | Tty.Known n -> string_of_int n
  | Tty.Number_param p ->
      invalid_arg ("Symbol.number: the number parameter " ^ p.Tty.name ^ " is not concrete")

and concept = function
  | Tty.Integer_lit -> namespace "concepts" ^ "$Int"
  | Tty.Decimal_lit -> namespace "concepts" ^ "$Float"
  | Tty.Text_lit -> namespace "concepts" ^ "$String"
  | Tty.Array_lit (t, n) -> namespace "concepts" ^ "$Array<" ^ ty t ^ ", " ^ number n ^ ">"
  | Tty.Map_lit (k, v) -> namespace "concepts" ^ "$Map<" ^ ty k ^ ", " ^ ty v ^ ">"
  | Tty.Block -> namespace "concepts" ^ "$Block"
  | Tty.Type_value -> "Type"

(* A verb type: its result, `?` and its abort type when it has one, and its
   parameters in brackets, `%primitives$Int[this pkg$Player, pkg$Weapon] mut`. *)
and verb_type (v : Tty.verb) =
  let this_ = match v.Tty.this_ with None -> [] | Some t -> [ "this " ^ ty t ] in
  ty v.Tty.ret
  ^ (match v.Tty.abort with Some a -> "?" ^ ty a | None -> "")
  ^ "[" ^ String.concat ", " (this_ @ List.map ty v.Tty.params) ^ "]"
  ^ if v.Tty.is_mut then " mut" else ""

(* A verb's name: its package, its name, a generic instance's arguments, and
   its parameter types, with `this` before a method's subject:

     pkg$swapWeapon(this pkg$Player, pkg$Weapon)
     pkg$first<%primitives$Int>(this pkg$List<%primitives$Int>)

   Two overloads never take the same parameter types (functions.md §4.1), and
   two instances of one generic never take the same arguments, so no two verbs
   share a name. An explicit `T Type` or number parameter writes its kind; the
   argument it was given is among the instance's. *)
let verb (s : S.t) (instance : (Tty.param * Tty.arg) list) =
  let sub = Tty.subst (List.map (fun ((p : Tty.param), a) -> (p.Tty.id, a)) instance) in
  let param (p : S.param) =
    match p.S.binds with
    | Some { Tty.kind = Tty.Type_kind; _ } -> "Type"
    | Some { Tty.kind = Tty.Number_kind; _ } -> namespace "concepts" ^ "$Int"
    | None -> (if S.is_method s && p.S.name = "this" then "this " else "") ^ ty (sub p.S.ty)
  in
  (match s.S.home with S.Package p -> p | S.Namespace n -> namespace n)
  ^ "$" ^ s.S.name
  ^ args_ (List.map snd instance)
  ^ "(" ^ String.concat ", " (List.map param s.S.params) ^ ")"
