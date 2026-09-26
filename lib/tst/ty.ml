(* What an expression's type can be. See docs/semantics.md §4.

   A [Named] type is a `type` declaration applied to its arguments; an `alias`
   never appears here, because it is expanded where it is written (D5), so two
   spellings of one type are one [t] and type equality is structural equality.

   The intrinsic namespaces supply types too. Those are [Intrinsic], carrying
   the namespace they live in -- `primitives` or `runtime` -- rather than a
   package, since the namespace is also where their operators and methods are
   found (functions.md §6.1). The concept types of `@concepts$` and the `Type`
   parameter concept are [Concept]: they type literals, blocks and explicit
   type arguments, and are never storage (syntax.md §2.8). *)

type kind = Type_kind | Number_kind

(* A type or number parameter, introduced by a type's header or at its first
   marked occurrence in a verb signature (generics.md §3.2). [id] is unique
   across the build, so two verbs that both call their parameter `T` never
   confuse one for the other. *)
type param = { id : int; name : string; kind : kind }

(* A declared type is named by its defining package and its name, which is
   also what a compiled symbol will carry (packages.md §3.3). *)
type type_id = { package : string; name : string }

type t =
  | Named of type_id * arg list
  | Intrinsic of { namespace : string; name : string; args : arg list }
  | Guest of t
  | Concept of concept
  | Verb of verb
  | Param of param
  (* The type of an expression that failed to type. Every check accepts it
     silently, so one mistake is one diagnostic (D4). *)
  | Error

and arg = Type of t | Number of number

and number = Known of int | Number_param of param

and concept =
  (* `@concepts$Int`: an integer literal, and what a number parameter is
     declared with and reads as in a body (generics.md §3.3). *)
  | Integer_lit
  | Decimal_lit
  | Text_lit
  | Array_lit of t * number
  | Map_lit of t * t
  (* A block argument: statements that yield nothing (docs/spec-divergences.md
     §12). *)
  | Block
  (* The type of a type written where a value goes: what a `T Type` value
     parameter accepts (generics.md §5.3). *)
  | Type_value

and verb = {
  this_ : t option;
  params : t list;
  ret : t;
  abort : t option;
  is_mut : bool;
}

let fresh_param =
  let next = ref 0 in
  fun ~name ~kind ->
    incr next;
    { id = !next; name; kind }

let unit_primitive = Intrinsic { namespace = "primitives"; name = "Unit"; args = [] }
let bool_primitive = Intrinsic { namespace = "primitives"; name = "Bool"; args = [] }

let rec contains_error = function
  | Error -> true
  | Named (_, args) | Intrinsic { args; _ } -> List.exists arg_contains_error args
  | Guest t -> contains_error t
  | Concept c -> concept_contains_error c
  | Verb v ->
      Option.fold ~none:false ~some:contains_error v.this_
      || List.exists contains_error v.params
      || contains_error v.ret
      || Option.fold ~none:false ~some:contains_error v.abort
  | Param _ -> false

and arg_contains_error = function
  | Type t -> contains_error t
  | Number _ -> false

and concept_contains_error = function
  | Array_lit (t, _) -> contains_error t
  | Map_lit (k, v) -> contains_error k || contains_error v
  | _ -> false

(* ---------------------------------------------------------------------- *)
(* Printing                                                               *)
(* ---------------------------------------------------------------------- *)

let rec to_string = function
  | Named ({ package; name }, args) -> package ^ "$" ^ name ^ args_to_string args
  | Intrinsic { namespace; name; args } ->
      "@" ^ namespace ^ "$" ^ name ^ args_to_string args
  | Guest t -> "&" ^ to_string t
  | Concept c -> concept_to_string c
  | Verb v -> verb_to_string v
  | Param p -> p.name
  | Error -> "<error>"

and args_to_string = function
  | [] -> ""
  | args -> "<" ^ String.concat ", " (List.map arg_to_string args) ^ ">"

and arg_to_string = function
  | Type t -> to_string t
  | Number n -> number_to_string n

and number_to_string = function
  | Known n -> string_of_int n
  | Number_param p -> p.name

and concept_to_string = function
  | Integer_lit -> "@concepts$Int"
  | Decimal_lit -> "@concepts$Float"
  | Text_lit -> "@concepts$String"
  | Array_lit (t, n) ->
      "@concepts$Array<" ^ to_string t ^ ", " ^ number_to_string n ^ ">"
  | Map_lit (k, v) -> "@concepts$Map<" ^ to_string k ^ ", " ^ to_string v ^ ">"
  | Block -> "@concepts$Block"
  | Type_value -> "Type"

and ret_to_string ret abort =
  match abort with
  | None -> to_string ret
  | Some a -> to_string ret ^ "?" ^ to_string a

and verb_to_string v =
  let this_ =
    match v.this_ with None -> [] | Some t -> [ "this " ^ to_string t ]
  in
  ret_to_string v.ret v.abort
  ^ "["
  ^ String.concat ", " (this_ @ List.map to_string v.params)
  ^ "]"
  ^ if v.is_mut then " mut" else ""

(* ---------------------------------------------------------------------- *)
(* Substitution                                                           *)
(* ---------------------------------------------------------------------- *)

(* What each parameter stands for, by [param.id]. *)
type subst = (int * arg) list

let rec subst (s : subst) t =
  if s = [] then t
  else
    match t with
    | Param p -> (
        match List.assoc_opt p.id s with
        | Some (Type t) -> t
        | Some (Number _) | None -> t)
    | Named (id, args) -> Named (id, List.map (subst_arg s) args)
    | Intrinsic i -> Intrinsic { i with args = List.map (subst_arg s) i.args }
    | Guest t -> Guest (subst s t)
    | Concept c -> Concept (subst_concept s c)
    | Verb v ->
        Verb
          {
            v with
            this_ = Option.map (subst s) v.this_;
            params = List.map (subst s) v.params;
            ret = subst s v.ret;
            abort = Option.map (subst s) v.abort;
          }
    | Error -> Error

and subst_arg s = function
  | Type t -> Type (subst s t)
  | Number n -> Number (subst_number s n)

and subst_number s = function
  | Known n -> Known n
  | Number_param p as n -> (
      match List.assoc_opt p.id s with Some (Number m) -> m | _ -> n)

and subst_concept s = function
  | Array_lit (t, n) -> Array_lit (subst s t, subst_number s n)
  | Map_lit (k, v) -> Map_lit (subst s k, subst s v)
  | c -> c

(* The parameters a type still mentions, first occurrence first. *)
let free_params t =
  let seen = ref [] in
  let add p = if not (List.exists (fun q -> q.id = p.id) !seen) then seen := p :: !seen in
  let rec go = function
    | Param p -> add p
    | Named (_, args) | Intrinsic { args; _ } -> List.iter go_arg args
    | Guest t -> go t
    | Concept c -> go_concept c
    | Verb v ->
        Option.iter go v.this_;
        List.iter go v.params;
        go v.ret;
        Option.iter go v.abort
    | Error -> ()
  and go_arg = function Type t -> go t | Number n -> go_number n
  and go_number = function Known _ -> () | Number_param p -> add p
  and go_concept = function
    | Array_lit (t, n) -> go t; go_number n
    | Map_lit (k, v) -> go k; go v
    | _ -> ()
  in
  go t;
  List.rev !seen

(* ---------------------------------------------------------------------- *)
(* Comparison                                                             *)
(* ---------------------------------------------------------------------- *)

(* The passing mode is not part of what a value is: a `&T` argument and a `T`
   one carry the same type, and which mode a position may take is a question
   for the lifetime analysis (docs/semantics.md D1), not for typing. So the
   comparisons below look through a guest marker at the top of either side. *)
let strip_guest = function Guest t -> t | t -> t

let rec equal a b =
  match (a, b) with
  | Error, _ | _, Error -> true
  | Named (x, xs), Named (y, ys) -> x = y && args_equal xs ys
  | Intrinsic x, Intrinsic y ->
      x.namespace = y.namespace && x.name = y.name && args_equal x.args y.args
  | Guest x, Guest y -> equal x y
  | Concept x, Concept y -> concept_equal x y
  | Verb x, Verb y ->
      Option.equal equal x.this_ y.this_
      && List.length x.params = List.length y.params
      && List.for_all2 equal x.params y.params
      && equal x.ret y.ret
      && Option.equal equal x.abort y.abort
      && x.is_mut = y.is_mut
  | Param x, Param y -> x.id = y.id
  | _ -> false

and args_equal xs ys =
  List.length xs = List.length ys && List.for_all2 arg_equal xs ys

and arg_equal a b =
  match (a, b) with
  | Type x, Type y -> equal x y
  | Number x, Number y -> number_equal x y
  | _ -> false

and number_equal a b =
  match (a, b) with
  | Known x, Known y -> x = y
  | Number_param x, Number_param y -> x.id = y.id
  | _ -> false

and concept_equal a b =
  match (a, b) with
  | Array_lit (t, n), Array_lit (u, m) -> equal t u && number_equal n m
  | Map_lit (k, v), Map_lit (k', v') -> equal k k' && equal v v'
  | x, y -> x = y

(* Whether a value of [src] may be stored where [dst] is declared, at a
   position that is not a coercion site: a declaration, an assignment, a
   `return`. Exact, up to the passing mode, with the one relaxation the spec
   gives function values: a lambda that does not declare `mut` may be held by
   a `mut` function type (functions.md §7.2). *)
let assignable ~dst ~src =
  match (strip_guest dst, strip_guest src) with
  | Verb d, Verb s when d.is_mut && not s.is_mut -> equal (Verb d) (Verb { s with is_mut = true })
  | d, s -> equal d s

(* ---------------------------------------------------------------------- *)
(* Inference                                                              *)
(* ---------------------------------------------------------------------- *)

(* A literal's concept type fixes no concrete type, so it "MUST NOT drive
   inference" (generics.md §5.4). *)
let is_bare_literal = function
  | Concept (Integer_lit | Decimal_lit | Text_lit) -> true
  | _ -> false

(* Match [pattern], which mentions the parameters in [open_], against
   [actual], extending [s]. [None] when they cannot be made equal. *)
let rec unify ~open_ (s : subst) pattern actual : subst option =
  let is_open p = List.exists (fun q -> q.id = p.id) open_ in
  match (pattern, actual) with
  | Error, _ -> Some s
  (* An open parameter binds even to [Error], so a type that failed to
     resolve -- or a generic body checked with its parameters unknown -- still
     fixes it, and what depends on it is accepted rather than unbound. *)
  | Param p, _ when is_open p -> (
      match List.assoc_opt p.id s with
      | Some (Type bound) -> if equal bound actual then Some s else None
      | Some (Number _) -> None
      | None -> if is_bare_literal actual then None else Some ((p.id, Type actual) :: s))
  | _, Error -> Some s
  | Named (x, xs), Named (y, ys) when x = y -> unify_args ~open_ s xs ys
  | Intrinsic x, Intrinsic y when x.namespace = y.namespace && x.name = y.name ->
      unify_args ~open_ s x.args y.args
  | Guest x, Guest y -> unify ~open_ s x y
  | Concept x, Concept y -> unify_concept ~open_ s x y
  | Verb x, Verb y
    when List.length x.params = List.length y.params
         && x.is_mut = y.is_mut
         && Option.is_some x.this_ = Option.is_some y.this_
         && Option.is_some x.abort = Option.is_some y.abort ->
      let pairs =
        (match (x.this_, y.this_) with Some a, Some b -> [ (a, b) ] | _ -> [])
        @ List.combine x.params y.params
        @ [ (x.ret, y.ret) ]
        @ match (x.abort, y.abort) with Some a, Some b -> [ (a, b) ] | _ -> []
      in
      List.fold_left
        (fun acc (a, b) -> Option.bind acc (fun s -> unify ~open_ s a b))
        (Some s) pairs
  | _ -> if equal pattern actual && free_params pattern = [] then Some s else None

and unify_args ~open_ s xs ys =
  if List.length xs <> List.length ys then None
  else
    List.fold_left2
      (fun acc x y ->
        Option.bind acc (fun s ->
            match (x, y) with
            | Type a, Type b -> unify ~open_ s a b
            | Number a, Number b -> unify_number ~open_ s a b
            | _ -> None))
      (Some s) xs ys

and unify_number ~open_ s pattern actual =
  match pattern with
  | Number_param p when List.exists (fun q -> q.id = p.id) open_ -> (
      match List.assoc_opt p.id s with
      | Some (Number bound) -> if number_equal bound actual then Some s else None
      | Some (Type _) -> None
      | None -> Some ((p.id, Number actual) :: s))
  | _ -> if number_equal pattern actual then Some s else None

and unify_concept ~open_ s x y =
  match (x, y) with
  | Array_lit (t, n), Array_lit (u, m) ->
      Option.bind (unify ~open_ s t u) (fun s -> unify_number ~open_ s n m)
  | Map_lit (k, v), Map_lit (k', v') ->
      Option.bind (unify ~open_ s k k') (fun s -> unify ~open_ s v v')
  | x, y -> if x = y then Some s else None

(* A signature's parameter list, spelled so that two lists that differ only
   in what their parameters are called read the same: each parameter becomes
   its position of first occurrence. That is overload identity
   (functions.md §4.1), and it is how two generic overloads compare. *)
let canonical ts =
  let order = ref [] in
  let index p =
    match List.assoc_opt p.id !order with
    | Some i -> i
    | None ->
        let i = List.length !order in
        order := (p.id, i) :: !order;
        i
  in
  let rec go = function
    | Param p -> "$" ^ string_of_int (index p)
    | Named ({ package; name }, args) -> package ^ "$" ^ name ^ go_args args
    | Intrinsic { namespace; name; args } -> "@" ^ namespace ^ "$" ^ name ^ go_args args
    | Guest t -> "&" ^ go t
    | Concept c -> (
        match c with
        | Array_lit (t, n) -> "@concepts$Array<" ^ go t ^ "," ^ go_number n ^ ">"
        | Map_lit (k, v) -> "@concepts$Map<" ^ go k ^ "," ^ go v ^ ">"
        | c -> concept_to_string c)
    | Verb v ->
        (match v.this_ with Some t -> "this " ^ go t ^ ";" | None -> "")
        ^ String.concat "," (List.map go v.params)
        ^ "->" ^ go v.ret
        ^ (match v.abort with Some a -> "?" ^ go a | None -> "")
        ^ if v.is_mut then " mut" else ""
    | Error -> "<error>"
  and go_args = function
    | [] -> ""
    | args -> "<" ^ String.concat "," (List.map go_arg args) ^ ">"
  and go_arg = function Type t -> go t | Number n -> go_number n
  and go_number = function
    | Known n -> string_of_int n
    | Number_param p -> "$" ^ string_of_int (index p)
  in
  String.concat ", " (List.map go ts)
