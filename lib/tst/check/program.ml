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
      (* A foreign verb's body is C (ffi.md §3.1). *)
      | N.Verb_decl.Func { foreign = Some _; _ } | N.Verb_decl.Meth { foreign = Some _; _ } -> None
      | N.Verb_decl.Func { body; _ }
      | N.Verb_decl.Meth { body; _ }
      | N.Verb_decl.Op { body; _ }
      | N.Verb_decl.Flip { body; _ }
      | N.Verb_decl.Constructor { body; _ } -> Some body
      | N.Verb_decl.Subscript _ -> None)
  | _ -> None

let check_body env (d : decl) (s : S.t) subst =
  let ctx, locals = verb_context env d s subst in
  match verb_body d with
  | None -> None
  | Some body ->
      let typed = block_in env ctx body in
      if not (ends ~resolve:false typed.T.Block.stats) then
        error env body.N.Block.span
          (Printf.sprintf
             "not every path through %s returns; a block-bodied verb returns explicitly \
              on every path, `Unit` included (functions.md §3.5)"
             (quote s.name));
      Some (locals, typed)

(* A field constructor's defaults are values of their entries' types, and a
   default is a declaration, not a coercion site. Each default is typed with
   the constructor's parameters as [subst] gives them, and returned with its
   entry's slot; an instance's defaults are typed again, and only a
   declaration's defaults [report] whether a default fits its entry. *)
let typed_defaults env ?(report = true) (d : decl) (s : S.t) subst =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Constructor { params = { N.Constructor_params.node = N.Constructor_params.Fields fs; _ }; _ }; _ } ->
      let ctx, _ = verb_context env d s subst in
      let ctx = { ctx with scopes = [ Hashtbl.create 1 ]; building = None; ret_target = No_return } in
      List.concat
        (List.mapi
           (fun slot ((f : N.Constructor_field.t), (p : S.param)) ->
             match f.N.Constructor_field.default with
             | Some default ->
                 let v = expr env ctx default in
                 let dst = Ty.subst subst p.ty in
                 if report && not (Ty.assignable ~dst ~src:v.T.Expr.ty) then
                   error env v.T.Expr.span
                     (Printf.sprintf "the default of %s is %s, and the entry is %s"
                        (quote p.name) (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst)));
                 [ (slot, v) ]
             | None -> [])
           (List.combine fs s.params))
  | _ -> []


let check_defaults env (d : decl) (s : S.t) =
  match typed_defaults env d s [] with
  | [] -> ()
  | values -> if s.S.generics = [] then env.instances.defaults := { T.Defaults.decl = d.id; args = []; values } :: !(env.instances.defaults)

(* An exported lambda has the rights of root-package code wherever it is
   declared (packages.md §8.4). *)
let package_context env (d : decl) =
  {
    file = d.file;
    package = d.package;
    is_root = (package env d.package).is_root || (match d.kind with Constant { export = Some _; _ } -> true | _ -> false);
    params = [];
    generics = [];
    scopes = [ Hashtbl.create 1 ];
    ret_target = No_return;
    resolve_target = No_resolve;
    is_mut = false;
    building = None;
  }

(* An enum-map entry is a coercion site (adt.md §6): its value matches
   exactly, or is converted by the single implicit constructor that
   applies. *)
let coerce_to env ctx (v : T.Expr.t) dst =
  if Ty.assignable ~dst ~src:v.T.Expr.ty then v
  else
    match implicit_constructors env ~src:v.T.Expr.ty ~dst with
    | [ ((s, subst) as found) ] ->
        request env s subst v.T.Expr.span;
        coerce_value v found
    | [] ->
        error env v.T.Expr.span
          (Printf.sprintf "this entry is %s, and the map holds %s, with no implicit constructor between them"
             (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst)));
        v
    | several ->
        ignore ctx;
        error env v.T.Expr.span
          (Printf.sprintf "more than one implicit constructor converts %s to %s: %s"
             (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string dst))
             (String.concat ", " (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)));
        v

let type_definition env (info : type_info) : T.Decl.definition =
  match info.definition with
  | Some (Handle h) ->
      (* A handle that no foreign verb makes has no kind from a verb: it is a
         data handle when it has a free function, and a capability
         otherwise. *)
      let kind =
        match Verbs.handle_kind env.verbs info.tid with
        | Some k -> k
        | None -> if h.T.Handle.free = None then T.Decl.Capability else T.Decl.Data
      in
      T.Decl.Handle (h, kind)
  | Some (Struct fs) -> T.Decl.Struct fs
  | Some (Variant cs) -> T.Decl.Variant cs
  | Some (Enum ms) -> T.Decl.Enum ms
  | Some (Distinct t) -> T.Decl.Distinct t
  | None -> T.Decl.Distinct Ty.Error

(* A generic subscript is checked per instance; any other subscript is checked
   here. *)
let subscript_declaration env (d : decl) (s : S.t) =
  if s.generics <> [] then T.Decl.Subscript { signature = s; params = []; value = None }
  else
    let ty = subscript_result env d s [] d.span in
    let key = subscript_key d.id [] s in
    let params, value =
      match Hashtbl.find_opt env.instances.subscript_instances key with
      | Some (_, _, ps, v) -> (ps, Some v)
      | None -> ([], None)
    in
    T.Decl.Subscript { signature = { s with ret = ty }; params; value }

let verb_declaration env (d : decl) (s : S.t) =
  let foreign =
    match d.kind with
    | Verb { N.Verb_decl.node = N.Verb_decl.Func { foreign = Some _; _ } | N.Verb_decl.Meth { foreign = Some _; _ }; _ } -> true
    | _ -> false
  in
  (* A foreign verb's body is C. A foreign verb that [Foreign_decls] rejected
     has no body, and is left out, as a verb whose signature did not resolve
     is. *)
  if foreign then Option.map (fun f -> T.Decl.Verb { signature = s; body = T.Decl.Foreign f }) (Verbs.foreign_verb env.verbs d.id)
  else if s.generics <> [] then Some (T.Decl.Verb { signature = s; body = T.Decl.Per_instance })
  else
    match check_body env d s [] with
    | Some (params, body) ->
        Some (T.Decl.Verb { signature = s; body = T.Decl.Checked { params; body } })
    | None -> None

let declaration env (d : decl) : T.Decl.t option =
  let node : T.Decl.node option =
    match d.kind with
    | Type_decl { name; _ } -> (
        match Types.type_info env.types d.id with
        | Some info ->
            Some
              (T.Decl.Type
                 {
                   name = name.N.Name.text;
                   params = info.params;
                   reference = Type_decls.is_reference env (Ty.Named (info.tid, List.map Type_decls.param_arg info.params));
                   definition = type_definition env info;
                 })
        | None -> (
            match Types.alias_info env.types d.id with
            | Some a ->
                Some (T.Decl.Alias { name = name.N.Name.text; params = a.alias_params; target = Type_decls.alias_target env a })
            | None -> None))
    | Constant { name; value; export; _ } ->
        let ty = Option.value ~default:Ty.Error (Verbs.constant_type env.verbs d.id) in
        let ctx = package_context env d in
        let v =
          match value.N.Expr.node with
          | N.Expr.Foreign_global symbol ->
              Foreign_decls.global env ~root:ctx.is_root ~span:value.N.Expr.span ~declared:ty symbol
          | _ -> expr env ctx value
        in
        Option.iter (Exports.check_lambda env ty) export;
        if not (Ty.assignable ~dst:ty ~src:v.T.Expr.ty) then
          error env v.T.Expr.span
            (Printf.sprintf
               "%s is declared %s, and its value is %s; a declaration is not a coercion \
                site, so a conversion is written out"
               (quote name.N.Name.text) (quote (Ty.to_string ty)) (quote (Ty.to_string v.T.Expr.ty)));
        Some (T.Decl.Constant { name = name.N.Name.text; ty; value = v; export = Option.map (fun (s : N.Name.t) -> s.N.Name.text) export })
    | Enum_map { enum; property; entries; _ } ->
        let ty = Option.value ~default:Ty.Error (Verbs.constant_type env.verbs d.id) in
        let ctx = package_context env d in
        let enum = Type_decls.resolve env (Type_decls.scope d.file) enum in
        (match Context.definition env enum with
        | Some (tid, Enum _) ->
            List.iter (fun ((m : N.Name.t), _) -> Uses.add env.uses m.N.Name.span (Uses.Member (tid, m.N.Name.text))) entries
        | _ -> ());
        let entries =
          List.map (fun ((m : N.Name.t), value) -> (m.N.Name.text, coerce_to env ctx (expr env ctx value) ty)) entries
        in
        Some (T.Decl.Enum_map { enum; property = property.N.Name.text; ty; entries })
    | Verb _ -> (
        match Verbs.signature env.verbs d.id with
        | None -> None
        | Some s -> (
            check_defaults env d s;
            match s.kind with
            | S.Subscript -> Some (subscript_declaration env d s)
            | _ -> verb_declaration env d s))
  in
  Option.map (fun node -> { T.Decl.id = d.id; span = d.span; node }) node

(* Fills [instances] while it checks every body, and returns the program. *)

(* One requested instance: its field-constructor defaults and its body,
   typed at its arguments, into the instances the program carries. *)
let check_instance env (p : pending) =
  match p.p_sig.kind with
  | S.Subscript -> ()
  | _ -> (
      (match typed_defaults env ~report:false p.p_decl p.p_sig p.p_subst with
      | [] -> ()
      | values ->
          env.instances.defaults :=
            { T.Defaults.decl = p.p_decl.id; args = binding_args p.p_sig p.p_subst; values }
            :: !(env.instances.defaults));
      match check_body env p.p_decl p.p_sig p.p_subst with
      | Some (params, body) ->
          env.instances.checked :=
            {
              T.Instance.decl = p.p_decl.id;
              signature = p.p_sig;
              args = binding_args p.p_sig p.p_subst;
              params;
              body;
              note = Some (describe_instance p.p_sig p.p_subst p.p_at);
            }
            :: !(env.instances.checked)
      | None -> ())

(* The uses of veiled values the declaration check reported join the other
   diagnostics. An instance's error about the same place in the body is that
   use failing for one type argument, so it is dropped: one mistake, one
   diagnostic (D4). *)
let merge_veiled env =
  let veiled = !(env.veiled_diagnostics) in
  let spans = List.map (fun (d : Diagnostic.t) -> d.location) veiled in
  let same d =
    List.exists (fun (r, body) -> r == d && List.mem (Diagnostic.Location.Span body) spans) !(env.relocated)
  in
  env.diagnostics := veiled @ List.filter (fun d -> not (same d)) !(env.diagnostics);
  env.veiled_diagnostics := []

let run env (instances : instances) : T.Program.t =
  let requests = Env.requests () in
  let env = { env with instances = { instances with requests = Some requests } } in
  let packages =
    List.map
      (fun name ->
        let pkg = package env name in
        { T.Package.name; decls = List.filter_map (declaration env) pkg.decls })
      (Names.package_order env.names)
  in
  (* The latest instance requested is checked first, so a chain is followed
     to its end before the instances beside it: a chain that never ends
     reaches the limit after as many steps as the limit, not after every
     instance its branches would have requested. *)
  while not (Stack.is_empty requests.pending) do
    let p = Stack.pop requests.pending in
    requests.current_chain := p.p_decl.id :: p.p_chain;
    requests.current_path := Some (p.p_origin, p.p_path);
    Fun.protect ~finally:(fun () ->
        requests.current_chain := [];
        requests.current_path := None)
    @@ fun () ->
    at_origin env p.p_origin @@ fun () ->
    with_note env (describe_path p.p_path) (fun () -> check_instance env p)
  done;
  (* D12 checks a generic body once per instantiation. Each generic body is
     also checked once where it is declared, with every type parameter
     standing for [Ty.Veiled]: code that depends on the parameter is
     accepted, as for any expression that failed to type, except a use of a
     veiled value that generics.md §3.8 forbids, which this check reports
     whether or not anything instantiates the body. For a body that nothing
     instantiates, the check also reports code that does not depend on a
     parameter -- an identifier that resolves nowhere, a call no overload
     takes -- so an unused body is not an unchecked one; for an instantiated
     body its instances report those. A number parameter stays a number
     parameter. Nothing from this check enters the tree. The check runs
     without requests, so it requests no instances. *)
  let instantiated_subscripts = Hashtbl.create 16 in
  Hashtbl.iter
    (fun _ ((t : S.t), _, _, _) ->
      match t.S.owner with S.Declared id -> Hashtbl.replace instantiated_subscripts id () | _ -> ())
    env.instances.subscript_instances;
  let instantiated (d : decl) (s : S.t) =
    match s.S.kind with
    | S.Subscript -> Hashtbl.mem instantiated_subscripts d.id
    | _ -> Hashtbl.mem requests.instantiated d.id
  in
  let env = { env with instances = { instances with requests = None } } in
  List.iter
    (fun name ->
      List.iter
        (fun (d : decl) ->
          match Verbs.signature env.verbs d.id with
          | Some s when s.S.generics <> [] ->
              let subst =
                List.filter_map
                  (fun (p : Ty.param) ->
                    match p.Ty.kind with
                    | Ty.Type_kind -> Some (p.Ty.id, Ty.Type (Ty.Veiled p))
                    | Ty.Number_kind -> None)
                  s.S.generics
              in
              let env, note =
                if instantiated d s then
                  ( { env with diagnostics = ref []; uses = Uses.create false },
                    Printf.sprintf "in %s" (quote s.S.name) )
                else (env, Printf.sprintf "in %s, which nothing instantiates" (quote s.S.name))
              in
              with_note env note
                (fun () ->
                  match s.S.kind with
                  | S.Subscript -> ignore (subscript_body env d s subst)
                  | _ -> ignore (check_body env d s subst))
          | _ -> ())
        (package env name).decls)
    (Names.package_order env.names);
  merge_veiled env;
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
              note = None;
            }
            :: acc
        | _ -> acc)
      env.instances.subscript_instances []
  in
  let key (i : T.Instance.t) =
    (i.decl, String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) i.args))
  in
  let all = List.rev !(env.instances.checked) @ subscript_bodies in
  {
    T.Program.packages;
    instances = List.sort (fun a b -> compare (key a) (key b)) all;
    defaults = List.rev !(env.instances.defaults);
    exports = Exports.of_build env;
    export_lines = Exports.lines env;
  }
