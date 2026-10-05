(* Pass 5's driver (docs/design/semantics.md §3): the walk in [Check] run over
   every verb body, field-constructor default, constant and enum-map entry of
   the build, and every generic instance a call asked for, into the program's
   declarations. *)

open Env
module N = Sst.Nodes
module T = Nodes
module S = Signature

open Context
open Instances
open Overloads
open Termination
open Check

let verb_body (d : decl) =
  match d.kind with
  | Verb v -> (
      match v.N.Verb_decl.node with
      | N.Verb_decl.Func { body; _ }
      | N.Verb_decl.Meth { body; _ }
      | N.Verb_decl.Op { body; _ }
      | N.Verb_decl.Flip { body; _ }
      | N.Verb_decl.Constructor { body; _ } -> Some body
      | N.Verb_decl.Subscript _ -> None)
  | _ -> None

let check_body (d : decl) (s : S.t) subst =
  let ctx, locals = verb_context d s subst in
  match verb_body d with
  | None -> None
  | Some body ->
      let typed = block_in ctx body in
      if not (ends ~resolve:false typed.T.Block.stats) then
        error body.N.Block.span
          (Printf.sprintf
             "not every path through %s returns; a block-bodied verb returns explicitly \
              on every path, `Unit` included (functions.md §3.5)"
             (quote s.name));
      Some (locals, typed)

(* A field constructor's defaults are values of their entries' types, and a
   default is a declaration, not a coercion site. Each is typed with the
   constructor's parameters as [subst] gives them, and given with its entry's
   slot; an instance's are typed again, and only a declaration's [report]
   whether a default fits its entry. *)
let typed_defaults ?(report = true) (d : decl) (s : S.t) subst =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Constructor { params = { N.Constructor_params.node = N.Constructor_params.Fields fs; _ }; _ }; _ } ->
      let ctx, _ = verb_context d s subst in
      let ctx = { ctx with scopes = [ Hashtbl.create 1 ]; building = None; ret_target = No_return } in
      List.concat
        (List.mapi
           (fun slot ((f : N.Constructor_field.t), (p : S.param)) ->
             match f.N.Constructor_field.default with
             | Some default ->
                 let v = expr ctx default in
                 let dst = Ty.subst subst p.ty in
                 if report && not (Ty.assignable ~dst ~src:v.T.Expr.ty) then
                   error v.T.Expr.span
                     (Printf.sprintf "the default of %s is %s, and the entry is %s"
                        (quote p.name) (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst)));
                 [ (slot, v) ]
             | None -> [])
           (List.combine fs s.params))
  | _ -> []


let check_defaults (d : decl) (s : S.t) =
  match typed_defaults d s [] with
  | [] -> ()
  | values -> if s.S.generics = [] then defaults := { T.Defaults.decl = d.id; args = []; values } :: !defaults

let package_context (d : decl) =
  {
    file = d.file;
    package = d.package;
    is_root = (package d.package).is_root;
    params = [];
    scopes = [ Hashtbl.create 1 ];
    ret_target = No_return;
    resolve_target = No_resolve;
    this_type = None;
    is_mut = false;
    building = None;
  }

(* An enum-map entry is a coercion site (adt.md §6): exact, or converted by
   the one implicit constructor that applies. *)
let coerce_to ctx (v : T.Expr.t) dst =
  if Ty.assignable ~dst ~src:v.T.Expr.ty then v
  else
    match implicit_constructors ~src:v.T.Expr.ty ~dst with
    | [ ((s, subst) as found) ] ->
        request s subst v.T.Expr.span;
        coerce_value v found
    | [] ->
        error v.T.Expr.span
          (Printf.sprintf "this entry is %s, and the map holds %s, with no implicit constructor between them"
             (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst)));
        v
    | several ->
        ignore ctx;
        error v.T.Expr.span
          (Printf.sprintf "more than one implicit constructor converts %s to %s: %s"
             (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst))
             (String.concat ", " (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)));
        v

let type_definition (info : type_info) : T.Decl.definition =
  match info.definition with
  | Some (Struct fs) -> T.Decl.Struct fs
  | Some (Variant cs) -> T.Decl.Variant cs
  | Some (Enum ms) -> T.Decl.Enum ms
  | Some (Distinct t) -> T.Decl.Distinct t
  | None -> T.Decl.Distinct Ty.Error

let declaration (d : decl) : T.Decl.t option =
  let node : T.Decl.node option =
    match d.kind with
    | Type_decl { name; _ } -> (
        match Hashtbl.find_opt type_infos d.id with
        | Some info ->
            Some
              (T.Decl.Type
                 {
                   name = name.N.Name.text;
                   params = info.params;
                   reference = Type_decls.is_reference (Ty.Named (info.tid, List.map Type_decls.param_arg info.params));
                   definition = type_definition info;
                 })
        | None -> (
            match Hashtbl.find_opt alias_infos d.id with
            | Some a ->
                Some (T.Decl.Alias { name = name.N.Name.text; params = a.alias_params; target = Type_decls.alias_target a })
            | None -> None))
    | Constant { name; value; _ } ->
        let ty = Option.value ~default:Ty.Error (Hashtbl.find_opt constant_types d.id) in
        let v = expr (package_context d) value in
        if not (Ty.assignable ~dst:ty ~src:v.T.Expr.ty) then
          error v.T.Expr.span
            (Printf.sprintf
               "%s is declared %s, and its value is %s; a declaration is not a coercion \
                site, so a conversion is written out"
               (quote name.N.Name.text) (quote (Ty.to_string ty)) (quote (Ty.to_string v.T.Expr.ty)));
        Some (T.Decl.Constant { name = name.N.Name.text; ty; value = v })
    | Enum_map { enum; property; entries; _ } ->
        let ty = Option.value ~default:Ty.Error (Hashtbl.find_opt constant_types d.id) in
        let ctx = package_context d in
        let entries =
          List.map (fun ((m : N.Name.t), value) -> (m.N.Name.text, coerce_to ctx (expr ctx value) ty)) entries
        in
        Some
          (T.Decl.Enum_map
             { enum = Type_decls.resolve (Type_decls.scope d.file) enum; property = property.N.Name.text; ty; entries })
    | Verb _ -> (
        match Hashtbl.find_opt signatures d.id with
        | None -> None
        | Some s -> (
            check_defaults d s;
            match s.kind with
            | S.Subscript ->
                if s.generics = [] then begin
                  let ty = subscript_result d s [] d.span in
                  let key = subscript_key d.id [] s in
                  let params, value =
                    match Hashtbl.find_opt subscript_instances key with
                    | Some (_, _, ps, v) -> (ps, Some v)
                    | None -> ([], None)
                  in
                  Some (T.Decl.Subscript { signature = { s with ret = ty }; params; value })
                end
                else Some (T.Decl.Subscript { signature = s; params = []; value = None })
            | _ ->
                if s.generics <> [] then Some (T.Decl.Verb { signature = s; body = T.Decl.Per_instance })
                else
                  match check_body d s [] with
                  | Some (params, body) -> Some (T.Decl.Verb { signature = s; body = T.Decl.Checked { params; body } })
                  | None -> None))
  in
  Option.map (fun node -> { T.Decl.id = d.id; span = d.span; node }) node

let run () : T.Program.t =
  let packages =
    List.map
      (fun name ->
        let pkg = package name in
        { T.Package.name; decls = List.filter_map declaration pkg.decls })
      !package_order
  in
  while not (Queue.is_empty pending) do
    let p = Queue.pop pending in
    note := Some (describe_instance p.p_sig p.p_subst p.p_at);
    (match p.p_sig.kind with
    | S.Subscript -> ()
    | _ -> (
        (match typed_defaults ~report:false p.p_decl p.p_sig p.p_subst with
        | [] -> ()
        | values ->
            defaults :=
              { T.Defaults.decl = p.p_decl.id; args = binding_args p.p_sig p.p_subst; values }
              :: !defaults);
        match check_body p.p_decl p.p_sig p.p_subst with
        | Some (params, body) ->
            instances :=
              {
                T.Instance.decl = p.p_decl.id;
                signature = p.p_sig;
                args = binding_args p.p_sig p.p_subst;
                params;
                body;
              }
              :: !instances
        | None -> ()));
    note := None
  done;
  (* D12 checks a generic body once per instantiation, so one nothing
     instantiates would go unchecked. It is checked once more where it is
     declared, with every type parameter standing for [Ty.Error]: what depends
     on the parameter is accepted as it is for any expression that failed to
     type, and what does not -- a name that resolves nowhere, a call no
     overload takes -- is reported. A number parameter stays the parameter it
     is. Nothing from this check enters the tree; there is no instance to
     hold it. *)
  let instantiated_subscripts = Hashtbl.create 16 in
  Hashtbl.iter
    (fun _ ((t : S.t), _, _, _) ->
      match t.S.owner with S.Declared id -> Hashtbl.replace instantiated_subscripts id () | _ -> ())
    subscript_instances;
  let instantiated (d : decl) (s : S.t) =
    match s.S.kind with
    | S.Subscript -> Hashtbl.mem instantiated_subscripts d.id
    | _ -> Hashtbl.mem instance_counts d.id
  in
  defining := true;
  Fun.protect
    ~finally:(fun () -> defining := false)
    (fun () ->
      List.iter
        (fun name ->
          List.iter
            (fun (d : decl) ->
              match Hashtbl.find_opt signatures d.id with
              | Some s when s.S.generics <> [] && not (instantiated d s) ->
                  let subst =
                    List.filter_map
                      (fun (p : Ty.param) ->
                        match p.Ty.kind with
                        | Ty.Type_kind -> Some (p.Ty.id, Ty.Type Ty.Error)
                        | Ty.Number_kind -> None)
                      s.S.generics
                  in
                  note := Some (Printf.sprintf "in %s, which nothing instantiates" (quote s.S.name));
                  (match s.S.kind with
                  | S.Subscript -> ignore (subscript_body d s subst)
                  | _ -> ignore (check_body d s subst));
                  note := None
              | _ -> ())
            (package name).decls)
        !package_order);
  (* Generic subscripts were instantiated as their call sites were typed. *)
  let subscript_bodies =
    Hashtbl.fold
      (fun _ (s, subst, params, (v : T.Expr.t)) acc ->
        match s.S.owner with
        | S.Declared id when s.S.generics <> [] ->
            {
              T.Instance.decl = id;
              signature = { s with ret = v.T.Expr.ty };
              args = binding_args s subst;
              params;
              body = { T.Block.stats = [ { T.Stat.node = T.Stat.Return v; span = v.T.Expr.span } ]; span = v.T.Expr.span };
            }
            :: acc
        | _ -> acc)
      subscript_instances []
  in
  let key (i : T.Instance.t) =
    (i.decl, String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) i.args))
  in
  let all = List.rev !instances @ subscript_bodies in
  {
    T.Program.packages;
    instances = List.sort (fun a b -> compare (key a) (key b)) all;
    defaults = List.rev !defaults;
  }
