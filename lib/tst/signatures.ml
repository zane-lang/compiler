(* Pass 4 (docs/semantics.md §3): every verb's parameter and return types,
   and the checks that need only signatures -- overload identity, the operator
   and implicit-constructor home-package rules, enum-map exhaustiveness.

   A verb has no `< >` header. It introduces each type or number parameter at
   the parameter's first *marked* occurrence -- `x T Type`, `Array<T Type, n
   @concepts$Integer>`, or an explicit `T Type` or `n @concepts$Integer` value
   parameter -- and every other occurrence of the name, before or after,
   refers to it (generics.md §3.2).
   So the introductions are found first, over the whole signature, and only
   then is any type in it resolved. *)

open Env
module N = Sst.Nodes
module S = Signature

(* ---------------------------------------------------------------------- *)
(* Introductions                                                          *)
(* ---------------------------------------------------------------------- *)

type introductions = {
  mutable found : (string * Ty.param) list;
  (* The explicit ones, by the value parameter that introduces them. *)
  mutable explicit : (string * Ty.param) list;
  (* Every name the signature writes where a number goes, as in the `n` of
     `Array<T, n>`. *)
  numbers : string list;
}

let introduce intro span name kind =
  match List.assoc_opt name intro.found with
  | Some p ->
      if p.Ty.kind <> kind then
        error span
          (Printf.sprintf "%s is introduced as both a type and a number" (quote name));
      p
  | None ->
      let p = Ty.fresh_param ~name ~kind in
      intro.found <- intro.found @ [ (name, p) ];
      p

(* The names a type writes where a number goes. *)
let rec number_refs (te : N.Type_expr.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Guest inner -> number_refs inner
  | N.Type_expr.Verb v -> (
      match v.N.Verb_type.node with
      | N.Verb_type.Func { params; ret_type } ->
          List.concat_map param_type_number_refs params @ ret_number_refs ret_type
      | N.Verb_type.Meth { this_type; params; ret_type; _ } ->
          number_refs this_type
          @ List.concat_map param_type_number_refs params
          @ ret_number_refs ret_type)
  | N.Type_expr.Path { generics; _ } ->
      List.concat_map
        (fun (g : N.Generic_arg.t) ->
          match g.N.Generic_arg.node with
          | N.Generic_arg.Type t -> number_refs t
          | N.Generic_arg.NumberRef n -> [ n.N.Name.text ]
          | N.Generic_arg.Inferred p -> param_type_number_refs p.N.Param.type_
          | N.Generic_arg.Number _ -> [])
        generics

and param_type_number_refs (pt : N.Param_type.t) =
  match pt.N.Param_type.node with N.Param_type.Concrete t -> number_refs t | _ -> []

and ret_number_refs (r : N.Ret_type.t) =
  match r.N.Ret_type.node with
  | N.Ret_type.Safe t -> number_refs t
  | N.Ret_type.Abort { ok; abort } -> number_refs ok @ number_refs abort

let rec scan_type intro (te : N.Type_expr.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Guest inner -> scan_type intro inner
  | N.Type_expr.Verb v -> (
      match v.N.Verb_type.node with
      | N.Verb_type.Func { params; ret_type } ->
          List.iter (scan_param_type intro) params;
          scan_ret intro ret_type
      | N.Verb_type.Meth { this_type; params; ret_type; _ } ->
          scan_type intro this_type;
          List.iter (scan_param_type intro) params;
          scan_ret intro ret_type)
  | N.Type_expr.Path { generics; _ } ->
      List.iter
        (fun (g : N.Generic_arg.t) ->
          match g.N.Generic_arg.node with
          | N.Generic_arg.Type t -> scan_type intro t
          | N.Generic_arg.Inferred p -> (
              let name = p.N.Param.name.N.Name.text in
              match p.N.Param.type_.N.Param_type.node with
              | N.Param_type.Concept { N.Concept.node = N.Concept.Type; _ } ->
                  ignore (introduce intro g.N.Generic_arg.span name Ty.Type_kind)
              | N.Param_type.Concrete t when Types.is_integer_concept_type t ->
                  ignore (introduce intro g.N.Generic_arg.span name Ty.Number_kind)
              | _ ->
                  error g.N.Generic_arg.span
                    (Printf.sprintf
                       "%s introduces a parameter, which takes `Type` or \
                        `@concepts$Integer` (generics.md §3.3)"
                       (quote name)))
          | _ -> ())
        generics

and scan_ret intro (r : N.Ret_type.t) =
  match r.N.Ret_type.node with
  | N.Ret_type.Safe t -> scan_type intro t
  | N.Ret_type.Abort { ok; abort } ->
      scan_type intro ok;
      scan_type intro abort

and scan_param_type intro (pt : N.Param_type.t) =
  match pt.N.Param_type.node with
  | N.Param_type.Concrete t -> scan_type intro t
  | N.Param_type.Concept _ -> ()
  | N.Param_type.InferredType { name; _ } ->
      ignore (introduce intro pt.N.Param_type.span name.N.Name.text Ty.Type_kind)

(* A `T Type` value parameter always introduces a type parameter. An
   `@concepts$Integer` one is a compile-time integer either way, since that is
   a leaf concept type (syntax.md §2.8); it introduces a number parameter
   when the signature writes its name where a number goes, as
   `Array<T, n>(T Type, n @concepts$Integer)` does, and is otherwise an
   ordinary parameter that accepts an integer literal
   (docs/semantics.md §9). *)
let scan_param intro (p : N.Param.t) =
  let name = p.N.Param.name.N.Name.text in
  let explicit kind =
    let param = introduce intro p.N.Param.span name kind in
    intro.explicit <- intro.explicit @ [ (name, param) ]
  in
  match p.N.Param.type_.N.Param_type.node with
  | N.Param_type.Concept { N.Concept.node = N.Concept.Type; _ } -> explicit Ty.Type_kind
  | N.Param_type.Concrete t when Types.is_integer_concept_type t && List.mem name intro.numbers ->
      explicit Ty.Number_kind
  | _ -> scan_param_type intro p.N.Param.type_

(* ---------------------------------------------------------------------- *)
(* Building a signature                                                   *)
(* ---------------------------------------------------------------------- *)

let signature_scope (d : decl) intro =
  Types.scope ~signature:true
    ~params:(List.map (fun (n, p) -> (n, Types.param_arg p)) intro.found)
    d.file

let param sc intro (p : N.Param.t) : S.param =
  let name = p.N.Param.name.N.Name.text in
  match List.assoc_opt name intro.explicit with
  | Some binds ->
      let ty =
        match binds.Ty.kind with
        | Ty.Type_kind -> Ty.Concept Ty.Type_value
        | Ty.Number_kind -> Ty.Concept Ty.Integer_lit
      in
      { S.name; ty; binds = Some binds; has_default = false }
  | None -> { S.name; ty = Types.param_type sc p.N.Param.type_; binds = None; has_default = false }

let ret sc (r : N.Ret_type.t) = Types.ret_type_of sc r

let check_params_unique (params : N.Param.t list) =
  let seen = Hashtbl.create 4 in
  List.iter
    (fun (p : N.Param.t) ->
      let name = p.N.Param.name.N.Name.text in
      if Hashtbl.mem seen name then
        error p.N.Param.name.N.Name.span
          (Printf.sprintf "the parameter %s is declared twice" (quote name))
      else Hashtbl.add seen name ())
    params

let type_key (t : Ty.t) =
  match t with
  | Ty.Named (tid, _) -> Some (Declared_type tid)
  | Ty.Intrinsic { namespace; name; _ } -> Some (Intrinsic_type (namespace, name))
  | _ -> None

(* The type a constructor builds, as its overload set is keyed: the defining
   package and the name, and not the arguments, which mention each
   declaration's own parameter names. *)
let type_head (t : Ty.t) =
  match t with
  | Ty.Named (tid, _) -> tid.Ty.package ^ "$" ^ tid.Ty.name
  | Ty.Intrinsic { namespace; name; _ } -> "@" ^ namespace ^ "$" ^ name
  | t -> Ty.to_string t

let type_name (t : Ty.t) =
  match t with
  | Ty.Named (tid, _) -> tid.Ty.name
  | t -> Ty.to_string t

(* The home of a type, for the rules that ask for one: the package that
   declared it, or the namespace that supplies it (functions.md §6.1). A
   parameter has none, since it stands for types from anywhere. *)
let rec home (t : Ty.t) : S.home option =
  match t with
  | Ty.Named (tid, _) -> Some (S.Package tid.Ty.package)
  | Ty.Intrinsic { namespace; _ } -> Some (S.Namespace namespace)
  | Ty.Concept _ -> Some (S.Namespace "concepts")
  | Ty.Guest t -> home t
  | _ -> None

let signature_number_refs (v : N.Verb_decl.t) =
  let params ps = List.concat_map (fun (p : N.Param.t) -> param_type_number_refs p.N.Param.type_) ps in
  match v.N.Verb_decl.node with
  | N.Verb_decl.Func { params = ps; ret_type; _ }
  | N.Verb_decl.Op { params = ps; ret_type; _ }
  | N.Verb_decl.Flip { params = ps; ret_type; _ } ->
      params ps @ ret_number_refs ret_type
  | N.Verb_decl.Meth { this_type; params = ps; ret_type; _ } ->
      number_refs this_type @ params ps @ ret_number_refs ret_type
  | N.Verb_decl.Subscript { this_type; params = ps; _ } -> number_refs this_type @ params ps
  | N.Verb_decl.Constructor { type_; params = cps; _ } -> (
      number_refs type_
      @
      match cps.N.Constructor_params.node with
      | N.Constructor_params.Positional ps -> params ps
      | N.Constructor_params.Fields fs ->
          List.concat_map
            (fun (f : N.Constructor_field.t) -> param_type_number_refs f.N.Constructor_field.type_)
            fs)

let build (d : decl) (v : N.Verb_decl.t) : S.t option =
  let intro = { found = []; explicit = []; numbers = signature_number_refs v } in
  let make ?(is_mut = false) ?(abort = None) ~kind ~name params ret_ty =
    Some
      {
        S.owner = S.Declared d.id;
        name;
        home = S.Package d.package;
        kind;
        generics = List.map snd intro.found;
        params;
        ret = ret_ty;
        abort;
        is_mut;
      }
  in
  match v.N.Verb_decl.node with
  | N.Verb_decl.Func { name; params; ret_type; _ } ->
      List.iter (scan_param intro) params;
      scan_ret intro ret_type;
      check_params_unique params;
      let sc = signature_scope d intro in
      let r, abort = ret sc ret_type in
      make ~abort ~kind:S.Function ~name:name.N.Name.text (List.map (param sc intro) params) r
  | N.Verb_decl.Meth { name; this_type; params; ret_type; is_mut; _ } ->
      scan_type intro this_type;
      List.iter (scan_param intro) params;
      scan_ret intro ret_type;
      check_params_unique params;
      let sc = signature_scope d intro in
      let this_ = { S.name = "this"; ty = Types.resolve sc this_type; binds = None; has_default = false } in
      let r, abort = ret sc ret_type in
      make ~is_mut ~abort ~kind:S.Method ~name:name.N.Name.text
        (this_ :: List.map (param sc intro) params)
        r
  | N.Verb_decl.Op { op; params; ret_type; _ } ->
      List.iter (scan_param intro) params;
      scan_ret intro ret_type;
      check_params_unique params;
      let token = Intrinsics.operator_token op.N.Operator.node in
      if List.length params <> 2 then begin
        error d.span
          (Printf.sprintf "the operator %s takes two operands, and %d are declared"
             (quote token) (List.length params));
        None
      end
      else
        let sc = signature_scope d intro in
        let r, abort = ret sc ret_type in
        make ~abort ~kind:S.Operator ~name:token (List.map (param sc intro) params) r
  | N.Verb_decl.Flip { params; ret_type; _ } ->
      List.iter (scan_param intro) params;
      scan_ret intro ret_type;
      if List.length params <> 1 then begin
        error d.span
          (Printf.sprintf "the operator `~` takes one operand, and %d are declared"
             (List.length params));
        None
      end
      else
        let sc = signature_scope d intro in
        let r, abort = ret sc ret_type in
        make ~abort ~kind:S.Flip ~name:"~" (List.map (param sc intro) params) r
  | N.Verb_decl.Constructor { type_; member; params; is_implicit; _ } -> (
      let fields = match params.N.Constructor_params.node with N.Constructor_params.Fields _ -> true | _ -> false in
      (match params.N.Constructor_params.node with
      | N.Constructor_params.Positional ps ->
          List.iter (scan_param intro) ps;
          check_params_unique ps
      | N.Constructor_params.Fields fs ->
          List.iter (fun (f : N.Constructor_field.t) -> scan_param_type intro f.N.Constructor_field.type_) fs);
      let sc = signature_scope d intro in
      let built = Types.resolve sc type_ in
      let member = Option.map (fun (m : N.Name.t) -> m.N.Name.text) member in
      let ps =
        match params.N.Constructor_params.node with
        | N.Constructor_params.Positional ps -> List.map (param sc intro) ps
        | N.Constructor_params.Fields fs ->
            List.map
              (fun (f : N.Constructor_field.t) ->
                {
                  S.name = f.N.Constructor_field.name.N.Name.text;
                  ty = Types.param_type sc f.N.Constructor_field.type_;
                  binds = None;
                  has_default = Option.is_some f.N.Constructor_field.default;
                })
              fs
      in
      match built with
      | Ty.Named _ | Ty.Intrinsic _ ->
          let name =
            type_name built ^ match member with Some m -> "." ^ m | None -> ""
          in
          make ~kind:(S.Constructor { implicit = is_implicit; member; fields }) ~name ps built
      | Ty.Error -> None
      | other ->
          error type_.N.Type_expr.span
            (Printf.sprintf "a constructor is named after the type it builds, and %s is not one"
               (quote (Ty.to_string other)));
          None)
  | N.Verb_decl.Subscript { this_type; params; _ } ->
      scan_type intro this_type;
      List.iter (scan_param intro) params;
      check_params_unique params;
      let sc = signature_scope d intro in
      let this_ = { S.name = "this"; ty = Types.resolve sc this_type; binds = None; has_default = false } in
      (* A subscript's result is "inferred from the projected place"
         (functions.md §2.9), which is pass 5's to type; [Check] fills it. *)
      make ~kind:S.Subscript ~name:"[]" (this_ :: List.map (param sc intro) params) Ty.Error

(* ---------------------------------------------------------------------- *)
(* Checks                                                                 *)
(* ---------------------------------------------------------------------- *)

let params_key ~strip (s : S.t) =
  Ty.canonical
    (List.map (fun (p : S.param) -> if strip then Ty.strip_guest p.ty else p.ty) s.params)

(* functions.md §4.1: one overload set, no two members with the same ordered
   parameter types, and none that differ only in a passing mode. *)
let check_overload_set what (sigs : (decl * S.t) list) =
  let rec go seen = function
    | [] -> ()
    | ((d : decl), s) :: rest ->
        (match
           List.find_opt (fun (_, t) -> params_key ~strip:true t = params_key ~strip:true s) seen
         with
        | Some ((first : decl), t) ->
            if params_key ~strip:false t <> params_key ~strip:false s then
              error d.span
                (Printf.sprintf
                   "illegal overload set: this %s differs from the one at %s only by \
                    the passing mode on a parameter; rename one declaration or choose \
                    a single signature"
                   what (where first.span))
            else
              error d.span
                (Printf.sprintf
                   "this %s takes the same parameter types as the one at %s, so no call \
                    could tell them apart; parameter names, `this`, `mut` and the return \
                    type do not distinguish overloads"
                   what (where first.span))
        | None -> ());
        go (seen @ [ (d, s) ]) rest
  in
  go [] sigs

let group_by key items =
  let table = Hashtbl.create 16 in
  let order = ref [] in
  List.iter
    (fun item ->
      let k = key item in
      if not (Hashtbl.mem table k) then order := k :: !order;
      Hashtbl.add table k item)
    items;
  List.rev_map (fun k -> List.rev (Hashtbl.find_all table k)) !order

(* operators.md §2.2: an operator lives in the home package of one of its
   operands, whether it is declared in `core` or anywhere else. *)
let check_operator_home (d : decl) (s : S.t) =
  let homes = List.filter_map (fun (p : S.param) -> home p.ty) s.params in
  if not (List.mem (S.Package d.package) homes) then
    let operands = String.concat " and " (List.map (fun (p : S.param) -> quote (Ty.to_string p.ty)) s.params) in
    error d.span
      (Printf.sprintf
         "the operator %s on %s may be declared only in the home package of an \
          operand type, and %s is not one"
         (quote s.name) operands (quote d.package))

(* types.md §4.1, §4.4, §4.5. *)
let check_implicit (d : decl) (s : S.t) =
  match s.kind with
  | S.Constructor { implicit = true; member; fields } -> (
      if Option.is_some member then
        error d.span
          "a named constructor cannot be `implicit`: an implicit constructor is the \
           anonymous conversion a coercion site inserts, and a name has nothing to \
           insert"
      else if fields then
        error d.span "an implicit constructor takes one positional parameter, not a field list"
      else
        match s.params with
        | [ source ] ->
            let source_ty = source.ty in
            (match source_ty with
            | Ty.Guest _ ->
                error d.span
                  "the source of an implicit constructor cannot be an `&`; it must be a \
                   value type or a concept type"
            | Ty.Concept _ | Ty.Param _ | Ty.Error -> ()
            | t ->
                if Types.is_reference t then
                  error d.span
                    (Printf.sprintf
                       "the source of an implicit constructor must be a value type or a \
                        concept type, and %s is a reference type"
                       (quote (Ty.to_string t))));
            let homes = List.filter_map home [ source_ty; s.ret ] in
            if not (List.mem (S.Package d.package) homes) then
              error d.span
                (Printf.sprintf
                   "an implicit constructor from %s to %s may be declared only in the \
                    home package of one of them, and %s is neither"
                   (quote (Ty.to_string source_ty))
                   (quote (Ty.to_string s.ret))
                   (quote d.package))
        | params ->
            error d.span
              (Printf.sprintf "an implicit constructor takes exactly one parameter, and %d are declared"
                 (List.length params)))
  | _ -> ()

(* A named constructor on a variant would share its spelling with a case,
   and a variant is built by naming a case (adt.md §3.2). *)
let check_constructor_target (d : decl) (s : S.t) =
  match (s.kind, s.ret) with
  | S.Constructor { member = Some m; _ }, Ty.Named (tid, _) -> (
      match Types.type_info_of_id tid with
      | Some { definition = Some (Variant cases); _ } when List.mem_assoc m cases ->
          error d.span
            (Printf.sprintf
               "%s is a case of %s, and a case is built by naming it; it cannot also \
                be a named constructor"
               (quote m) (quote tid.Ty.name))
      | _ -> ())
  | _ -> ()

let enum_map (d : decl) =
  match d.kind with
  | Enum_map { enum; property; type_; entries } -> (
      let sc = Types.scope d.file in
      let enum_ty = Types.resolve sc enum in
      let ty = Types.resolve sc type_ in
      Types.check_storage type_.N.Type_expr.span "the type of an enum map" ty;
      Hashtbl.replace constant_types d.id ty;
      match enum_ty with
      | Ty.Error -> ()
      | Ty.Named (tid, _) -> (
          match Types.type_info_of_id tid with
          | Some { definition = Some (Enum members); _ } ->
              let seen = Hashtbl.create 8 in
              List.iter
                (fun ((m : N.Name.t), _) ->
                  if not (List.mem m.N.Name.text members) then
                    error m.N.Name.span
                      (Printf.sprintf "%s has no member %s" (quote tid.Ty.name) (quote m.N.Name.text))
                  else if Hashtbl.mem seen m.N.Name.text then
                    error m.N.Name.span
                      (Printf.sprintf "the member %s already has an entry" (quote m.N.Name.text))
                  else Hashtbl.add seen m.N.Name.text ())
                entries;
              let missing = List.filter (fun m -> not (Hashtbl.mem seen m)) members in
              if missing <> [] then
                error d.span
                  (Printf.sprintf "an enum map covers every member, and this one has no entry for %s"
                     (String.concat ", " (List.map quote missing)));
              let key = (tid, property.N.Name.text) in
              let existing = Option.value ~default:[] (Hashtbl.find_opt enum_maps key) in
              (match List.find_opt (fun m -> m.map_decl.package = d.package) existing with
              | Some first ->
                  error property.N.Name.span
                    (Printf.sprintf "%s already has a map %s, at %s" (quote tid.Ty.name)
                       (quote property.N.Name.text) (where first.map_decl.span))
              | None -> ());
              Hashtbl.replace enum_maps key
                (existing @ [ { map_decl = d; map_enum = tid; map_ty = ty } ])
          | _ ->
              error enum.N.Type_expr.span
                (Printf.sprintf "an enum map ranges over an enum, and %s is not one"
                   (quote (Ty.to_string enum_ty))))
      | other ->
          error enum.N.Type_expr.span
            (Printf.sprintf "an enum map ranges over an enum, and %s is not one"
               (quote (Ty.to_string other))))
  | _ -> ()

let constant (d : decl) =
  match d.kind with
  | Constant { type_; _ } ->
      let ty = Types.resolve (Types.scope d.file) type_ in
      Types.check_storage type_.N.Type_expr.span "a constant" ty;
      Hashtbl.replace constant_types d.id ty
  | _ -> ()

let run () =
  let built = ref [] in
  List.iter
    (fun pkg_name ->
      let pkg = package pkg_name in
      List.iter
        (fun (d : decl) ->
          match d.kind with
          | Verb v -> (
              match build d v with
              | None -> ()
              | Some s ->
                  Hashtbl.replace signatures d.id s;
                  built := (d, s) :: !built;
                  (match s.kind with
                  | S.Method -> Hashtbl.add methods s.name s
                  | S.Operator -> (
                      match v.N.Verb_decl.node with
                      | N.Verb_decl.Op { op; _ } -> Hashtbl.add operators op.N.Operator.node s
                      | _ -> ())
                  | S.Flip -> flips := !flips @ [ s ]
                  | S.Subscript -> subscripts := !subscripts @ [ s ]
                  | S.Constructor _ -> (
                      match type_key s.ret with
                      | Some key -> Hashtbl.add constructors key s
                      | None -> ())
                  | S.Function -> ()))
          | Constant _ -> constant d
          | Enum_map _ -> enum_map d
          | Type_decl _ -> ())
        pkg.decls)
    !package_order;
  let built = List.rev !built in
  (* Overload identity, per package and per name. *)
  let key ((d : decl), (s : S.t)) =
    let kind =
      match s.kind with
      | S.Function -> "function " ^ s.name
      | S.Method -> "method " ^ s.name
      | S.Operator -> "operator " ^ s.name
      | S.Flip -> "operator ~"
      | S.Subscript -> "subscript"
      | S.Constructor { member; _ } ->
          "constructor " ^ Ty.to_string s.ret ^ Option.fold ~none:"" ~some:(fun m -> "." ^ m) member
    in
    (d.package, kind)
  in
  List.iter
    (fun group ->
      match group with
      | [] | [ _ ] -> ()
      | ((_, (s : S.t)) :: _) as group ->
          let what =
            match s.kind with
            | S.Function -> "function"
            | S.Method -> "method"
            | S.Operator | S.Flip -> "operator"
            | S.Subscript -> "subscript"
            | S.Constructor _ -> "constructor"
          in
          check_overload_set what group)
    (group_by
       (fun ((d, s) as item) ->
         match s.S.kind with
         (* A field constructor and a positional one are called with
            different brackets, so no call could confuse the two: each form
            is its own overload set. *)
         | S.Constructor { member; fields; _ } ->
             ( d.package,
               "constructor " ^ type_head s.S.ret
               ^ Option.fold ~none:"" ~some:(fun m -> "." ^ m) member
               ^ if fields then "{}" else "()" )
         | _ -> key item)
       built);
  List.iter
    (fun ((d : decl), (s : S.t)) ->
      (match s.kind with
      | S.Operator | S.Flip -> check_operator_home d s
      | _ -> ());
      check_implicit d s;
      check_constructor_target d s)
    built;
  (* `main` takes no parameters (packages.md §6.2). *)
  List.iter
    (fun pkg_name ->
      let pkg = package pkg_name in
      if pkg.is_root then
        List.iter
          (fun (d : decl) ->
            match Hashtbl.find_opt signatures d.id with
            | Some ({ kind = S.Function; name = "main"; params = _ :: _; _ }) ->
                error d.span "`main` takes no parameters: the root package reaches the console and runtime through `@program$`"
            | _ -> ())
          (package_values pkg_name "main"))
    !package_order;
  List.iter
    (fun pkg_name -> List.iter Collect.check_import_overloads (package pkg_name).files)
    !package_order
