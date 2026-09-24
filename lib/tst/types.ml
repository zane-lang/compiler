(* Resolving type expressions, and pass 3 (docs/semantics.md §3): every `type`
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

(* `@concepts$Integer`, the concept a number parameter is declared with
   (generics.md §3.3). An intrinsic namespace is spelled the same in every
   file, so this needs no scope. *)
let is_integer_concept (n : N.Name_type.t) = name_type_text n = "@concepts$Integer"

let is_integer_concept_type (te : N.Type_expr.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Path { name; generics = [] } -> is_integer_concept name
  | _ -> false

(* Once pass 3 has run, whether a type is a reference type can be asked of
   any type; before it has, the answer may depend on a definition not yet
   resolved, so the checks that need it wait. *)
let ready = ref false
let deferred_guests : (Ty.t * Span.t) list ref = ref []

(* ---------------------------------------------------------------------- *)
(* Kind                                                                   *)
(* ---------------------------------------------------------------------- *)

let rec is_reference ?(seen = []) (t : Ty.t) =
  match t with
  | Ty.Named (tid, args) -> (
      match Hashtbl.find_opt type_infos_by_id tid with
      | None -> false
      | Some info -> (
          match info.reference with
          | Some r -> r
          | None -> (
              match info.definition with
              | Some (Distinct rhs) when not (List.mem tid seen) ->
                  let s = List.combine (List.map (fun (p : Ty.param) -> p.id) info.params) args in
                  is_reference ~seen:(tid :: seen) (Ty.subst s rhs)
              | _ -> false)))
  | Ty.Intrinsic { namespace; name; _ } -> (
      match Intrinsics.find_type namespace name with
      | Some t -> t.reference
      | None -> false)
  | Ty.Guest _ -> true
  | _ -> false

let type_info_of_id tid = Hashtbl.find_opt type_infos_by_id tid

(* A concept type is never storage (syntax.md §2.8): not a field, not a
   local, not an element of a stored type. *)
let rec mentions_concept (t : Ty.t) =
  match t with
  | Ty.Concept _ -> true
  | Ty.Named (_, args) | Ty.Intrinsic { args; _ } ->
      List.exists (function Ty.Type t -> mentions_concept t | Ty.Number _ -> false) args
  | Ty.Guest t -> mentions_concept t
  | _ -> false

let check_storage span what (t : Ty.t) =
  if mentions_concept t then
    error span
      (Printf.sprintf
         "%s is a concept type, which may type a parameter but is never storage, \
          so it cannot be %s"
         (quote (Ty.to_string t)) what)

let check_guest span (inner : Ty.t) =
  if !ready then begin
    match inner with
    | Ty.Param _ | Ty.Error -> ()
    | _ ->
        if not (is_reference inner) then
          error span
            (Printf.sprintf
               "%s is a value type, and `&` marks only a reference type (a `#` \
                mould or a reference primitive)"
               (quote (Ty.to_string inner)))
  end
  else deferred_guests := (inner, span) :: !deferred_guests

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

let concept_names = [ "Integer"; "Decimal"; "Text"; "Array"; "Map"; "Block" ]

let resolve_head scope (name : N.Name_type.t) : head =
  let span = name.N.Name_type.span in
  match name.N.Name_type.node with
  | N.Name_type.Ident id -> (
      let text = id.N.Name.text in
      match List.assoc_opt text scope.params with
      | Some arg -> Bound arg
      | None -> (
          match lookup_types scope.file text with
          | d :: _ -> Declared d
          | [] ->
              let hint = missing_import_hint scope.file text ~members:package_types in
              error span (Printf.sprintf "no type named %s is in scope%s" (quote text) hint);
              Unknown))
  | N.Name_type.Qualified { package = q; ident } -> (
      match qualified scope.file q.N.Name.text ident.N.Name.text ~members:package_types with
      | Error message ->
          error q.N.Name.span message;
          Unknown
      | Ok (pkg, found, reachable) -> (
          match (found, reachable) with
          | _, d :: _ -> Declared d
          | _ :: _, [] ->
              error span
                (Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text)
                   (quote pkg));
              Unknown
          | [], _ ->
              error span
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
            error span (Printf.sprintf "no intrinsic type %s" (quote ("@" ^ ns ^ "$" ^ text)));
            Unknown)

(* An integer literal's value. A `'` only separates groups of digits. *)
let integer_value text =
  int_of_string_opt (String.concat "" (String.split_on_char '\'' text))

let parse_number span text =
  match integer_value text with
  | Some n -> Ty.Known n
  | None ->
      error span (Printf.sprintf "%s is not a number this compiler can represent" (quote text));
      Ty.Known 0

let rec resolve scope (te : N.Type_expr.t) : Ty.t =
  let span = te.N.Type_expr.span in
  match te.N.Type_expr.node with
  | N.Type_expr.Guest inner ->
      let t = resolve scope inner in
      check_guest span t;
      Ty.Guest t
  | N.Type_expr.Verb v -> Ty.Verb (verb_type scope v)
  | N.Type_expr.Path { name; generics } -> apply scope span (resolve_head scope name) name generics

and generic_arg scope (a : N.Generic_arg.t) : Ty.arg =
  let span = a.N.Generic_arg.span in
  match a.N.Generic_arg.node with
  | N.Generic_arg.Type t -> Ty.Type (resolve scope t)
  | N.Generic_arg.Number text -> Ty.Number (parse_number span text)
  | N.Generic_arg.NumberRef n -> (
      match List.assoc_opt n.N.Name.text scope.params with
      | Some (Ty.Number num) -> Ty.Number num
      | Some (Ty.Type _) ->
          error span (Printf.sprintf "%s is a type parameter, not a number" (quote n.N.Name.text));
          Ty.Number (Ty.Known 0)
      | None ->
          error span
            (Printf.sprintf "no number parameter named %s is in scope" (quote n.N.Name.text));
          Ty.Number (Ty.Known 0))
  | N.Generic_arg.Inferred p -> (
      let name = p.N.Param.name.N.Name.text in
      if not scope.signature then begin
        error span
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

(* Arguments against the parameters they fill: one each, of the right kind
   (generics.md §4.2). *)
and apply_args scope span what (kinds : Ty.kind list) generics =
  let args = List.map (generic_arg scope) generics in
  if List.length args <> List.length kinds then begin
    error span
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
            error g.N.Generic_arg.span (Printf.sprintf "%s expects a type here, not a number" what)
        | Ty.Number_kind, Ty.Type t when t <> Ty.Error ->
            ok := false;
            error g.N.Generic_arg.span (Printf.sprintf "%s expects a number here, not a type" what)
        | _ -> ())
      kinds
      (List.combine args generics);
    if !ok then Some args else None
  end

and apply scope span head (name : N.Name_type.t) generics : Ty.t =
  match head with
  | Unknown -> Ty.Error
  | Bound (Ty.Type t) ->
      if generics <> [] then
        error span "a type parameter takes no type arguments";
      t
  | Bound (Ty.Number _) ->
      error span "a number parameter is not a type";
      Ty.Error
  | Intrinsic_type info -> (
      match apply_args scope span (quote ("@" ^ info.namespace ^ "$" ^ info.name)) info.params generics with
      | Some args -> Ty.Intrinsic { namespace = info.namespace; name = info.name; args }
      | None -> Ty.Error)
  | Concept_type c -> concept scope span c generics
  | Declared d -> (
      match Hashtbl.find_opt type_infos d.id with
      | Some info -> (
          let kinds = List.map (fun (p : Ty.param) -> p.kind) info.params in
          match apply_args scope span (quote info.tid.name) kinds generics with
          | Some args -> Ty.Named (info.tid, args)
          | None -> Ty.Error)
      | None -> (
          match Hashtbl.find_opt alias_infos d.id with
          | Some alias -> (
              let kinds = List.map (fun (p : Ty.param) -> p.kind) alias.alias_params in
              match apply_args scope span (quote (decl_name d)) kinds generics with
              | Some args ->
                  let target = alias_target alias in
                  let s = List.combine (List.map (fun (p : Ty.param) -> p.id) alias.alias_params) args in
                  Ty.subst s target
              | None -> Ty.Error)
          | None ->
              ignore name;
              Ty.Error))

and concept scope span c generics : Ty.t =
  let args () = List.map (generic_arg scope) generics in
  let expect n =
    if List.length generics <> n then begin
      error span
        (Printf.sprintf "%s takes %d argument%s" (quote ("@concepts$" ^ c)) n
           (if n = 1 then "" else "s"));
      false
    end
    else true
  in
  match c with
  | "Integer" -> if expect 0 then Ty.Concept Ty.Integer_lit else Ty.Error
  | "Decimal" -> if expect 0 then Ty.Concept Ty.Decimal_lit else Ty.Error
  | "Text" -> if expect 0 then Ty.Concept Ty.Text_lit else Ty.Error
  | "Block" -> (
      match args () with
      | [] -> Ty.Concept (Ty.Block None)
      | [ Ty.Type t ] -> Ty.Concept (Ty.Block (Some t))
      | _ ->
          error span "`@concepts$Block` takes at most one type argument";
          Ty.Error)
  | "Array" -> (
      match args () with
      | [ Ty.Type t; Ty.Number n ] -> Ty.Concept (Ty.Array_lit (t, n))
      | _ ->
          error span "`@concepts$Array` takes a type and a number";
          Ty.Error)
  | "Map" -> (
      match args () with
      | [ Ty.Type k; Ty.Type v ] -> Ty.Concept (Ty.Map_lit (k, v))
      | _ ->
          error span "`@concepts$Map` takes two types";
          Ty.Error)
  | _ -> Ty.Error

and verb_type scope (v : N.Verb_type.t) : Ty.verb =
  match v.N.Verb_type.node with
  | N.Verb_type.Func { params; ret_type } ->
      let ret, abort = ret_type_of scope ret_type in
      { Ty.this_ = None; params = List.map (param_type scope) params; ret; abort; is_mut = false }
  | N.Verb_type.Meth { this_type; params; ret_type; is_mut } ->
      let ret, abort = ret_type_of scope ret_type in
      {
        Ty.this_ = Some (resolve scope this_type);
        params = List.map (param_type scope) params;
        ret;
        abort;
        is_mut;
      }

and ret_type_of scope (r : N.Ret_type.t) =
  match r.N.Ret_type.node with
  | N.Ret_type.Safe t -> (resolve scope t, None)
  | N.Ret_type.Abort { ok; abort } -> (resolve scope ok, Some (resolve scope abort))

and param_type scope (p : N.Param_type.t) : Ty.t =
  match p.N.Param_type.node with
  | N.Param_type.Concrete t -> resolve scope t
  | N.Param_type.Concept { N.Concept.node = N.Concept.Type; _ } -> Ty.Concept Ty.Type_value
  (* Only a type's header entry is written this way, and the grammar builds
     one nowhere else. *)
  | N.Param_type.Concept { N.Concept.node = N.Concept.Named _; _ } -> Ty.Error
  | N.Param_type.InferredType { name; _ } -> (
      if not scope.signature then begin
        error p.N.Param_type.span
          (Printf.sprintf
             "%s introduces a parameter, and only a named verb may: a generic \
              function value is not specified (generics.md §9)"
             (quote name.N.Name.text));
        Ty.Error
      end
      else
        match List.assoc_opt name.N.Name.text scope.params with
        | Some (Ty.Type t) -> t
        | _ -> Ty.Error)

(* An alias is expanded where it is written (D5), so it has no identity of
   its own; resolving one that leads back to itself would never end. *)
and alias_target (alias : alias_info) =
  match alias.target with
  | Some t -> t
  | None ->
      if alias.resolving then begin
        error alias.alias_decl.span
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
              resolve (scope ~params alias.alias_decl.file) te
          | _ -> Ty.Error
        in
        alias.resolving <- false;
        (match alias.target with None -> alias.target <- Some t | Some _ -> ());
        Option.get alias.target
      end

and param_arg (p : Ty.param) =
  match p.kind with
  | Ty.Type_kind -> Ty.Type (Ty.Param p)
  | Ty.Number_kind -> Ty.Number (Ty.Number_param p)

(* ---------------------------------------------------------------------- *)
(* Pass 3                                                                 *)
(* ---------------------------------------------------------------------- *)

let header_params (params : N.Generic_param.t list) =
  let seen = Hashtbl.create 4 in
  List.filter_map
    (fun (g : N.Generic_param.t) ->
      let name = g.N.Generic_param.name.N.Name.text in
      if Hashtbl.mem seen name then begin
        error g.N.Generic_param.span
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
                error g.N.Generic_param.type_.N.Concept.span
                  (Printf.sprintf
                     "a type's `< >` header holds `Type` and `@concepts$Integer` \
                      parameters, and %s is neither (generics.md §3.3)"
                     (quote (name_type_text n)));
              Ty.Number_kind
        in
        Some (Ty.fresh_param ~name ~kind)
      end)
    params

let register () =
  List.iter
    (fun pkg_name ->
      let pkg = package pkg_name in
      List.iter
        (fun (d : decl) ->
          match d.kind with
          | Type_decl { name; params; value; alias } -> (
              let params = header_params params in
              let is_mould =
                match value.N.Type_or_moulded.node with
                | N.Type_or_moulded.Moulded _ -> true
                | N.Type_or_moulded.Raw _ -> false
              in
              match (alias, is_mould) with
              | true, false ->
                  Hashtbl.replace alias_infos d.id
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
                  Hashtbl.replace type_infos d.id info;
                  Hashtbl.replace type_infos_by_id info.tid info)
          | _ -> ())
        pkg.decls)
    !package_order

let members what (entries : N.Body_field.t list) resolve_field =
  let seen = Hashtbl.create 8 in
  List.filter_map
    (fun (f : N.Body_field.t) ->
      let name = f.N.Body_field.name.N.Name.text in
      match Hashtbl.find_opt seen name with
      | Some (first : Span.t) ->
          error f.N.Body_field.name.N.Name.span
            (Printf.sprintf "the %s %s is already declared at %s" what (quote name) (where first));
          None
      | None ->
          Hashtbl.add seen name f.N.Body_field.span;
          Some (name, resolve_field f))
    entries

let define (info : type_info) =
  match info.decl.kind with
  | Type_decl { value; _ } ->
      let params = List.map (fun (p : Ty.param) -> (p.name, param_arg p)) info.params in
      let sc = scope ~params info.decl.file in
      let field (f : N.Body_field.t) =
        let t = resolve sc f.N.Body_field.type_ in
        check_storage f.N.Body_field.type_.N.Type_expr.span "a field" t;
        t
      in
      let definition, reference =
        match value.N.Type_or_moulded.node with
        | N.Type_or_moulded.Raw te ->
            let t = resolve sc te in
            check_storage te.N.Type_expr.span "the definition of a type" t;
            (Distinct t, None)
        | N.Type_or_moulded.Moulded { N.Moulded.mould; axis; _ } ->
            let reference = axis.N.Type_axis.node = N.Type_axis.Reference in
            let definition =
              match mould.N.Mould.node with
              | N.Mould.Struct fields -> Struct (members "field" fields field)
              | N.Mould.Variant cases -> Variant (members "case" cases field)
              | N.Mould.Enum names ->
                  let seen = Hashtbl.create 8 in
                  Enum
                    (List.filter_map
                       (fun (n : N.Name.t) ->
                         if Hashtbl.mem seen n.N.Name.text then begin
                           error n.N.Name.span
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
let infos_in_order () =
  Hashtbl.fold (fun _ info acc -> info :: acc) type_infos []
  |> List.sort (fun (a : type_info) b -> compare a.decl.id b.decl.id)

let check_distinct_cycles () =
  List.iter
    (fun (info : type_info) ->
      let rec follow seen (t : Ty.t) =
        match t with
        | Ty.Named (tid, _) -> (
            if List.mem tid seen then true
            else
              match type_info_of_id tid with
              | Some { definition = Some (Distinct rhs); _ } -> follow (tid :: seen) rhs
              | _ -> false)
        | _ -> false
      in
      match info.definition with
      | Some (Distinct rhs) when follow [ info.tid ] rhs ->
          error info.decl.span
            (Printf.sprintf "the type %s is defined in terms of itself" (quote info.tid.name));
          info.definition <- Some (Distinct Ty.Error)
      | _ -> ())
    (infos_in_order ())

(* A value type is transitively a value: no reference-type or `&` member,
   anywhere downstream (memory.md §2.10). Every member's own type obeys the
   same rule where it is declared, so checking one level is checking all of
   them. *)
let check_value_downstream () =
  List.iter
    (fun (info : type_info) ->
      if info.reference = Some false then
        let members =
          match info.definition with
          | Some (Struct fs) | Some (Variant fs) -> fs
          | _ -> []
        in
        List.iter
          (fun (name, (t : Ty.t)) ->
            match t with
            | Ty.Guest _ ->
                error info.decl.span
                  (Printf.sprintf
                     "%s is a value type, so its member %s cannot be an `&`; only a \
                      `#` mould may hold one"
                     (quote info.tid.name) (quote name))
            | Ty.Param _ | Ty.Error -> ()
            | _ ->
                if is_reference t then
                  error info.decl.span
                    (Printf.sprintf
                       "%s is a value type, so its member %s cannot hold %s, a \
                        reference type; a value type is a value all the way down"
                       (quote info.tid.name) (quote name) (quote (Ty.to_string t))))
          members)
    (infos_in_order ())

let run () =
  ready := false;
  deferred_guests := [];
  register ();
  List.iter define (infos_in_order ());
  let aliases = Hashtbl.fold (fun _ a acc -> a :: acc) alias_infos [] in
  List.iter (fun a -> ignore (alias_target a)) (List.sort (fun a b -> compare a.alias_decl.id b.alias_decl.id) aliases);
  check_distinct_cycles ();
  ready := true;
  List.iter (fun (t, span) -> check_guest span t) (List.rev !deferred_guests);
  deferred_guests := [];
  check_value_downstream ()
