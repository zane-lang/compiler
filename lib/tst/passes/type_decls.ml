(* Resolving type expressions, and pass 3 (docs/design/semantics.md §3): every `type`
   and `alias` right-hand side resolved to a [Ty.t].

   The resolver is shared by the later passes too. Its scope says which names
   are parameters: a type's header, a verb signature's inline introductions
   (generics.md §3.2), or -- inside a body checked for one instantiation --
   the concrete arguments those parameters stand for (D12). *)

open Env
module N = Sst.Nodes

type scope = {
  file : Env.file;
  (* A parameter name and what it resolves to: [Ty.Type (Param p)] while a
     signature is being resolved, the argument itself inside an instance. *)
  params : (string * Ty.arg) list;
  (* A verb signature, where a `T Type` inside `< >` introduces a parameter
     rather than being a mistake. The introductions were found before any type
     was resolved, so each one is already in [params] by the time it is met. *)
  signature : bool;
}

let scope ?(params = []) ?(signature = false) file = { file; params; signature }

(* How a type name was written, for a message about it. *)
let name_type_text (n : N.Name_type.t) =
  match n.N.Name_type.node with
  | N.Name_type.Ident i -> i.N.Name.text
  | N.Name_type.Qualified { package; ident } -> package.N.Name.text ^ "$" ^ ident.N.Name.text
  | N.Name_type.Intrinsic { package; ident } -> "@" ^ package.N.Name.text ^ "$" ^ ident.N.Name.text

(* `@concepts$Int`, the concept a number parameter is declared with
   (generics.md §3.3). An intrinsic namespace is spelled the same in every
   file, so this needs no scope. *)
let is_integer_concept (n : N.Name_type.t) = name_type_text n = "@concepts$Int"

let is_integer_concept_type (te : N.Type_expr.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Path { name; generics = [] } -> is_integer_concept name
  | _ -> false


(* ---------------------------------------------------------------------- *)
(* Kind                                                                   *)
(* ---------------------------------------------------------------------- *)

let rec is_reference env ?(seen = []) (t : Ty.t) =
  match t with
  | Ty.Named (tid, args) -> (
      match Types.type_info_of_id env.types tid with
      | None -> false
      | Some info -> (
          match info.reference with
          | Some r -> r
          | None -> (
              match info.definition with
              | Some (Distinct rhs) when not (List.mem tid seen) ->
                  is_reference env ~seen:(tid :: seen) (Ty.instantiate info.params args rhs)
              | _ -> false)))
  | Ty.Intrinsic { namespace; name; _ } -> (
      match Intrinsics.find_type namespace name with
      | Some t -> t.reference
      | None -> false)
  | Ty.Reference _ -> true
  | Ty.Roaming t -> is_reference env ~seen t
  | _ -> false

let type_info_of_id env tid = Types.type_info_of_id env.types tid

(* A concept type is never storage (syntax.md §2.8): not a field, not a
   local, not an element of a stored type. *)
let rec concept_in (t : Ty.t) =
  match t with
  | Ty.Concept _ -> Some t
  | Ty.Named (_, args) | Ty.Intrinsic { args; _ } ->
      List.find_map (function Ty.Type t -> concept_in t | Ty.Number _ -> None) args
  | Ty.Reference t | Ty.Roaming t -> concept_in t
  | _ -> None

let mentions_concept t = Option.is_some (concept_in t)

(* How a message names the concept a type holds: the type itself, or the
   type argument that is one. *)
let describe_concept (t : Ty.t) =
  match concept_in t with
  | Some c when c == t || Ty.equal c t -> Printf.sprintf "%s is a concept type" (quote (Ty.to_string t))
  | Some c ->
      Printf.sprintf "%s holds %s, a concept type" (quote (Ty.to_string t)) (quote (Ty.to_string c))
  | None -> quote (Ty.to_string t)

(* [roaming] says whether the storage may be a roaming owner: a local may,
   and a field, a constant or a type's definition may not (syntax.md §2.3). *)
let check_storage env ?(roaming = false) span what (t : Ty.t) =
  if mentions_concept t then
    error env span
      (Printf.sprintf "%s, which may type a parameter but is never storage, so it cannot be %s"
         (describe_concept t) what)
  else if Ty.is_roaming t && not roaming then
    error env span
      (Printf.sprintf
         "%s is a roaming owner, and `^` is written only on a local, a parameter or a return \
          type, so it cannot be %s"
         (quote (Ty.to_string t)) what)

(* `&` and `^` mark only a reference type (memory.md §2.1, §2.4). A type
   parameter may be either kind, and is checked where it is filled. Kinds
   are known only once every type is defined, so a marker met before then
   is checked afterwards. *)
let check_marker env span (marked : Ty.t) =
  match Types.deferred env.types with
  | Some deferred -> Queue.push (marked, span) deferred.marks
  | None -> (
      match marked with
      | Ty.Reference (Ty.Param _ | Ty.Error) | Ty.Roaming (Ty.Param _ | Ty.Error) -> ()
      | Ty.Reference inner when not (is_reference env inner) ->
          error env span
            (Printf.sprintf
               "%s is a value type, and `&` marks only a reference type (a `#` \
                mould or a reference primitive)"
               (quote (Ty.to_string inner)))
      | Ty.Roaming inner when not (is_reference env inner) ->
          error env span
            (Printf.sprintf
               "%s is a value type, and `^` marks only a roaming owner of a reference type; a \
                value is never owned, only copied"
               (quote (Ty.to_string inner)))
      | _ -> ())

(* A reference-typed result is a roaming owner or a reference, written `^T`
   or `&T`: a bare one would hand back a borrow, which is never returned
   (memory.md §2.9, syntax.md §3.1). An abort hands its value to the
   caller's handler as a return hands it to the caller (lifetimes.md §1.7),
   so an abort type follows the same rule. *)
let bare_reference env (t : Ty.t) =
  match t with
  | Ty.Reference _ | Ty.Roaming _ | Ty.Param _ | Ty.Error -> false
  | t -> is_reference env t

let check_result env span what (t : Ty.t) =
  if bare_reference env t then
    error env span
      (Printf.sprintf
         "%s %s, a reference type, bare; a borrow is never returned, so write `^%s` to hand back \
          an owner or `&%s` to hand back a reference"
         what (quote (Ty.to_string t)) (Ty.to_string t) (Ty.to_string t))

(* The same rule for every function type written inside [t]. *)
let rec check_function_types env span (t : Ty.t) =
  match t with
  | Ty.Verb v ->
      check_result env span "this function type returns" v.Ty.ret;
      Option.iter (check_result env span "this function type aborts with") v.Ty.abort;
      List.iter (check_function_types env span) (Option.to_list v.Ty.this_ @ v.Ty.params @ [ v.Ty.ret ])
  | Ty.Named (_, args) | Ty.Intrinsic { args; _ } ->
      List.iter (function Ty.Type t -> check_function_types env span t | Ty.Number _ -> ()) args
  | Ty.Reference t | Ty.Roaming t -> check_function_types env span t
  | _ -> ()

(* A type argument of the wrong kind (generics.md §3.6): a reference type,
   or an `&`, that an instance puts where a value mould holds only values
   (memory.md §2.10), or a value type it puts under an `&` written over a
   type parameter (memory.md §2.4). The walk follows what the instance
   builds: the fields of each mould it applies, with the arguments
   substituted, down through the moulds those fields apply in turn, and an
   `@primitives$Array`'s elements. It does not look inside the arguments
   themselves, which were checked where they were written. What it finds is
   the slot that rejects the type, as the path that reaches it, and the
   type. *)
type slot = Value_slot | Under_reference | Under_take | List_element | Bare_result

type wrong_kind = { path : string list; bad : Ty.t; slot : slot }

(* A value type for `&`: what `&` cannot mark (memory.md §2.4). *)
let is_value env (t : Ty.t) =
  match t with
  | Ty.Param _ | Ty.Error | Ty.Concept _ | Ty.Reference _ | Ty.Roaming _ -> false
  | t -> not (is_reference env t)

(* The value types [inst] puts where [raw] writes `&` over a type parameter,
   and the `&` types it puts where [raw] writes `^` over one, each with the
   slot that rejects it. An `&` or `^` written over a concrete type was
   checked where it was written. *)
let rec filled_references env (raw : Ty.t) (inst : Ty.t) =
  match (raw, inst) with
  | Ty.Reference (Ty.Param _), Ty.Reference x -> if is_value env x then [ (x, Under_reference) ] else []
  | Ty.Roaming (Ty.Param _), Ty.Roaming (Ty.Reference _ as x) -> [ (x, Under_take) ]
  | (Ty.Reference r | Ty.Roaming r), (Ty.Reference i | Ty.Roaming i) -> filled_references env r i
  (* A literal's elements are passed in the mode its element writes. *)
  | Ty.Concept (Ty.Array_lit (r, _)), Ty.Concept (Ty.Array_lit (i, _)) -> filled_references env r i
  | Ty.Named (_, ra), Ty.Named (_, ia) | Ty.Intrinsic { args = ra; _ }, Ty.Intrinsic { args = ia; _ }
    when List.length ra = List.length ia ->
      List.concat
        (List.map2
           (fun r i ->
             match (r, i) with Ty.Type r, Ty.Type i -> filled_references env r i | _ -> [])
           ra ia)
  | Ty.Verb r, Ty.Verb i -> (
      match (verb_parts r, verb_parts i) with
      | rs, is when List.length rs = List.length is ->
          List.concat (List.map2 (filled_references env) rs is)
      | _ -> [])
  | _ -> []

and verb_parts (v : Ty.verb) =
  Option.to_list v.Ty.this_ @ v.Ty.params @ [ v.Ty.ret ] @ Option.to_list v.Ty.abort

(* A function type's parts keep their passing modes: a borrow, a take and a
   reference are passed differently, so a function is used only at the
   modes it was written with. The one latitude is `^` over a type
   parameter filled with a value type, which is a plain value (memory.md
   §2.9). [expected] is a parameter's type with its arguments filled in;
   [actual] is the argument's. *)
let rec modes_agree env (expected : Ty.t) (actual : Ty.t) =
  let rec erase (t : Ty.t) : Ty.t =
    match t with
    | Ty.Roaming v when Ty.free_params v = [] && v <> Ty.Error && not (is_reference env v) -> erase v
    | Ty.Roaming v -> Ty.Roaming (erase v)
    | Ty.Reference v -> Ty.Reference (erase v)
    | Ty.Verb v ->
        Ty.Verb
          {
            v with
            Ty.this_ = Option.map erase v.Ty.this_;
            params = List.map erase v.Ty.params;
            ret = erase v.Ty.ret;
            abort = Option.map erase v.Ty.abort;
          }
    | Ty.Named (id, args) -> Ty.Named (id, List.map erase_arg args)
    | Ty.Intrinsic i -> Ty.Intrinsic { i with args = List.map erase_arg i.args }
    | t -> t
  and erase_arg = function Ty.Type t -> Ty.Type (erase t) | n -> n in
  match (Ty.strip_mode expected, Ty.strip_mode actual) with
  | Ty.Verb _, Ty.Verb _ ->
      Ty.contains_error expected || Ty.contains_error actual
      || Ty.equal (erase (Ty.strip_mode expected)) (erase (Ty.held_as ~dst:expected ~src:actual))
  | Ty.Named (x, xs), Ty.Named (y, ys) when x = y && List.length xs = List.length ys ->
      List.for_all2 (modes_agree_arg env) xs ys
  | Ty.Intrinsic x, Ty.Intrinsic y when List.length x.args = List.length y.args ->
      List.for_all2 (modes_agree_arg env) x.args y.args
  | _ -> true

and modes_agree_arg env a b =
  match (a, b) with Ty.Type a, Ty.Type b -> modes_agree env a b | _ -> true

(* The reference types [inst] puts where [raw] writes a bare type parameter
   as a result or abort type: of the verb itself when [top], and of every
   function type inside it. Such a result would hand back a borrow
   (memory.md §2.9), which a written signature is rejected for. *)
let rec bare_results env ~top (raw : Ty.t) (inst : Ty.t) =
  let here r i = match r with Ty.Param _ when is_reference env i -> [ i ] | _ -> [] in
  let inside r i = bare_results env ~top:false r i in
  match (raw, inst) with
  | Ty.Param _, i when top -> here raw i
  | (Ty.Reference r | Ty.Roaming r), (Ty.Reference i | Ty.Roaming i) -> inside r i
  | Ty.Verb r, Ty.Verb i
    when List.length r.Ty.params = List.length i.Ty.params
         && Option.is_some r.Ty.abort = Option.is_some i.Ty.abort ->
      here r.Ty.ret i.Ty.ret
      @ (match (r.Ty.abort, i.Ty.abort) with Some r, Some i -> here r i | _ -> [])
      @ List.concat (List.map2 inside (verb_parts r) (verb_parts i))
  | Ty.Named (_, ra), Ty.Named (_, ia) | Ty.Intrinsic { args = ra; _ }, Ty.Intrinsic { args = ia; _ }
    when List.length ra = List.length ia ->
      List.concat
        (List.map2 (fun r i -> match (r, i) with Ty.Type r, Ty.Type i -> inside r i | _ -> []) ra ia)
  | _ -> []

(* Whether a value slot of type [ft] holds a reference. *)
let holds_reference env (ft : Ty.t) =
  match ft with
  | Ty.Reference _ -> true
  | Ty.Param _ | Ty.Error | Ty.Roaming _ -> false
  | ft -> is_reference env ft

(* A wrong kind found inside a part of a type, reached through [step]. *)
let through step = Option.map (fun found -> { found with path = step :: found.path })

let rec wrong_kind env ?(seen = []) (t : Ty.t) : wrong_kind option =
  let elements () = Printf.sprintf "the elements of %s" (quote (Ty.to_string t)) in
  match t with
  | Ty.Named (tid, args) when not (List.mem tid seen) -> (
      let seen = tid :: seen in
      match Types.type_info_of_id env.types tid with
      | Some ({ definition = Some (Struct fs | Variant fs); _ } as info) ->
          List.find_map (wrong_kind_in_field env ~seen t info args) fs
      | Some ({ definition = Some (Distinct u); _ } as info) ->
          wrong_kind env ~seen (Ty.instantiate info.params args u)
      | _ -> None)
  | Ty.Intrinsic
      { namespace = "primitives"; name = "ListRef"; args = Ty.Type (Ty.Reference x as e) :: _ }
    when not (is_value env x) ->
      Some { path = [ elements () ]; bad = e; slot = List_element }
  | Ty.Intrinsic { namespace = "primitives"; name = "Array" | "List"; args = Ty.Type e :: _ }
    when holds_reference env e ->
      Some { path = [ elements () ]; bad = e; slot = Value_slot }
  | Ty.Intrinsic
      { namespace = "primitives"; name = "Array" | "ArrayRef" | "List" | "ListRef"; args = Ty.Type e :: _ }
    ->
      through (elements ()) (wrong_kind env ~seen (Ty.strip_mode e))
  | _ -> None

(* The first wrong kind field [n] of [t] holds, in the field itself or
   inside its type. *)
and wrong_kind_in_field env ~seen t (info : type_info) args (n, raw) =
  let step = Printf.sprintf "%s's field %s" (quote (Ty.to_string t)) (quote n) in
  let ft = Ty.instantiate info.params args raw in
  if info.reference = Some false && holds_reference env ft then
    Some { path = [ step ]; bad = ft; slot = Value_slot }
  else
    match (filled_references env raw ft, bare_results env ~top:false raw ft) with
    | (x, slot) :: _, _ -> Some { path = [ step ]; bad = x; slot }
    | [], x :: _ -> Some { path = [ step ]; bad = x; slot = Bare_result }
    | [], [] -> through step (wrong_kind env ~seen (Ty.strip_mode ft))

let describe_wrong_kind { path; bad; slot } =
  (* An `&` type is a reference, not a reference type (memory.md §2.4). *)
  let what = match bad with Ty.Reference _ -> "a reference" | _ -> "a reference type" in
  match slot with
  | Under_reference ->
      Printf.sprintf
        "%s is a value type, and it fills an `&`%s; `&` marks only a reference type, since a value \
         is never referenced, only copied"
        (quote (Ty.to_string bad))
        (if path = [] then "" else " at " ^ String.concat ", then " path)
  | Under_take ->
      Printf.sprintf
        "%s is a reference, and it fills a `^`%s; `^` takes an owner, and a reference has none \
         to hand over"
        (quote (Ty.to_string bad))
        (if path = [] then "" else " at " ^ String.concat ", then " path)
  | List_element ->
      Printf.sprintf
        "%s is a reference, and it fills %s; a `ListRef`'s elements are owners, never references"
        (quote (Ty.to_string bad)) (String.concat ", then " path)
  | Bare_result ->
      Printf.sprintf
        "%s is %s, and it fills %s, written bare; a borrow is never returned or aborted, so \
         that position needs `^` or `&` to take this type"
        (quote (Ty.to_string bad)) what (String.concat ", then " path)
  | Value_slot ->
      Printf.sprintf
        "%s is %s, and it reaches %s, a value type's slot; a value type holds only values, \
         all the way down"
        (quote (Ty.to_string bad)) what (String.concat ", then " path)

(* Report a wrong-kind type: at the argument written explicitly that
   brought the rejected type in, or at [span]. *)
let report_kinds env span (t : Ty.t) (args : (Ty.arg * Span.t) list) =
  match wrong_kind env t with
  | None -> ()
  | Some ({ bad; _ } as found) ->
      let rec mentions (x : Ty.t) =
        Ty.equal (Ty.strip_mode x) (Ty.strip_mode bad)
        ||
        match x with
        | Ty.Named (_, a) | Ty.Intrinsic { args = a; _ } ->
            List.exists (function Ty.Type x -> mentions x | Ty.Number _ -> false) a
        | Ty.Reference x | Ty.Roaming x -> mentions x
        | _ -> false
      in
      let at =
        match List.find_opt (function Ty.Type x, _ -> mentions x | _ -> false) args with
        | Some (_, s) -> s
        | None -> span
      in
      error env at (describe_wrong_kind found)

(* Kinds are known only once every type is defined, so a type met before
   then is checked afterwards. *)
let check_kinds env span (t : Ty.t) (args : (Ty.arg * Span.t) list) =
  match Types.deferred env.types with
  | Some deferred -> Queue.push (t, args, span) deferred.kinds
  | None -> report_kinds env span t args

(* ---------------------------------------------------------------------- *)
(* Resolution                                                             *)
(* ---------------------------------------------------------------------- *)

(* What a type name refers to before any arguments are applied. *)
type head =
  | Declared of decl
  | Intrinsic_type of Intrinsics.type_info
  | Concept_type of string
  (* A parameter, or what a parameter stands for inside an instance. *)
  | Bound of Ty.arg
  | Unknown

let concept_names = [ "Int"; "Float"; "String"; "Array"; "Map"; "Block" ]

let resolve_head env scope (name : N.Name_type.t) : head =
  let span = name.N.Name_type.span in
  match name.N.Name_type.node with
  | N.Name_type.Ident id -> (
      let text = id.N.Name.text in
      match List.assoc_opt text scope.params with
      | Some arg -> Bound arg
      | None -> (
          match lookup_types env scope.file text with
          | d :: _ -> Declared d
          | [] ->
              let hint = missing_import_hint env scope.file text ~members:(package_types env) in
              error env span (Printf.sprintf "no type named %s is in scope%s" (quote text) hint);
              Unknown))
  | N.Name_type.Qualified { package = q; ident } -> (
      match qualified env scope.file q.N.Name.text ident.N.Name.text ~members:(package_types env) with
      | Error message ->
          error env q.N.Name.span message;
          Unknown
      | Ok (pkg, found, reachable) -> (
          match (found, reachable) with
          | _, d :: _ -> Declared d
          | _ :: _, [] ->
              error env span
                (Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text)
                   (quote pkg));
              Unknown
          | [], _ ->
              error env span
                (Printf.sprintf "the package %s has no type %s" (quote pkg)
                   (quote ident.N.Name.text));
              Unknown))
  | N.Name_type.Intrinsic { package = ns; ident } -> (
      let ns = ns.N.Name.text and text = ident.N.Name.text in
      if ns = "concepts" && List.mem text concept_names then Concept_type text
      else
        match Intrinsics.find_type ns text with
        | Some t -> Intrinsic_type t
        | None ->
            error env span (Printf.sprintf "no intrinsic type %s" (quote ("@" ^ ns ^ "$" ^ text)));
            Unknown)

(* An integer literal's value. A `'` only separates groups of digits. *)
let integer_value text =
  int_of_string_opt (String.concat "" (String.split_on_char '\'' text))

let parse_number env span text =
  match integer_value text with
  | Some n -> Ty.Known n
  | None ->
      error env span (Printf.sprintf "%s is not a number this compiler can represent" (quote text));
      Ty.Known 0

(* `^T` over a type parameter filled with a value type is an ordinary value
   (memory.md §2.1). In an instance [T] already stands for its argument, so
   the `^` written over it marks nothing and the type is the plain value;
   every other `^` is a roaming owner, checked as one. *)
let roaming env scope span (inner : N.Type_expr.t) (t : Ty.t) : Ty.t =
  let over_param =
    match inner.N.Type_expr.node with
    | N.Type_expr.Path { name = { N.Name_type.node = N.Name_type.Ident id; _ }; generics = [] } ->
        List.mem_assoc id.N.Name.text scope.params
    | _ -> false
  in
  if over_param && is_value env t then t
  else begin
    let marked = Ty.Roaming t in
    check_marker env span marked;
    marked
  end

(* [param] is set on a value parameter's own type, the one place a marked
   introduction may stand inside type arguments: as its `@concepts$Array`'s
   element (generics.md §8.4). *)
let rec resolve ?(param = false) env scope (te : N.Type_expr.t) : Ty.t =
  let span = te.N.Type_expr.span in
  match te.N.Type_expr.node with
  | N.Type_expr.Reference inner ->
      let t = Ty.Reference (resolve env scope inner) in
      check_marker env span t;
      t
  | N.Type_expr.Roaming inner -> roaming env scope span inner (resolve env scope inner)
  | N.Type_expr.Verb v -> Ty.Verb (verb_type env scope v)
  | N.Type_expr.Path { name; generics } -> apply ~param env scope span (resolve_head env scope name) name generics

and generic_arg ?(element = false) env scope (a : N.Generic_arg.t) : Ty.arg =
  let span = a.N.Generic_arg.span in
  match a.N.Generic_arg.node with
  | N.Generic_arg.Type t ->
      let t = resolve env scope t in
      (* A type argument is what a type holds, and a type's members are
         never roaming owners (syntax.md §2.3). *)
      if Ty.is_roaming t then
        error env span
          (Printf.sprintf
             "%s is a roaming owner, and `^` is written only on a local, a parameter or a \
              return type, never inside another type's arguments"
             (quote (Ty.to_string t)));
      Ty.Type t
  | N.Generic_arg.Number text -> Ty.Number (parse_number env span text)
  | N.Generic_arg.NumberRef n -> (
      match List.assoc_opt n.N.Name.text scope.params with
      | Some (Ty.Number num) -> Ty.Number num
      | Some (Ty.Type _) ->
          error env span (Printf.sprintf "%s is a type parameter, not a number" (quote n.N.Name.text));
          Ty.Number (Ty.Known 0)
      | None ->
          error env span
            (Printf.sprintf "no number parameter named %s is in scope" (quote n.N.Name.text));
          Ty.Number (Ty.Known 0))
  | N.Generic_arg.Inferred p -> (
      let name = p.N.Param.name.N.Name.text in
      if not scope.signature then begin
        error env span
          (Printf.sprintf
             "%s introduces a parameter, which only a verb signature may do; a \
              type lists its parameters in its `< >` header"
             (quote name));
        Ty.Type Ty.Error
      end
      else
        match List.assoc_opt name scope.params with
        | Some arg -> arg
        | None -> Ty.Type Ty.Error)
  | N.Generic_arg.Moded t ->
      if element then Ty.Type (param_type env scope t)
      else begin
        error env span
          "a marked introduction is written only on a parameter's own type, or as the element \
           of a parameter's `@concepts$Array`, where it is the mode each element is passed in";
        Ty.Type (Ty.strip_mode (param_type env scope t))
      end

(* Arguments against the parameters they fill: one each, of the right kind
   (generics.md §4.2). *)
and apply_args env scope span what (kinds : Ty.kind list) generics =
  let args = List.map (generic_arg env scope) generics in
  if List.length args <> List.length kinds then begin
    error env span
      (Printf.sprintf "%s takes %d type argument%s, and %d %s written" what
         (List.length kinds)
         (if List.length kinds = 1 then "" else "s")
         (List.length args)
         (if List.length args = 1 then "was" else "were"));
    None
  end
  else begin
    let ok = ref true in
    List.iter2
      (fun kind (arg, (g : N.Generic_arg.t)) ->
        match (kind, arg) with
        | Ty.Type_kind, Ty.Number _ ->
            ok := false;
            error env g.N.Generic_arg.span (Printf.sprintf "%s expects a type here, not a number" what)
        | Ty.Number_kind, Ty.Type t when t <> Ty.Error ->
            ok := false;
            error env g.N.Generic_arg.span (Printf.sprintf "%s expects a number here, not a type" what)
        | _ -> ())
      kinds
      (List.combine args generics);
    if !ok then Some args else None
  end

and apply ?(param = false) env scope span head (name : N.Name_type.t) generics : Ty.t =
  match head with
  | Unknown -> Ty.Error
  | Bound (Ty.Type t) ->
      if generics <> [] then
        error env span "a type parameter takes no type arguments";
      t
  | Bound (Ty.Number _) ->
      error env span "a number parameter is not a type";
      Ty.Error
  | Intrinsic_type info -> (
      match apply_args env scope span (quote ("@" ^ info.namespace ^ "$" ^ info.name)) info.params generics with
      | Some args ->
          let t = Ty.Intrinsic { namespace = info.namespace; name = info.name; args } in
          check_kinds env span t (arg_spans args generics);
          t
      | None -> Ty.Error)
  | Concept_type c -> concept ~param env scope span c generics
  | Declared d -> (
      match Types.type_info env.types d.id with
      | Some info -> (
          let kinds = List.map (fun (p : Ty.param) -> p.kind) info.params in
          match apply_args env scope span (quote info.tid.name) kinds generics with
          | Some args ->
              let t = Ty.Named (info.tid, args) in
              check_kinds env span t (arg_spans args generics);
              t
          | None -> Ty.Error)
      | None -> (
          match Types.alias_info env.types d.id with
          | Some alias -> (
              let kinds = List.map (fun (p : Ty.param) -> p.kind) alias.alias_params in
              match apply_args env scope span (quote (decl_name d)) kinds generics with
              | Some args ->
                  let t = Ty.instantiate alias.alias_params args (alias_target env alias) in
                  check_kinds env span t (arg_spans args generics);
                  t
              | None -> Ty.Error)
          | None ->
              ignore name;
              Ty.Error))

and arg_spans args (generics : N.Generic_arg.t list) =
  List.combine args (List.map (fun (g : N.Generic_arg.t) -> g.N.Generic_arg.span) generics)

and concept ~param env scope span c generics : Ty.t =
  let args () = List.map (generic_arg env scope) generics in
  let expect n =
    if List.length generics <> n then begin
      error env span
        (Printf.sprintf "%s takes %d argument%s" (quote ("@concepts$" ^ c)) n
           (if n = 1 then "" else "s"));
      false
    end
    else true
  in
  match c with
  | "Int" -> if expect 0 then Ty.Concept Ty.Integer_lit else Ty.Error
  | "Float" -> if expect 0 then Ty.Concept Ty.Decimal_lit else Ty.Error
  | "String" -> if expect 0 then Ty.Concept Ty.Text_lit else Ty.Error
  | "Block" -> (
      match args () with
      | [] -> Ty.Concept Ty.Block
      | _ ->
          error env span
            "`@concepts$Block` takes no type argument: a block yields nothing \
             (control-flow.md §2.4)";
          Ty.Error)
  | "Array" -> (
      let args =
        List.mapi (fun i g -> generic_arg ~element:(param && i = 0) env scope g) generics
      in
      match args with
      | [ Ty.Type t; Ty.Number n ] -> Ty.Concept (Ty.Array_lit (t, n))
      | _ ->
          error env span "`@concepts$Array` takes a type and a number";
          Ty.Error)
  | "Map" -> (
      match args () with
      | [ Ty.Type k; Ty.Type v ] -> Ty.Concept (Ty.Map_lit (k, v))
      | _ ->
          error env span "`@concepts$Map` takes two types";
          Ty.Error)
  | _ -> Ty.Error

and verb_type env scope (v : N.Verb_type.t) : Ty.verb =
  match v.N.Verb_type.node with
  | N.Verb_type.Func { params; ret_type } ->
      let ret, abort = ret_type_of env scope ret_type in
      { Ty.this_ = None; params = List.map (param_type env scope) params; ret; abort; is_mut = false }
  | N.Verb_type.Meth { this_type; params; ret_type; is_mut } ->
      let ret, abort = ret_type_of env scope ret_type in
      {
        Ty.this_ = Some (resolve env scope this_type);
        params = List.map (param_type env scope) params;
        ret;
        abort;
        is_mut;
      }

and ret_type_of env scope (r : N.Ret_type.t) =
  match r.N.Ret_type.node with
  | N.Ret_type.Safe t -> (resolve env scope t, None)
  | N.Ret_type.Abort { ok; abort } -> (resolve env scope ok, Some (resolve env scope abort))

and param_type env scope (p : N.Param_type.t) : Ty.t =
  match p.N.Param_type.node with
  | N.Param_type.Concrete t -> resolve ~param:true env scope t
  | N.Param_type.Concept { N.Concept.node = N.Concept.Type; _ } -> Ty.Concept Ty.Type_value
  (* Only a type's header entry is written this way, and the grammar builds
     one nowhere else. *)
  | N.Param_type.Concept { N.Concept.node = N.Concept.Named _; _ } -> Ty.Error
  | N.Param_type.InferredType { name; marker; _ } -> (
      if not scope.signature then begin
        error env p.N.Param_type.span
          (Printf.sprintf
             "%s introduces a parameter, and only a named verb may: a generic \
              function value is not specified (generics.md §9)"
             (quote name.N.Name.text));
        Ty.Error
      end
      else
        match List.assoc_opt name.N.Name.text scope.params with
        | Some (Ty.Type t) -> (
            match marker with
            | N.Marker.Bare -> t
            | N.Marker.Roaming -> Ty.Roaming t
            | N.Marker.Reference -> Ty.Reference t)
        | _ -> Ty.Error)

(* An alias is expanded where it is written (D5), so it has no identity of
   its own; resolving one that leads back to itself would never end. *)
and alias_target env (alias : alias_info) =
  match alias.target with
  | Some t -> t
  | None ->
      if alias.resolving then begin
        error env alias.alias_decl.span
          (Printf.sprintf "the alias %s is defined in terms of itself"
             (quote (decl_name alias.alias_decl)));
        alias.target <- Some Ty.Error;
        Ty.Error
      end
      else begin
        alias.resolving <- true;
        let t =
          match alias.alias_decl.kind with
          | Type_decl { value = { N.Type_or_moulded.node = N.Type_or_moulded.Raw te; _ }; _ } ->
              let params =
                List.map (fun (p : Ty.param) -> (p.name, param_arg p)) alias.alias_params
              in
              resolve env (scope ~params alias.alias_decl.file) te
          | _ -> Ty.Error
        in
        alias.resolving <- false;
        match alias.target with
        | None ->
            alias.target <- Some t;
            t
        | Some t -> t
      end

and param_arg (p : Ty.param) =
  match p.kind with
  | Ty.Type_kind -> Ty.Type (Ty.Param p)
  | Ty.Number_kind -> Ty.Number (Ty.Number_param p)

(* ---------------------------------------------------------------------- *)
(* Pass 3                                                                 *)
(* ---------------------------------------------------------------------- *)

let header_params env (params : N.Generic_param.t list) =
  let seen = Hashtbl.create 4 in
  List.filter_map
    (fun (g : N.Generic_param.t) ->
      let name = g.N.Generic_param.name.N.Name.text in
      if Hashtbl.mem seen name then begin
        error env g.N.Generic_param.span
          (Printf.sprintf "the parameter %s is declared twice" (quote name));
        None
      end
      else begin
        Hashtbl.add seen name ();
        let kind =
          match g.N.Generic_param.type_.N.Concept.node with
          | N.Concept.Type -> Ty.Type_kind
          | N.Concept.Named n ->
              if not (is_integer_concept n) then
                error env g.N.Generic_param.type_.N.Concept.span
                  (Printf.sprintf
                     "a type's `< >` header holds `Type` and `@concepts$Int` \
                      parameters, and %s is neither (generics.md §3.3)"
                     (quote (name_type_text n)));
              Ty.Number_kind
        in
        Some (Env.fresh_param env ~name ~kind)
      end)
    params

let register env (tables : types) =
  List.iter
    (fun pkg_name ->
      let pkg = package env pkg_name in
      List.iter
        (fun (d : decl) ->
          match d.kind with
          | Type_decl { name; params; value; alias } -> (
              let params = header_params env params in
              let is_mould =
                match value.N.Type_or_moulded.node with
                | N.Type_or_moulded.Moulded _ -> true
                | N.Type_or_moulded.Raw _ -> false
              in
              match (alias, is_mould) with
              | true, false ->
                  Hashtbl.replace tables.alias_infos d.id
                    { alias_decl = d; alias_params = params; target = None; resolving = false }
              | _ ->
                  let info =
                    {
                      tid = { Ty.package = pkg_name; name = name.N.Name.text };
                      decl = d;
                      params;
                      definition = None;
                      reference = None;
                    }
                  in
                  Hashtbl.replace tables.type_infos d.id info;
                  (* A type declared twice is reported where it is collected;
                     its id keeps naming the first declaration, the one name
                     lookup finds. *)
                  if not (Hashtbl.mem tables.type_infos_by_id info.tid) then
                    Hashtbl.replace tables.type_infos_by_id info.tid info)
          | _ -> ())
        pkg.decls)
    (Names.package_order env.names)

let members env what (entries : N.Body_field.t list) resolve_field =
  let seen = Hashtbl.create 8 in
  List.filter_map
    (fun (f : N.Body_field.t) ->
      let name = f.N.Body_field.name.N.Name.text in
      match Hashtbl.find_opt seen name with
      | Some (first : Span.t) ->
          error env f.N.Body_field.name.N.Name.span
            (Printf.sprintf "the %s %s is already declared at %s" what (quote name) (where first));
          None
      | None ->
          Hashtbl.add seen name f.N.Body_field.span;
          Some (name, resolve_field f))
    entries

let define env (info : type_info) =
  match info.decl.kind with
  | Type_decl { value; _ } ->
      let params = List.map (fun (p : Ty.param) -> (p.name, param_arg p)) info.params in
      let sc = scope ~params info.decl.file in
      let field (f : N.Body_field.t) =
        let t = resolve env sc f.N.Body_field.type_ in
        check_storage env f.N.Body_field.type_.N.Type_expr.span "a field" t;
        t
      in
      let definition, reference =
        match value.N.Type_or_moulded.node with
        | N.Type_or_moulded.Raw te ->
            let t = resolve env sc te in
            check_storage env te.N.Type_expr.span "the definition of a type" t;
            (Distinct t, None)
        | N.Type_or_moulded.Moulded { N.Moulded.mould; axis; _ } ->
            let reference = axis.N.Type_axis.node = N.Type_axis.Reference in
            let definition =
              match mould.N.Mould.node with
              | N.Mould.Struct fields -> Struct (members env "field" fields field)
              | N.Mould.Variant cases -> Variant (members env "case" cases field)
              | N.Mould.Enum names ->
                  let seen = Hashtbl.create 8 in
                  Enum
                    (List.filter_map
                       (fun (n : N.Name.t) ->
                         if Hashtbl.mem seen n.N.Name.text then begin
                           error env n.N.Name.span
                             (Printf.sprintf "the member %s is listed twice" (quote n.N.Name.text));
                           None
                         end
                         else begin
                           Hashtbl.add seen n.N.Name.text ();
                           Some n.N.Name.text
                         end)
                       names)
            in
            (definition, Some reference)
      in
      info.definition <- Some definition;
      info.reference <- reference
  | _ -> ()

(* A distinct type whose definition leads back to itself without passing
   through a mould has no layout at all: `type A = B` and `type B = A`. *)
(* Declarations in source order, so what a whole-table check reports does not
   depend on how a hash table happens to iterate. *)
let infos_in_order env () =
  Types.fold_type_infos (fun _ info acc -> info :: acc) env.types []
  |> List.sort (fun (a : type_info) b -> compare a.decl.id b.decl.id)

let check_distinct_cycles env () =
  List.iter
    (fun (info : type_info) ->
      let rec follow seen (t : Ty.t) =
        match t with
        | Ty.Named (tid, _) -> (
            if List.mem tid seen then true
            else
              match type_info_of_id env tid with
              | Some { definition = Some (Distinct rhs); _ } -> follow (tid :: seen) rhs
              | _ -> false)
        | _ -> false
      in
      match info.definition with
      | Some (Distinct rhs) when follow [ info.tid ] rhs ->
          error env info.decl.span
            (Printf.sprintf "the type %s is defined in terms of itself" (quote info.tid.name));
          info.definition <- Some (Distinct Ty.Error)
      | _ -> ())
    (infos_in_order env ())

(* generics.md §2.4, the growing-argument rule: where a type leads back to
   itself through its members, each argument it passes back is one of its own
   parameters as written or names none of them. `Grow<T>` holding
   `Grow<Array<T, 2>>` would have a distinct instance at every depth, which no
   layout, and no walk over its members, could finish.

   The graph's nodes are the generic types' parameters. Each occurrence of
   `B<args>` in a member of `A` -- inside `&`, `^` and the element types of
   the intrinsic generics too -- gives an edge from each parameter of `A` an
   argument names to the parameter of `B` it is passed as: plain when the
   argument is that parameter itself, growing otherwise. A path from one of
   `A`'s parameters to another of them is a way `A` leads back to itself, and
   the argument it passes back grows when the path takes a growing edge. So a
   growing edge breaks the rule when some declaration has a parameter that
   reaches the edge and a parameter the edge reaches. That is wider than a
   cycle through the edge: `A<T, U>` holding `A<Array<U, 2>, U>` passes back a
   larger argument, though its instances are finite. The member that holds
   the edge is reported, and its type replaced by [Ty.Error], so that nothing
   after this pass walks it. *)
type growth = {
  g_from : int;
  g_to : int;
  g_growing : bool;
  g_owner : type_info;
  g_member : string;
  g_arg : Ty.arg;
  g_target : type_info;
  g_param : Ty.param;
}

let member_span (info : type_info) name =
  match info.decl.kind with
  | Type_decl { value; _ } -> (
      match value.N.Type_or_moulded.node with
      | N.Type_or_moulded.Raw te -> te.N.Type_expr.span
      | N.Type_or_moulded.Moulded { N.Moulded.mould; _ } -> (
          match mould.N.Mould.node with
          | N.Mould.Struct fields | N.Mould.Variant fields -> (
              match List.find_opt (fun (f : N.Body_field.t) -> f.N.Body_field.name.N.Name.text = name) fields with
              | Some f -> f.N.Body_field.type_.N.Type_expr.span
              | None -> info.decl.span)
          | N.Mould.Enum _ -> info.decl.span))
  | _ -> info.decl.span

let check_growing_arguments env () =
  let infos = infos_in_order env () in
  let members (info : type_info) =
    match info.definition with
    | Some (Struct fs) -> List.map (fun (n, t) -> ("field", n, t)) fs
    | Some (Variant fs) -> List.map (fun (n, t) -> ("case", n, t)) fs
    | Some (Distinct t) -> [ ("definition", "", t) ]
    | _ -> []
  in
  let edges = ref [] in
  (* The edges one argument adds: from each parameter it names to the
     parameter of [target] it is passed for. *)
  let add_argument_edges owner member (target : type_info) (param : Ty.param) arg =
    let named =
      match arg with
      | Ty.Type t -> Ty.free_params t
      | Ty.Number (Ty.Number_param p) -> [ p ]
      | Ty.Number (Ty.Known _) -> []
    in
    let bare =
      match arg with Ty.Type (Ty.Param _) | Ty.Number (Ty.Number_param _) -> true | _ -> false
    in
    List.iter
      (fun (from : Ty.param) ->
        edges :=
          {
            g_from = from.id;
            g_to = param.id;
            g_growing = not bare;
            g_owner = owner;
            g_member = member;
            g_arg = arg;
            g_target = target;
            g_param = param;
          }
          :: !edges)
      named
  in
  let rec occurrences owner member (t : Ty.t) =
    match t with
    | Ty.Named (tid, args) ->
        (match type_info_of_id env tid with
        | Some target when List.compare_lengths target.params args = 0 ->
            List.iter2 (add_argument_edges owner member target) target.params args
        | _ -> ());
        List.iter (occurrences_arg owner member) args
    | Ty.Intrinsic { args; _ } -> List.iter (occurrences_arg owner member) args
    | Ty.Reference t | Ty.Roaming t -> occurrences owner member t
    | _ -> ()
  and occurrences_arg owner member = function
    | Ty.Type t -> occurrences owner member t
    | Ty.Number _ -> ()
  in
  List.iter
    (fun (owner : type_info) ->
      List.iter (fun (_, member, t) -> occurrences owner member t) (members owner))
    infos;
  let edges = List.rev !edges in
  if List.exists (fun e -> e.g_growing) edges then begin
    let forward = Hashtbl.create 16 and backward = Hashtbl.create 16 in
    List.iter
      (fun e ->
        Hashtbl.add forward e.g_from e.g_to;
        Hashtbl.add backward e.g_to e.g_from)
      edges;
    let reach graph (params : Ty.param list) =
      let seen = Hashtbl.create 16 in
      let rec visit id =
        if not (Hashtbl.mem seen id) then begin
          Hashtbl.add seen id ();
          List.iter visit (Hashtbl.find_all graph id)
        end
      in
      List.iter (fun (p : Ty.param) -> visit p.id) params;
      seen
    in
    let reaches = Hashtbl.create 16 in
    let sets (info : type_info) =
      match Hashtbl.find_opt reaches info.decl.id with
      | Some r -> r
      | None ->
          (* What reaches the declaration's parameters, and what they reach. *)
          let r = (reach backward info.params, reach forward info.params) in
          Hashtbl.add reaches info.decl.id r;
          r
    in
    (* The declaration that leads back to itself through the edge: the one
       that holds it, when it does. *)
    let leads_back e =
      let through (info : type_info) =
        let reaching, reached = sets info in
        Hashtbl.mem reached e.g_from && Hashtbl.mem reaching e.g_to
      in
      List.find_opt through (e.g_owner :: List.filter (fun i -> i != e.g_owner) infos)
    in
    (* The growing edge [e], reported once at the member it comes from. *)
    let report_growing e (looping : type_info) =
      let kind, _, _ = List.find (fun (_, n, _) -> n = e.g_member) (members e.g_owner) in
      let which =
        match kind with "definition" -> "definition" | _ -> kind ^ " " ^ quote e.g_member
      in
      let holder =
        if looping == e.g_owner then "its " ^ which
        else Printf.sprintf "the %s of %s" which (quote e.g_owner.tid.name)
      in
      error env
        (member_span e.g_owner e.g_member)
        (Printf.sprintf
           "%s holds itself at a growing argument: %s passes %s as %s of %s; where a type leads \
            back to itself, each argument it passes back is one of its own parameters as written \
            or names none of them"
           (quote looping.tid.name) holder
           (quote (Ty.arg_to_string e.g_arg))
           (quote e.g_param.name) (quote e.g_target.tid.name))
    in
    (* A reported member's type becomes [Ty.Error], so that nothing after
       this pass walks it. *)
    let blank_member (id, member) () =
      match List.find_opt (fun (i : type_info) -> i.decl.id = id) infos with
      | Some info ->
          let blank fs = List.map (fun (n, t) -> (n, if n = member then Ty.Error else t)) fs in
          info.definition <-
            (match info.definition with
            | Some (Struct fs) -> Some (Struct (blank fs))
            | Some (Variant fs) -> Some (Variant (blank fs))
            | Some (Distinct _) -> Some (Distinct Ty.Error)
            | d -> d)
      | None -> ()
    in
    let reported = Hashtbl.create 4 in
    List.iter
      (fun e ->
        let key = (e.g_owner.decl.id, e.g_member) in
        if e.g_growing && not (Hashtbl.mem reported key) then
          match leads_back e with
          | None -> ()
          | Some looping ->
              Hashtbl.add reported key ();
              report_growing e looping)
      edges;
    Hashtbl.iter blank_member reported
  end

(* A value type is transitively a value: no reference-type or `&` member,
   anywhere downstream (memory.md §2.10). Every member's own type obeys the
   same rule where it is declared, so checking one level is checking all of
   them. *)
let check_value_downstream env () =
  List.iter
    (fun (info : type_info) ->
      (match info.definition with
      | Some (Struct fs) | Some (Variant fs) ->
          List.iter (fun (_, t) -> check_function_types env info.decl.span t) fs
      | Some (Distinct t) -> check_function_types env info.decl.span t
      | _ -> ());
      if info.reference = Some false then
        let members =
          match info.definition with
          | Some (Struct fs) | Some (Variant fs) -> fs
          | _ -> []
        in
        List.iter
          (fun (name, (t : Ty.t)) ->
            match t with
            | Ty.Reference _ ->
                error env info.decl.span
                  (Printf.sprintf
                     "%s is a value type, so its member %s cannot be an `&`; only a \
                      `#` mould may hold one"
                     (quote info.tid.name) (quote name))
            | Ty.Param _ | Ty.Error -> ()
            | _ ->
                if is_reference env t then
                  error env info.decl.span
                    (Printf.sprintf
                       "%s is a value type, so its member %s cannot hold %s, a \
                        reference type; a value type is a value all the way down"
                       (quote info.tid.name) (quote name) (quote (Ty.to_string t))))
          members)
    (infos_in_order env ())

(* Fills [tables] and hands on a view of them. The checks that need every
   type's kind wait until every type is defined, and the view handed on
   holds none back. *)
let run env (tables : types) =
  let deferred = { marks = Queue.create (); kinds = Queue.create () } in
  let env = { env with types = Types.defining tables deferred } in
  register env tables;
  List.iter (define env) (infos_in_order env ());
  let aliases = Types.fold_alias_infos (fun _ a acc -> a :: acc) env.types [] in
  List.iter (fun a -> ignore (alias_target env a)) (List.sort (fun a b -> compare a.alias_decl.id b.alias_decl.id) aliases);
  check_distinct_cycles env ();
  check_growing_arguments env ();
  let env = { env with types = Types.view tables } in
  Queue.iter (fun (t, span) -> check_marker env span t) deferred.marks;
  Queue.iter (fun (t, args, span) -> report_kinds env span t args) deferred.kinds;
  check_value_downstream env ();
  env.types
