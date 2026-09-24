(* Pass 5 (docs/semantics.md §3): every verb body, constant and enum-map entry,
   typed against the signatures pass 4 settled.

   Typing is bottom-up (D6): an expression's type comes from its parts, and
   the only place a destination type matters is a coercion site, where the
   destination is the parameter of the candidate being tried. So a call types
   its arguments first and then resolves its overloads in the three phases of
   functions.md §5.

   A generic verb's body is checked once per instantiation (D12). Resolving a
   call to one records the instance; [run] checks each instance once, with its
   parameters replaced by the arguments it was called with, and an instance may
   ask for more. *)

open Env
module N = Sst.Nodes
module T = Nodes
module S = Signature

let quote = Env.quote

(* ---------------------------------------------------------------------- *)
(* Context                                                                *)
(* ---------------------------------------------------------------------- *)

type role = Symbol | Parameter | This | Binder

type binding = { local : T.Local.t; role : role }

(* Where a `return` and an `abort` go. An arm of a `match` is its own target:
   `=> expr` is `{ return expr }` (adt.md §5.1), so a `return` in an arm is
   the arm's value, and an arm that aborts makes the whole `match` abortable
   (§5.4). *)
type arm_results = {
  mutable results : (Ty.t * Span.t) list;
  mutable aborts : (Ty.t * Span.t) list;
}

type ret_target =
  | To_verb of { ret : Ty.t; abort : Ty.t option }
  | To_arm of arm_results
  | No_return

(* Where a `resolve` goes: the handler or block argument it finishes. *)
type yields = { mutable yields : (Ty.t * Span.t) list }

type resolve_target = To_handler of Ty.t | To_block of yields | No_resolve

type ctx = {
  file : Env.file;
  package : string;
  is_root : bool;
  (* Parameters in scope and what they stand for; in an instance, the
     arguments it was instantiated at. *)
  params : (string * Ty.arg) list;
  mutable scopes : (string, binding) Hashtbl.t list;
  ret_target : ret_target;
  resolve_target : resolve_target;
  (* The subject type of the method being checked, which is what grants
     access to `_` fields (types.md §2.3). *)
  this_type : Ty.t option;
  is_mut : bool;
  (* In a constructor: what `init{ }` builds. *)
  building : Ty.t option;
}

let next_local = ref 0

let type_scope ctx = Types.scope ~params:ctx.params ctx.file

let find_local ctx name = List.find_map (fun tbl -> Hashtbl.find_opt tbl name) ctx.scopes

let push ctx = { ctx with scopes = Hashtbl.create 8 :: ctx.scopes }

let fresh_local name ty span =
  incr next_local;
  { T.Local.id = !next_local; name; ty; span }

let bind ctx role (local : T.Local.t) =
  match ctx.scopes with
  | top :: _ -> Hashtbl.replace top local.T.Local.name { local; role }
  | [] -> ()

(* D14: a local may not shadow a name already in scope -- an enclosing local
   or parameter, a parameter of the generic signature, or a package-scope name
   the file can write. *)
let declare ctx role (name : N.Name.t) ty =
  let text = name.N.Name.text and span = name.N.Name.span in
  (match find_local ctx text with
  | Some b ->
      error span
        (Printf.sprintf
           "%s is already declared at %s, and a local may not shadow a name in scope"
           (quote text) (where b.local.T.Local.span))
  | None -> (
      if List.mem_assoc text ctx.params then
        error span
          (Printf.sprintf "%s is a parameter of this verb, and a local may not shadow it"
             (quote text))
      else
        match lookup_values ctx.file text with
        | d :: _ ->
            error span
              (Printf.sprintf
                 "%s names the declaration at %s, and a local may not shadow a name in \
                  scope"
                 (quote text) (where d.span))
        | [] -> ()));
  let local = fresh_local text ty span in
  bind ctx role local;
  local

let mk node ty span = { T.Expr.node; ty; span }
let invalid span = mk T.Expr.Invalid Ty.Error span

(* ---------------------------------------------------------------------- *)
(* Types of things                                                        *)
(* ---------------------------------------------------------------------- *)

(* A declared type's definition with its arguments applied. A distinct type
   reads through to the type it was defined as, since it is "structurally
   equal to its right-hand side" (types.md §5.1). *)
let rec definition ?(depth = 0) (t : Ty.t) : (Ty.type_id * definition) option =
  match Ty.strip_guest t with
  | Ty.Named (tid, args) -> (
      match Types.type_info_of_id tid with
      | Some ({ definition = Some def; _ } as info) -> (
          let s =
            try List.combine (List.map (fun (p : Ty.param) -> p.id) info.params) args
            with Invalid_argument _ -> []
          in
          let apply = List.map (fun (n, t) -> (n, Ty.subst s t)) in
          match def with
          | Struct fs -> Some (tid, Struct (apply fs))
          | Variant cs -> Some (tid, Variant (apply cs))
          | Enum ms -> Some (tid, Enum ms)
          | Distinct rhs -> if depth > 16 then None else definition ~depth:(depth + 1) (Ty.subst s rhs))
      | _ -> None)
  | _ -> None

let signature_home = function S.Package p -> Some (S.Package p) | h -> Some h

let accessible_sig ctx (s : S.t) =
  match s.home with
  | S.Package p -> String.equal p ctx.package || not (is_private s.name)
  | S.Namespace _ -> true

(* ---------------------------------------------------------------------- *)
(* Instances                                                              *)
(* ---------------------------------------------------------------------- *)

type pending = { p_decl : decl; p_sig : S.t; p_subst : Ty.subst; p_at : Span.t }

let instance_keys : (string, unit) Hashtbl.t = Hashtbl.create 32
let instance_counts : (int, int) Hashtbl.t = Hashtbl.create 32
let pending : pending Queue.t = Queue.create ()
let instances : T.Instance.t list ref = ref []

(* How many instances of one declaration are enough to call it recursion
   without end: `f<T>` calling `f<Pair<T>>`, which no program can finish
   instantiating. *)
let instance_limit = 64

let binding_args (s : S.t) (subst : Ty.subst) =
  List.map
    (fun (p : Ty.param) ->
      ( p,
        match List.assoc_opt p.id subst with
        | Some a -> a
        | None -> Types.param_arg p ))
    s.generics

let describe_instance (s : S.t) subst at =
  Printf.sprintf "in %s with %s, required at %s" (quote s.name)
    (String.concat ", "
       (List.map (fun ((p : Ty.param), a) -> p.name ^ " = " ^ Ty.arg_to_string a) (binding_args s subst)))
    (where at)

let verb_ref (s : S.t) subst =
  { T.Verb_ref.owner = s.owner; name = s.name; instance = binding_args s subst }

let request (s : S.t) subst at =
  match s.owner with
  | S.Declared id when s.generics <> [] ->
      let args = binding_args s subst in
      if List.exists (fun (_, a) -> Ty.arg_contains_error a) args then ()
      else
        let key =
          string_of_int id ^ ":"
          ^ String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) args)
        in
        if not (Hashtbl.mem instance_keys key) then begin
          Hashtbl.add instance_keys key ();
          let count = 1 + Option.value ~default:0 (Hashtbl.find_opt instance_counts id) in
          Hashtbl.replace instance_counts id count;
          if count > instance_limit then begin
            if count = instance_limit + 1 then
              error at
                (Printf.sprintf
                   "%s is instantiated at more than %d sets of arguments; its calls to \
                    itself never reach a fixed set"
                   (quote s.name) instance_limit)
          end
          else Queue.add { p_decl = Hashtbl.find decls id; p_sig = s; p_subst = subst; p_at = at } pending
        end
  | _ -> ()

(* ---------------------------------------------------------------------- *)
(* Overload resolution                                                    *)
(* ---------------------------------------------------------------------- *)

(* An argument as the call site wrote it, already typed. *)
type actual = {
  arg : T.Arg.t;
  aty : Ty.t;
  aspan : Span.t;
  (* A method's subject is never converted (types.md §4.6). *)
  subject : bool;
}

type phase = Direct | Generic | Implicit

type outcome = {
  sig_ : S.t;
  subst : Ty.subst;
  (* Aligned with the signature's parameters; [None] where a field
     constructor's entry was omitted and its default applies. *)
  converted : T.Arg.t option list;
  (* Problems at one argument of a candidate that is otherwise the one: an
     ambiguous implicit constructor (types.md §4.2, step 4). *)
  site_errors : (Span.t * string) list;
}

(* A subscript's result type per set of arguments, and the body typed for
   it. [None] while it is being computed, which is how a subscript whose type
   depends on itself is caught. *)
let subscript_results : (string, Ty.t option) Hashtbl.t = Hashtbl.create 16

let subscript_instances : (string, S.t * Ty.subst * T.Local.t list * T.Expr.t) Hashtbl.t =
  Hashtbl.create 16

let arg_expr = function T.Arg.Value e -> Some e | T.Arg.Block _ -> None

(* The implicit constructors that take a [src] to a [dst]: declared in the
   home package of either, which is the only place one may be (types.md
   §4.5), so no import is involved. *)
let implicit_constructors ~src ~dst =
  let dst = Ty.strip_guest dst in
  match Signatures.type_key dst with
  | None -> []
  | Some key ->
      let homes = List.filter_map Signatures.home [ src; dst ] in
      Hashtbl.find_all constructors key
      |> List.filter (fun (s : S.t) -> S.is_implicit s && List.mem s.home homes)
      |> List.filter_map (fun (s : S.t) ->
             match s.params with
             | [ p ] -> (
                 let open_ = s.generics in
                 match Ty.unify ~open_ [] p.ty (Ty.strip_guest src) with
                 | None -> None
                 | Some subst -> (
                     match Ty.unify ~open_ subst s.ret dst with
                     | None -> None
                     | Some subst ->
                         if List.for_all (fun (q : Ty.param) -> List.mem_assoc q.id subst) open_
                         then Some (s, subst)
                         else None))
             | _ -> None)

let coerce_value ~at (e : T.Expr.t) (s, subst) =
  request s subst at;
  mk (T.Expr.Coerce { ctor = verb_ref s subst; value = e }) (Ty.subst subst s.S.ret) e.T.Expr.span

(* Bind an explicit `T Type` or `n Number` parameter from its argument. *)
let bind_explicit (p : Ty.param) (a : actual) subst =
  match (p.kind, a.arg) with
  | Ty.Type_kind, T.Arg.Value { T.Expr.node = T.Expr.Type_arg t; _ } -> Some ((p.id, Ty.Type t) :: subst)
  | Ty.Number_kind, T.Arg.Value { T.Expr.node = T.Expr.Number_lit text; _ } -> (
      match int_of_string_opt text with
      | Some n -> Some ((p.id, Ty.Number (Ty.Known n)) :: subst)
      | None -> None)
  | Ty.Number_kind, T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Number_param { value; _ }); _ } ->
      Some ((p.id, Ty.Number value) :: subst)
  | _, T.Arg.Value { T.Expr.ty = Ty.Error; _ } -> Some subst
  | _ -> None

let try_candidate ~phase (s : S.t) (slots : actual option list) : outcome option =
  if List.length slots <> List.length s.params then None
  else if phase = Direct && s.generics <> [] then None
  else if phase = Generic && s.generics = [] then None
  else
    let open_ = s.generics in
    let pairs = List.combine s.params slots in
    (* First every argument that matches without conversion, binding the
       parameters it fixes; then, in the implicit phase only, the rest, each
       against its parameter with every binding applied. An implicit
       constructor never discovers a destination (functions.md §5). *)
    let exact subst ((p : S.param), slot) =
      match (slot, subst) with
      | _, None -> (None, None)
      | None, Some subst -> if p.has_default then (Some subst, Some `Default) else (None, None)
      | Some a, Some subst -> (
          match p.binds with
          | Some q -> (
              match bind_explicit q a subst with
              | Some subst -> (Some subst, Some `Exact)
              | None -> (None, None))
          | None -> (
              match
                Ty.unify ~open_ subst (Ty.strip_guest p.ty) (Ty.strip_guest a.aty)
              with
              | Some subst -> (Some subst, Some `Exact)
              | None -> (Some subst, Some `Convert)))
    in
    let subst, marks =
      List.fold_left
        (fun (subst, marks) pair ->
          match subst with
          | None -> (None, marks)
          | Some _ ->
              let subst', mark = exact subst pair in
              (subst', marks @ [ mark ]))
        (Some [], []) pairs
    in
    match subst with
    | None -> None
    | Some subst ->
        if List.exists (fun m -> m = None) marks then None
        else if phase <> Implicit && List.exists (fun m -> m = Some `Convert) marks then None
        else if not (List.for_all (fun (q : Ty.param) -> List.mem_assoc q.id subst) open_) then None
        else begin
          let site_errors = ref [] in
          let converted =
            List.map2
              (fun ((p : S.param), slot) mark ->
                match (slot, mark) with
                | None, _ -> Some None
                | Some a, Some `Exact -> Some (Some a.arg)
                | Some a, Some `Convert -> (
                    if a.subject then None
                    else
                      match arg_expr a.arg with
                      | None -> None
                      | Some e -> (
                          let dst = Ty.subst subst p.ty in
                          if Ty.free_params dst <> [] then None
                          else
                            match implicit_constructors ~src:a.aty ~dst with
                            | [ found ] -> Some (Some (T.Arg.Value (coerce_value ~at:a.aspan e found)))
                            | [] -> None
                            | several ->
                                site_errors :=
                                  ( a.aspan,
                                    Printf.sprintf
                                      "more than one implicit constructor converts %s to %s: %s"
                                      (quote (Ty.to_string a.aty))
                                      (quote (Ty.to_string dst))
                                      (String.concat ", "
                                         (List.map (fun ((s : S.t), _) -> quote (S.to_string s)) several)) )
                                  :: !site_errors;
                                Some (Some a.arg)))
                | _ -> None)
              pairs marks
          in
          if List.exists Option.is_none converted then None
          else
            Some
              {
                sig_ = s;
                subst;
                converted = List.map Option.get converted;
                site_errors = List.rev !site_errors;
              }
        end

type resolution = Resolved of outcome | No_match | Ambiguous of S.t list

let resolve candidates (slots_for : S.t -> actual option list option) =
  let attempt phase =
    List.filter_map
      (fun s -> Option.bind (slots_for s) (fun slots -> try_candidate ~phase s slots))
      candidates
  in
  let rec phases = function
    | [] -> No_match
    | phase :: rest -> (
        match attempt phase with
        | [] -> phases rest
        | [ one ] -> Resolved one
        | several -> Ambiguous (List.map (fun o -> o.sig_) several))
  in
  phases [ Direct; Generic; Implicit ]

let positional actuals (s : S.t) =
  match s.kind with
  | S.Constructor { fields = true; _ } -> None
  | _ -> Some (List.map Option.some actuals)

let has_literal actuals =
  List.exists
    (fun a ->
      Ty.is_bare_literal a.aty
      || match a.aty with Ty.Concept (Ty.Array_lit (t, _)) -> Ty.is_bare_literal t | _ -> false)
    actuals

let describe_args actuals =
  "(" ^ String.concat ", " (List.map (fun a -> Ty.to_string a.aty) actuals) ^ ")"

let list_candidates cands =
  let shown = List.filteri (fun i _ -> i < 4) cands in
  String.concat "; " (List.map (fun s -> quote (S.to_string s)) shown)
  ^ if List.length cands > 4 then "; ..." else ""

let report_resolution ?(literal = false) ~span ~what ~args result cands =
  match result with
  | Resolved o ->
      List.iter (fun (at, message) -> error at message) o.site_errors;
      Some o
  | Ambiguous several ->
      error span
        (Printf.sprintf "the call to %s is ambiguous: %s %s accept %s" what
           (list_candidates several)
           (if List.length several = 2 then "both" else "all")
           args);
      None
  | No_match ->
      (* The one no-match with a fix worth naming: a literal offered where
         only inference could have placed it (generics.md §5.4). *)
      let hint =
        if literal && List.exists (fun (s : S.t) -> s.generics <> []) cands then
          "; a bare literal fixes no type, so it cannot drive inference: wrap it in \
           the type it is meant to be, as `Int(4)`"
        else ""
      in
      error span
        (Printf.sprintf "no %s accepts %s; the %s %s%s" what args
           (if List.length cands = 1 then "candidate is" else "candidates are")
           (list_candidates cands) hint);
      None

(* ---------------------------------------------------------------------- *)
(* Termination                                                            *)
(* ---------------------------------------------------------------------- *)

(* Whether a run of statements ends on every path: some statement in it
   leaves for good. A call never counts -- which calls exit their caller is
   not something a signature says -- and neither does a `match`, whose arms
   `return` to it rather than out of the verb. *)
let ends ~resolve (stats : T.Stat.t list) =
  List.exists
    (fun (s : T.Stat.t) ->
      match s.T.Stat.node with
      | T.Stat.Return _ | T.Stat.Abort _ -> true
      | T.Stat.Resolve _ -> resolve
      | _ -> false)
    stats

(* ---------------------------------------------------------------------- *)
(* Expressions                                                            *)
(* ---------------------------------------------------------------------- *)

let rec expr ?(flow = false) ctx (e : N.Expr.t) : T.Expr.t =
  let span = e.N.Expr.span in
  match e.N.Expr.node with
  | N.Expr.IntLit s | N.Expr.FloatLit s -> mk (T.Expr.Number_lit s) (Ty.Concept Ty.Number_lit) span
  | N.Expr.StrLit s -> mk (T.Expr.Text_lit s) (Ty.Concept Ty.Text_lit) span
  | N.Expr.BoolLit b -> mk (T.Expr.Bool_lit b) Ty.bool_primitive span
  | N.Expr.CollectionLit items -> array_literal ctx span items
  | N.Expr.MapLit entries -> map_literal ctx span entries
  | N.Expr.NameExpr n -> name_value ctx n
  | N.Expr.TypeMember { type_; member } -> type_member ctx span type_ member
  | N.Expr.TypeValue name -> (
      match Types.resolve_head (type_scope ctx) name with
      | Types.Unknown -> invalid span
      | head ->
          let t = Types.apply (type_scope ctx) span head name [] in
          mk (T.Expr.Type_arg t) (Ty.Concept Ty.Type_value) span)
  | N.Expr.DotAccess { target; field; abort_handle } -> member ~flow ctx span target field abort_handle
  | N.Expr.Subscript { target; args } -> subscript ctx span target args
  | N.Expr.Ref inner ->
      let v = expr ctx inner in
      (match v.T.Expr.ty with
      | Ty.Error | Ty.Param _ -> ()
      | Ty.Guest _ -> ()
      | t ->
          if not (Types.is_reference t) then
            error span
              (Printf.sprintf
                 "`&` takes a guest of a reference type, and %s is a value type"
                 (quote (Ty.to_string t))));
      mk (T.Expr.Ref v) (Ty.Guest (Ty.strip_guest v.T.Expr.ty)) span
  | N.Expr.Init fields -> init ctx span fields
  | N.Expr.Spawn call -> spawn ctx call
  | N.Expr.Match m -> match_ ~flow ctx m
  | N.Expr.VerbCall call -> fst (verb_call ~flow ctx call)
  | N.Expr.FuncLambda l ->
      lambda ctx span ~this_type:None ~params:l.N.Func_lambda.params ~ret_type:l.N.Func_lambda.ret_type
        ~is_mut:false ~body:l.N.Func_lambda.body
  | N.Expr.MethLambda l ->
      lambda ctx span ~this_type:(Some l.N.Meth_lambda.this_type) ~params:l.N.Meth_lambda.params
        ~ret_type:l.N.Meth_lambda.ret_type ~is_mut:l.N.Meth_lambda.is_mut ~body:l.N.Meth_lambda.body

(* syntax.md §2.9: every element already has the one element type; nothing
   searches for a common one. *)
and array_literal ctx span items =
  let items = List.map (expr ctx) items in
  match items with
  | [] ->
      error span "an array literal holds at least one element; name the type to build an empty one";
      invalid span
  | first :: rest ->
      List.iter
        (fun (item : T.Expr.t) ->
          if not (Ty.equal item.T.Expr.ty first.T.Expr.ty) then
            error item.T.Expr.span
              (Printf.sprintf
                 "every element of an array literal has one type: this one is %s, and \
                  the first is %s"
                 (quote (Ty.to_string item.T.Expr.ty))
                 (quote (Ty.to_string first.T.Expr.ty))))
        rest;
      mk (T.Expr.Array_lit items)
        (Ty.Concept (Ty.Array_lit (first.T.Expr.ty, Ty.Known (List.length items))))
        span

and map_literal ctx span entries =
  let entries = List.map (fun (k, v) -> (expr ctx k, expr ctx v)) entries in
  match entries with
  | [] ->
      error span "a map literal holds at least one entry";
      invalid span
  | (k0, v0) :: rest ->
      List.iter
        (fun ((k : T.Expr.t), (v : T.Expr.t)) ->
          if not (Ty.equal k.T.Expr.ty k0.T.Expr.ty) then
            error k.T.Expr.span
              (Printf.sprintf "every key of a map literal has one type: this one is %s, and the first is %s"
                 (quote (Ty.to_string k.T.Expr.ty)) (quote (Ty.to_string k0.T.Expr.ty)));
          if not (Ty.equal v.T.Expr.ty v0.T.Expr.ty) then
            error v.T.Expr.span
              (Printf.sprintf "every value of a map literal has one type: this one is %s, and the first is %s"
                 (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string v0.T.Expr.ty))))
        rest;
      mk (T.Expr.Map_lit entries) (Ty.Concept (Ty.Map_lit (k0.T.Expr.ty, v0.T.Expr.ty))) span

and constant_ref (d : decl) span =
  let ty = Option.value ~default:Ty.Error (Hashtbl.find_opt constant_types d.id) in
  mk (T.Expr.Var (T.Name_ref.Global { decl = d.id; name = decl_name d })) ty span

and call_only span name =
  error span
    (Printf.sprintf
       "%s is a function, and a function has no value form: call it, or hold a \
        function value in a lambda-variable (functions.md §7.1)"
       (quote name));
  invalid span

and name_value ctx (n : N.Name_expr.t) =
  let span = n.N.Name_expr.span in
  match n.N.Name_expr.node with
  | N.Name_expr.Ident id -> (
      let text = id.N.Name.text in
      match find_local ctx text with
      | Some b -> mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty span
      | None -> (
          match List.assoc_opt text ctx.params with
          | Some (Ty.Number value) ->
              mk (T.Expr.Var (T.Name_ref.Number_param { name = text; value })) (Ty.Concept Ty.Number_lit) span
          | Some (Ty.Type t) -> mk (T.Expr.Type_arg t) (Ty.Concept Ty.Type_value) span
          | None -> (
              match lookup_values ctx.file text with
              | d :: _ when not (is_function d) -> constant_ref d span
              | _ :: _ -> call_only span text
              | [] ->
                  error span
                    (Printf.sprintf "no name %s is in scope%s" (quote text)
                       (missing_import_hint ctx.file text ~members:package_values));
                  invalid span)))
  | N.Name_expr.Qualified { package = q; ident } -> (
      match qualified ctx.file q.N.Name.text ident.N.Name.text ~members:package_values with
      | Error message ->
          error q.N.Name.span message;
          invalid span
      | Ok (pkg, found, reachable) -> (
          match reachable with
          | d :: _ when not (is_function d) -> constant_ref d span
          | _ :: _ -> call_only span (pkg ^ "$" ^ ident.N.Name.text)
          | [] ->
              error span
                (if found <> [] then
                   Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text) (quote pkg)
                 else Printf.sprintf "the package %s has no member %s" (quote pkg) (quote ident.N.Name.text));
              invalid span))
  | N.Name_expr.Intrinsic { package = ns; ident } -> (
      let ns = ns.N.Name.text and text = ident.N.Name.text in
      let spelling = "@" ^ ns ^ "$" ^ text in
      if ns = "program" && not ctx.is_root then begin
        error span
          (Printf.sprintf
             "only the root package reaches `@program$`; %s receives the console and \
              runtime from it as an argument"
             (quote ctx.package));
        invalid span
      end
      else
        match Intrinsics.find_value ns text with
        | Some ty -> mk (T.Expr.Var (T.Name_ref.Intrinsic spelling)) ty span
        | None ->
            if List.mem_assoc (ns, text) Intrinsics.functions then
              error span
                (Printf.sprintf "%s is an intrinsic operation, and has no value form" (quote spelling))
            else error span (Printf.sprintf "no intrinsic named %s" (quote spelling));
            invalid span)

(* `Colors.red`: a payloadless enum member. A variant case is written with its
   payload, and a named constructor is called. *)
and type_member ctx span (type_ : N.Name_type.t) (member : N.Name.t) =
  let m = member.N.Name.text in
  let t = Types.apply (type_scope ctx) span (Types.resolve_head (type_scope ctx) type_) type_ [] in
  match (t, definition t) with
  | Ty.Error, _ -> invalid span
  | _, Some (_, Enum members) when List.mem m members -> mk (T.Expr.Enum_member m) t span
  | _, Some (tid, Enum _) ->
      error member.N.Name.span (Printf.sprintf "%s has no member %s" (quote tid.Ty.name) (quote m));
      invalid span
  | _, Some (tid, Variant cases) when List.mem_assoc m cases ->
      error span
        (Printf.sprintf "%s is a case of %s, and a case is built with its payload: `%s.%s(...)`"
           (quote m) (quote tid.Ty.name) tid.Ty.name m);
      invalid span
  | _ ->
      error span
        (Printf.sprintf "%s has no member %s that can be read without a call"
           (quote (Ty.to_string t)) (quote m));
      invalid span

(* D10: a member read is a field read, a case read or an enum-map read, and
   only the target's type says which. D13: a case read can fail, so it takes a
   handler, and the others cannot, so they take none. *)
and member ~flow ctx span target (field : N.Name.t) handle =
  let target = expr ctx target in
  let f = field.N.Name.text in
  let no_handler () =
    match handle with
    | Some (h : N.Abort_handle.t) ->
        error h.N.Abort_handle.span
          (Printf.sprintf "reading %s cannot fail, so it takes no handler" (quote f))
    | None -> ()
  in
  match target.T.Expr.ty with
  | Ty.Error ->
      ignore (handler_opt ctx ~abort:Ty.Error ~ok:Ty.Error handle);
      invalid span
  | ty -> (
      match definition ty with
      | Some (tid, Struct fields) -> (
          no_handler ();
          let rec slot i = function
            | [] -> None
            | (n, t) :: rest -> if String.equal n f then Some (i, t) else slot (i + 1) rest
          in
          match slot 0 fields with
          | None -> map_read ctx span target tid f ~missing:(fun () ->
                error field.N.Name.span
                  (Printf.sprintf "%s has no field %s" (quote tid.Ty.name) (quote f)))
          | Some (i, t) ->
              if is_private f && not (private_access ctx tid) then
                error field.N.Name.span
                  (Printf.sprintf
                     "%s is private: only a method whose subject is %s may read it \
                      (types.md §2.3)"
                     (quote f) (quote tid.Ty.name));
              mk (T.Expr.Field { target; field = f; slot = i }) t span)
      | Some (tid, Variant cases) -> (
          match List.assoc_opt f cases with
          | None ->
              no_handler ();
              map_read ctx span target tid f ~missing:(fun () ->
                  error field.N.Name.span
                    (Printf.sprintf "%s has no case %s" (quote tid.Ty.name) (quote f)))
          | Some payload -> (
              match handle with
              | None ->
                  error span
                    (Printf.sprintf
                       "reading the case %s of %s fails when another case is live, so \
                        it takes a `?` or `??` handler"
                       (quote f) (quote tid.Ty.name));
                  mk (T.Expr.Case_read { target; case = f; handler = { T.Handler.binder = None; body = { T.Block.stats = []; span }; span } }) payload span
              | Some h ->
                  let h = type_handler ctx ~abort:Ty.unit_primitive ~ok:payload h in
                  mk (T.Expr.Case_read { target; case = f; handler = h }) payload span))
      | Some (tid, Enum _) ->
          no_handler ();
          map_read ctx span target tid f ~missing:(fun () ->
              error field.N.Name.span
                (Printf.sprintf "no enum map %s is declared for %s" (quote f) (quote tid.Ty.name)))
      | _ ->
          ignore flow;
          no_handler ();
          error field.N.Name.span
            (Printf.sprintf "%s has no member %s" (quote (Ty.to_string ty)) (quote f));
          invalid span)

and private_access ctx tid =
  match Option.map Ty.strip_guest ctx.this_type with
  | Some (Ty.Named (this_tid, _)) -> this_tid = tid
  | _ -> false

(* An enum map is found where a method is: in the enum's home package, then
   in the current one. *)
and map_read ctx span target tid property ~missing =
  let maps = Option.value ~default:[] (Hashtbl.find_opt enum_maps (tid, property)) in
  let visible =
    List.filter
      (fun m -> m.map_decl.package = tid.Ty.package || m.map_decl.package = ctx.package)
      maps
  in
  match visible with
  | m :: _ -> mk (T.Expr.Map_read { target; map = m.map_decl.id; property }) m.map_ty span
  | [] ->
      missing ();
      invalid span

and subscript ctx span target args =
  let target = expr ctx target in
  let args = List.map (expr ctx) args in
  let homes = List.filter_map Signatures.home [ target.T.Expr.ty ] @ [ S.Package ctx.package ] in
  let cands =
    List.filter (fun (s : S.t) -> List.mem s.home homes && accessible_sig ctx s) !subscripts
  in
  if target.T.Expr.ty = Ty.Error || List.exists (fun (a : T.Expr.t) -> a.T.Expr.ty = Ty.Error) args then
    invalid span
  else
    let actuals =
      { arg = T.Arg.Value target; aty = target.T.Expr.ty; aspan = target.T.Expr.span; subject = true }
      :: List.map (fun (a : T.Expr.t) -> { arg = T.Arg.Value a; aty = a.T.Expr.ty; aspan = a.T.Expr.span; subject = false }) args
    in
    if cands = [] then begin
      error span (Printf.sprintf "%s declares no subscript" (quote (Ty.to_string target.T.Expr.ty)));
      invalid span
    end
    else
      match
        report_resolution ~span ~what:"subscript" ~args:(describe_args actuals)
          (resolve cands (positional actuals)) cands
      with
      | None -> invalid span
      | Some o ->
          let ty =
            match o.sig_.owner with
            | S.Intrinsic _ -> Ty.subst o.subst o.sig_.ret
            | S.Declared id -> subscript_result (Hashtbl.find decls id) o.sig_ o.subst span
          in
          let args = List.filter_map (function Some (T.Arg.Value e) -> Some e | _ -> None) (List.tl o.converted) in
          mk (T.Expr.Subscript { target; impl = verb_ref o.sig_ o.subst; args }) ty span

and init ctx span fields =
  match ctx.building with
  | None ->
      error span "`init{ }` is valid only in a constructor body, which is what naming a verb after a type unlocks";
      List.iter (fun (f : N.Field_arg.t) -> ignore (expr ctx f.N.Field_arg.value)) fields;
      invalid span
  | Some built -> (
      match definition built with
      | Some (_, Struct declared) ->
          let seen = Hashtbl.create 8 in
          let values =
            List.filter_map
              (fun (f : N.Field_arg.t) ->
                let name = f.N.Field_arg.name.N.Name.text in
                let value = expr ctx f.N.Field_arg.value in
                let rec slot i = function
                  | [] -> None
                  | (n, t) :: rest -> if String.equal n name then Some (i, t) else slot (i + 1) rest
                in
                match slot 0 declared with
                | None ->
                    error f.N.Field_arg.name.N.Name.span
                      (Printf.sprintf "%s has no field %s" (quote (Ty.to_string built)) (quote name));
                    None
                | Some (i, t) ->
                    if Hashtbl.mem seen name then
                      error f.N.Field_arg.name.N.Name.span
                        (Printf.sprintf "the field %s is already assigned" (quote name))
                    else Hashtbl.add seen name ();
                    if not (Ty.assignable ~dst:t ~src:value.T.Expr.ty) then
                      error value.T.Expr.span
                        (Printf.sprintf
                           "the field %s is %s, and this is %s; `init{ }` is not a coercion \
                            site, so a conversion is written out"
                           (quote name) (quote (Ty.to_string t)) (quote (Ty.to_string value.T.Expr.ty)));
                    Some { T.Field_value.name; slot = i; value; span = f.N.Field_arg.span })
              fields
          in
          let missing = List.filter (fun (n, _) -> not (Hashtbl.mem seen n)) declared in
          if missing <> [] then
            error span
              (Printf.sprintf "`init{ }` assigns every field, and this one leaves out %s"
                 (String.concat ", " (List.map (fun (n, _) -> quote n) missing)));
          mk (T.Expr.Init values) built span
      | _ ->
          error span
            (Printf.sprintf "`init{ }` builds a struct, and %s is not one" (quote (Ty.to_string built)));
          invalid span)

(* ---------------------------------------------------------------------- *)
(* Handlers                                                               *)
(* ---------------------------------------------------------------------- *)

and type_handler ctx ~abort ~ok (h : N.Abort_handle.t) : T.Handler.t =
  let inner = push { ctx with resolve_target = To_handler ok } in
  let binder = Option.map (fun b -> declare inner Binder b abort) h.N.Abort_handle.binder in
  let body = block_in inner h.N.Abort_handle.body in
  if not (ends ~resolve:true body.T.Block.stats) then
    error h.N.Abort_handle.span
      "every path through a handler ends in `resolve`, `return` or `abort`; this one \
       can fall through (error-handling.md §3.2)";
  { T.Handler.binder; body; span = h.N.Abort_handle.span }

and handler_opt ctx ~abort ~ok handle = Option.map (type_handler ctx ~abort ~ok) handle

(* What an abortable operation's call site owes: a handler when it can
   abort, none when it cannot (error-handling.md §6). In the value position
   of an arm's `return`, an unhandled abort flows out through the `match`
   instead (adt.md §5.4). *)
and owe_handler ~flow ctx ~what ~span ~abort ~ok handle =
  match (abort, handle) with
  | None, None -> None
  | None, Some (h : N.Abort_handle.t) ->
      error h.N.Abort_handle.span (Printf.sprintf "%s cannot abort, so it takes no handler" what);
      Some (type_handler ctx ~abort:Ty.Error ~ok h)
  | Some a, Some h -> Some (type_handler ctx ~abort:a ~ok h)
  | Some a, None -> (
      match (flow, ctx.ret_target) with
      | true, To_arm r ->
          r.aborts <- r.aborts @ [ (a, span) ];
          None
      | _ ->
          if a <> Ty.Error then
            error span
              (Printf.sprintf
                 "%s can abort with %s, so the call needs a `?` or `??` handler"
                 what (quote (Ty.to_string a)));
          None)

(* ---------------------------------------------------------------------- *)
(* Calls                                                                  *)
(* ---------------------------------------------------------------------- *)

and actual_of ctx (a : N.Call_arg.t) =
  match a.N.Call_arg.node with
  | N.Call_arg.Value e ->
      let v = expr ctx e in
      { arg = T.Arg.Value v; aty = v.T.Expr.ty; aspan = v.T.Expr.span; subject = false }
  | N.Call_arg.Block b ->
      let typed, ty = block_argument ctx b in
      { arg = T.Arg.Block typed; aty = ty; aspan = a.N.Call_arg.span; subject = false }

(* A block argument captures the scope it is written in (control-flow.md
   §2.2), and its type says what it yields (§2.4). *)
and block_argument ctx (b : N.Block.t) =
  let y = { yields = [] } in
  let inner = { ctx with resolve_target = To_block y } in
  let typed = block_in (push inner) b in
  let ty =
    match y.yields with
    | [] -> Ty.Block None
    | (first, _) :: rest ->
        List.iter
          (fun (t, at) ->
            if not (Ty.equal t first) then
              error at
                (Printf.sprintf "a block yields one type: this `resolve` gives %s, and the first gives %s"
                   (quote (Ty.to_string t)) (quote (Ty.to_string first))))
          rest;
        if not (ends ~resolve:true typed.T.Block.stats) then
          error b.N.Block.span
            "a block that yields a value ends every path in `resolve`, `return` or `abort`";
        Ty.Block (Some first)
  in
  (typed, Ty.Concept ty)

and verb_call ~flow ctx (vc : N.Verb_call.t) : T.Expr.t * S.t option =
  let span = vc.N.Verb_call.span in
  match vc.N.Verb_call.node with
  | N.Verb_call.Call { callee; args; form; abort_handle } -> (
      let actuals = List.map (actual_of ctx) args in
      match form with
      | N.Call_form.Function -> function_call ~flow ctx span callee actuals abort_handle
      | N.Call_form.Method { is_mut } -> method_call ~flow ctx span callee actuals ~is_mut abort_handle)
  | N.Verb_call.Constructor { name; args; abort_handle } ->
      (constructor_call ctx span name args abort_handle, None)
  | N.Verb_call.Op { op; left; right; swapped; abort_handle } ->
      operator ~flow ctx span op left right ~swapped abort_handle
  | N.Verb_call.Flip { value; abort_handle } -> flip ~flow ctx span value abort_handle

and any_error actuals = List.exists (fun a -> Ty.contains_error a.aty) actuals

and finish_call ~flow ctx ~span ~what (o : outcome) handle build =
  request o.sig_ o.subst span;
  let ok = Ty.subst o.subst o.sig_.ret in
  let abort = Option.map (Ty.subst o.subst) o.sig_.abort in
  let handler = handle_call ~flow ctx ~what ~span ~abort ~ok handle in
  let args = List.filter_map Fun.id o.converted in
  (mk (build (verb_ref o.sig_ o.subst) args handler) ok span, Some o.sig_)

and handle_call ~flow ctx ~what ~span ~abort ~ok h = owe_handler ~flow ctx ~what ~span ~abort ~ok h

and skip_handler ctx handle = ignore (handler_opt ctx ~abort:Ty.Error ~ok:Ty.Error handle)

and function_call ~flow ctx span (callee : N.Expr.t) actuals handle =
  let call_decls ~name cands =
    let cands = List.filter_map (fun (d : decl) -> Hashtbl.find_opt signatures d.id) cands in
    if any_error actuals then begin
      skip_handler ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution ~literal:(has_literal actuals) ~span ~what:(quote name) ~args:(describe_args actuals)
          (resolve cands (positional actuals)) cands
      with
      | None ->
          skip_handler ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call ~flow ctx ~span ~what:(quote name) o handle (fun callee args handler ->
              T.Expr.Call { callee; args; handler })
  in
  let value_call (fn : T.Expr.t) = call_value ~flow ctx span fn actuals handle in
  match callee.N.Expr.node with
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Ident id; span = at } -> (
      let text = id.N.Name.text in
      match find_local ctx text with
      | Some b -> value_call (mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty at)
      | None -> (
          match lookup_values ctx.file text with
          | d :: _ when not (is_function d) -> value_call (constant_ref d at)
          | [] ->
              let hint = missing_import_hint ctx.file text ~members:package_values in
              error at (Printf.sprintf "no function named %s is in scope%s" (quote text) hint);
              skip_handler ctx handle;
              (invalid span, None)
          | fns -> call_decls ~name:text fns))
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Qualified { package = q; ident }; span = at } -> (
      match qualified ctx.file q.N.Name.text ident.N.Name.text ~members:package_values with
      | Error message ->
          error q.N.Name.span message;
          skip_handler ctx handle;
          (invalid span, None)
      | Ok (pkg, found, reachable) -> (
          let name = pkg ^ "$" ^ ident.N.Name.text in
          match reachable with
          | d :: _ when not (is_function d) -> value_call (constant_ref d at)
          | [] ->
              error at
                (if found <> [] then Printf.sprintf "%s is private to the package %s" (quote ident.N.Name.text) (quote pkg)
                 else Printf.sprintf "the package %s has no function %s" (quote pkg) (quote ident.N.Name.text));
              skip_handler ctx handle;
              (invalid span, None)
          | fns -> call_decls ~name fns))
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Intrinsic { package = ns; ident }; span = at } -> (
      let ns = ns.N.Name.text and text = ident.N.Name.text in
      match List.assoc_opt (ns, text) Intrinsics.functions with
      | None ->
          error at (Printf.sprintf "no intrinsic operation named %s" (quote ("@" ^ ns ^ "$" ^ text)));
          skip_handler ctx handle;
          (invalid span, None)
      | Some s -> (
          if any_error actuals then (skip_handler ctx handle; (invalid span, None))
          else
            match
              report_resolution ~span ~what:(quote s.S.name) ~args:(describe_args actuals)
                (resolve [ s ] (positional actuals)) [ s ]
            with
            | None ->
                skip_handler ctx handle;
                (invalid span, None)
            | Some o ->
                finish_call ~flow ctx ~span ~what:(quote s.S.name) o handle (fun callee args handler ->
                    T.Expr.Call { callee; args; handler })))
  | _ -> value_call (expr ctx callee)

(* Calling a function value. It is one value with one type, so there is one
   candidate; its arguments are still coercion sites. *)
and call_value ~flow ctx span (fn : T.Expr.t) actuals handle =
  match Ty.strip_guest fn.T.Expr.ty with
  | Ty.Error ->
      skip_handler ctx handle;
      (invalid span, None)
  | Ty.Verb v -> (
      let params =
        (match v.Ty.this_ with Some t -> [ t ] | None -> []) @ v.Ty.params
      in
      let s =
        {
          S.owner = S.Intrinsic "<value>";
          name = "this function value";
          home = S.Package ctx.package;
          kind = S.Function;
          generics = [];
          params = List.mapi (fun i t -> { S.name = string_of_int i; ty = t; binds = None; has_default = false }) params;
          ret = v.Ty.ret;
          abort = v.Ty.abort;
          is_mut = v.Ty.is_mut;
        }
      in
      if any_error actuals then (skip_handler ctx handle; (invalid span, None))
      else
        match
          report_resolution ~span ~what:"this function value" ~args:(describe_args actuals)
            (resolve [ s ] (positional actuals)) [ s ]
        with
        | None ->
            skip_handler ctx handle;
            (invalid span, None)
        | Some o ->
            let handler = owe_handler ~flow ctx ~what:"this function value" ~span ~abort:v.Ty.abort ~ok:v.Ty.ret handle in
            let args = List.filter_map Fun.id o.converted in
            (mk (T.Expr.Call_value { callee = fn; args; handler }) v.Ty.ret span, None))
  | other ->
      error fn.T.Expr.span (Printf.sprintf "%s is not a function value, so it cannot be called" (quote (Ty.to_string other)));
      skip_handler ctx handle;
      (invalid span, None)

(* functions.md §6.1: the subject type's home package first, then the
   current one; a qualified call names its package instead. *)
and method_call ~flow ctx span (callee : N.Expr.t) actuals ~is_mut handle =
  let actuals = match actuals with a :: rest -> { a with subject = true } :: rest | [] -> [] in
  let subject = List.hd actuals in
  let named_in home name =
    Hashtbl.find_all methods name
    |> List.filter (fun (s : S.t) -> s.home = home && accessible_sig ctx s)
    |> List.rev
  in
  let check_marker (s : S.t) =
    if s.is_mut && not is_mut then
      error span
        (Printf.sprintf "%s is a `mut` method, so it is called with `!`" (quote s.name))
    else if (not s.is_mut) && is_mut then
      error span
        (Printf.sprintf "%s is not a `mut` method, so it is called with `:`" (quote s.name))
  in
  let resolve_in stages name =
    if any_error actuals then (skip_handler ctx handle; (invalid span, None))
    else
      let all = List.concat stages in
      let rec try_stages = function
        | [] -> No_match
        | [] :: rest -> try_stages rest
        | cands :: rest -> (
            match resolve cands (positional actuals) with
            | No_match -> try_stages rest
            | r -> r)
      in
      if all = [] then begin
        let home =
          match Signatures.home subject.aty with
          | Some h -> Printf.sprintf " in %s, the home of %s," (quote (S.home_to_string h)) (quote (Ty.to_string subject.aty))
          | None -> ""
        in
        error span
          (Printf.sprintf "no method named %s is declared%s or in this package" (quote name) home);
        skip_handler ctx handle;
        (invalid span, None)
      end
      else
        match
          report_resolution ~literal:(has_literal actuals) ~span ~what:(Printf.sprintf "method %s" (quote name))
            ~args:(describe_args actuals) (try_stages stages) all
        with
        | None ->
            skip_handler ctx handle;
            (invalid span, None)
        | Some o ->
            check_marker o.sig_;
            finish_call ~flow ctx ~span ~what:(quote name) o handle (fun callee args handler ->
                T.Expr.Call { callee; args; handler })
  in
  match callee.N.Expr.node with
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Ident id; span = at } -> (
      let text = id.N.Name.text in
      (* A lambda-variable with a subject is called the way a method is. *)
      let value =
        match find_local ctx text with
        | Some b -> Some (mk (T.Expr.Var (T.Name_ref.Local b.local)) b.local.T.Local.ty at)
        | None -> None
      in
      match value with
      | Some ({ T.Expr.ty = Ty.Verb { Ty.this_ = Some _; is_mut = m; _ }; _ } as fn) ->
          if m <> is_mut then
            error span
              (if m then "this function value is `mut`, so it is called with `!`"
               else "this function value is not `mut`, so it is called with `:`");
          call_value ~flow ctx span fn actuals handle
      | _ ->
          let home_stage =
            match Signatures.home subject.aty with Some h -> named_in h text | None -> []
          in
          let current =
            if Signatures.home subject.aty = Some (S.Package ctx.package) then []
            else named_in (S.Package ctx.package) text
          in
          resolve_in [ home_stage; current ] text)
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Qualified { package = q; ident }; _ } -> (
      match qualified_package ctx.file q.N.Name.text with
      | Error message ->
          error q.N.Name.span message;
          skip_handler ctx handle;
          (invalid span, None)
      | Ok pkg -> resolve_in [ named_in (S.Package pkg) ident.N.Name.text ] ident.N.Name.text)
  | N.Expr.NameExpr { N.Name_expr.node = N.Name_expr.Intrinsic { package = ns; ident }; _ } ->
      resolve_in [ named_in (S.Namespace ns.N.Name.text) ident.N.Name.text ] ident.N.Name.text
  | _ ->
      error callee.N.Expr.span "a method is called by its name";
      skip_handler ctx handle;
      (invalid span, None)

and constructor_call ctx span (name : N.Constructor_name.t) (args : N.Constructor_args.t) handle =
  let sc = type_scope ctx in
  let member = Option.map (fun (m : N.Name.t) -> m.N.Name.text) name.N.Constructor_name.member in
  let head = Types.resolve_head sc name.N.Constructor_name.type_ in
  let no_handler () =
    match handle with
    | Some (h : N.Abort_handle.t) ->
        error h.N.Abort_handle.span "a constructor cannot abort, so it takes no handler";
        skip_handler ctx handle
    | None -> ()
  in
  let type_args () =
    match args.N.Constructor_args.node with
    | N.Constructor_args.Positional ps -> List.iter (fun a -> ignore (actual_of ctx a)) ps
    | N.Constructor_args.Fields fs -> List.iter (fun (f : N.Field_arg.t) -> ignore (expr ctx f.N.Field_arg.value)) fs
  in
  (* What the name builds, before any arguments: a generic type is named
     bare, and its arguments are inferred (generics.md §5.1). *)
  let target : [ `Type of Ty.t * Ty.param list | `None ] =
    match head with
    | Types.Unknown -> `None
    | Types.Declared d -> (
        match Hashtbl.find_opt type_infos d.id with
        | Some info -> `Type (Ty.Named (info.tid, List.map Types.param_arg info.params), info.params)
        | None -> (
            match Hashtbl.find_opt alias_infos d.id with
            | Some a when a.alias_params = [] -> `Type (Types.alias_target a, [])
            | Some _ ->
                error span "a generic alias cannot name a constructor; name the type it stands for";
                `None
            | None -> `None))
    | Types.Intrinsic_type info ->
        let params = List.map (fun k -> Ty.fresh_param ~name:"_" ~kind:k) info.params in
        `Type (Ty.Intrinsic { namespace = info.namespace; name = info.name; args = List.map Types.param_arg params }, params)
    | Types.Bound (Ty.Type t) -> `Type (t, [])
    | Types.Bound (Ty.Number _) ->
        error span "a number parameter has no constructor";
        `None
    | Types.Concept_type c ->
        error span (Printf.sprintf "%s is a concept type, which has no constructor" (quote ("@concepts$" ^ c)));
        `None
  in
  match target with
  | `None ->
      type_args ();
      skip_handler ctx handle;
      invalid span
  | `Type (built, open_) -> (
      match (definition built, member) with
      | Some (tid, Variant cases), Some m when List.mem_assoc m cases ->
          no_handler ();
          case_form ctx span tid (List.assoc m cases) built open_ m args
      | Some (tid, Variant _), None ->
          type_args ();
          no_handler ();
          error span
            (Printf.sprintf "a variant is built by naming a case, as `%s.case(payload)`" tid.Ty.name);
          invalid span
      | Some (tid, Enum members), Some m when List.mem m members ->
          type_args ();
          no_handler ();
          error span
            (Printf.sprintf "%s is a member of the enum %s and carries no payload; it is written `%s.%s`"
               (quote m) (quote tid.Ty.name) tid.Ty.name m);
          invalid span
      | _ -> (
          let what =
            quote
              ((match built with Ty.Named (tid, _) -> tid.Ty.name | t -> Ty.to_string t)
              ^ Option.fold ~none:"" ~some:(fun m -> "." ^ m) member)
          in
          let homes =
            List.filter_map Signatures.home [ built ] @ [ S.Package ctx.package ]
          in
          let cands =
            match Signatures.type_key built with
            | None -> []
            | Some key ->
                Hashtbl.find_all constructors key
                |> List.rev
                |> List.filter (fun (s : S.t) ->
                       (match s.kind with S.Constructor c -> c.member = member | _ -> false)
                       && List.mem s.home homes && accessible_sig ctx s)
          in
          no_handler ();
          if cands = [] then begin
            type_args ();
            error span
              (Printf.sprintf "%s has no constructor%s" (quote (Ty.to_string built))
                 (match member with Some m -> " named " ^ quote m | None -> ""));
            invalid span
          end
          else
            match args.N.Constructor_args.node with
            | N.Constructor_args.Positional ps -> (
                let actuals = List.map (actual_of ctx) ps in
                if any_error actuals then invalid span
                else
                  match
                    report_resolution ~literal:(has_literal actuals) ~span ~what ~args:(describe_args actuals)
                      (resolve (List.filter (fun (s : S.t) -> match s.kind with S.Constructor { fields; _ } -> not fields | _ -> false) cands)
                         (positional actuals))
                      cands
                  with
                  | None -> invalid span
                  | Some o ->
                      request o.sig_ o.subst span;
                      let ret = Ty.subst o.subst o.sig_.ret in
                      mk
                        (T.Expr.Construct
                           { ctor = verb_ref o.sig_ o.subst; args = List.filter_map Fun.id o.converted; handler = None })
                        ret span)
            | N.Constructor_args.Fields fs -> field_constructor_call ctx span what cands fs))

(* `Type{ a = x; b = y; }` against the field constructors: each entry fills
   the slot of the same name and is a coercion site; an entry left out must
   have a default (types.md §3.3). *)
and field_constructor_call ctx span what cands (fs : N.Field_arg.t list) =
  let seen = Hashtbl.create 8 in
  let entries =
    List.map
      (fun (f : N.Field_arg.t) ->
        let name = f.N.Field_arg.name.N.Name.text in
        if Hashtbl.mem seen name then
          error f.N.Field_arg.name.N.Name.span (Printf.sprintf "the field %s is given twice" (quote name))
        else Hashtbl.add seen name ();
        let v = expr ctx f.N.Field_arg.value in
        (name, f, { arg = T.Arg.Value v; aty = v.T.Expr.ty; aspan = v.T.Expr.span; subject = false }))
      fs
  in
  let field_cands =
    List.filter (fun (s : S.t) -> match s.kind with S.Constructor { fields; _ } -> fields | _ -> false) cands
  in
  let slots_for (s : S.t) =
    let names = List.map (fun (p : S.param) -> p.name) s.params in
    if List.exists (fun (n, _, _) -> not (List.mem n names)) entries then None
    else
      Some
        (List.map
           (fun (p : S.param) ->
             List.find_map (fun (n, _, a) -> if String.equal n p.name then Some a else None) entries)
           s.params)
  in
  if List.exists (fun (_, _, a) -> Ty.contains_error a.aty) entries then invalid span
  else if field_cands = [] then begin
    error span (Printf.sprintf "%s has no field constructor" what);
    invalid span
  end
  else
    let args =
      "{" ^ String.concat "; " (List.map (fun (n, _, a) -> n ^ " = " ^ Ty.to_string a.aty) entries) ^ "}"
    in
    match report_resolution ~span ~what ~args (resolve field_cands slots_for) field_cands with
    | None -> invalid span
    | Some o ->
        request o.sig_ o.subst span;
        let converted = List.combine o.sig_.params o.converted in
        let fields =
          List.filter_map
            (fun (name, (f : N.Field_arg.t), _) ->
              let rec find i = function
                | [] -> None
                | ((p : S.param), Some (T.Arg.Value v)) :: _ when String.equal p.name name ->
                    Some { T.Field_value.name; slot = i; value = v; span = f.N.Field_arg.span }
                | _ :: rest -> find (i + 1) rest
              in
              find 0 converted)
            entries
        in
        mk
          (T.Expr.Construct_fields { ctor = verb_ref o.sig_ o.subst; fields; handler = None })
          (Ty.subst o.subst o.sig_.ret) span

(* adt.md §3.2: naming a case and supplying its one payload, which is a
   coercion site. Not a constructor verb, so there is nothing to name. *)
and case_form ctx span tid payload built open_ case (args : N.Constructor_args.t) =
  match args.N.Constructor_args.node with
  | N.Constructor_args.Positional [ a ] -> (
      let actual = actual_of ctx a in
      if Ty.contains_error actual.aty then invalid span
      else
        let s =
          {
            S.owner = S.Intrinsic "<case>";
            name = tid.Ty.name ^ "." ^ case;
            home = S.Package tid.Ty.package;
            kind = S.Function;
            generics = open_;
            params = [ { S.name = case; ty = payload; binds = None; has_default = false } ];
            ret = built;
            abort = None;
            is_mut = false;
          }
        in
        match
          report_resolution ~span ~what:(quote s.S.name) ~args:(describe_args [ actual ])
            (resolve [ s ] (positional [ actual ])) [ s ]
        with
        | None -> invalid span
        | Some o -> (
            match o.converted with
            | [ Some (T.Arg.Value v) ] -> mk (T.Expr.Case { case; payload = v }) (Ty.subst o.subst built) span
            | _ -> invalid span))
  | N.Constructor_args.Positional ps ->
      List.iter (fun a -> ignore (actual_of ctx a)) ps;
      error span
        (Printf.sprintf "a case carries exactly one payload, so `%s.%s(...)` takes one argument"
           tid.Ty.name case);
      invalid span
  | N.Constructor_args.Fields fs ->
      List.iter (fun (f : N.Field_arg.t) -> ignore (expr ctx f.N.Field_arg.value)) fs;
      error span
        (Printf.sprintf "a case is built from one positional payload, `%s.%s(value)`" tid.Ty.name case);
      invalid span

(* operators.md §2.2: the candidates are the operand types' home packages'
   operators, and nothing an import brings. Operands evaluate in written
   order and are passed in the order the desugaring gives (§2.3). *)
and operator ~flow ctx span (op : N.Operator.t) left right ~swapped handle =
  let left = expr ctx left and right = expr ctx right in
  let token = Intrinsics.operator_token op.N.Operator.node in
  let passed = if swapped then [ right; left ] else [ left; right ] in
  let actuals =
    List.map (fun (e : T.Expr.t) -> { arg = T.Arg.Value e; aty = e.T.Expr.ty; aspan = e.T.Expr.span; subject = false }) passed
  in
  if any_error actuals then (skip_handler ctx handle; (invalid span, None))
  else
    let homes = List.filter_map (fun (e : T.Expr.t) -> Signatures.home e.T.Expr.ty) passed in
    let cands =
      Hashtbl.find_all operators op.N.Operator.node |> List.rev
      |> List.filter (fun (s : S.t) -> List.mem s.home homes)
    in
    if cands = [] then begin
      error span
        (Printf.sprintf "no operator %s is declared for %s in the home package of either operand"
           (quote token) (describe_args actuals));
      skip_handler ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution ~span ~what:(Printf.sprintf "operator %s" (quote token))
          ~args:(describe_args actuals) (resolve cands (positional actuals)) cands
      with
      | None ->
          skip_handler ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call ~flow ctx ~span ~what:(quote token) o handle (fun impl args handler ->
              match List.filter_map arg_expr args with
              | [ a; b ] ->
                  let left, right = if swapped then (b, a) else (a, b) in
                  T.Expr.Op { op = op.N.Operator.node; impl; left; right; swapped; handler }
              | _ -> T.Expr.Invalid)

and flip ~flow ctx span value handle =
  let value = expr ctx value in
  let actual = { arg = T.Arg.Value value; aty = value.T.Expr.ty; aspan = value.T.Expr.span; subject = false } in
  if Ty.contains_error value.T.Expr.ty then (skip_handler ctx handle; (invalid span, None))
  else
    let homes = Option.to_list (Signatures.home value.T.Expr.ty) in
    let cands = List.filter (fun (s : S.t) -> List.mem s.home homes) !flips in
    if cands = [] then begin
      error span
        (Printf.sprintf "no operator `~` is declared for %s in its home package"
           (quote (Ty.to_string value.T.Expr.ty)));
      skip_handler ctx handle;
      (invalid span, None)
    end
    else
      match
        report_resolution ~span ~what:"operator `~`" ~args:(describe_args [ actual ])
          (resolve cands (positional [ actual ])) cands
      with
      | None ->
          skip_handler ctx handle;
          (invalid span, None)
      | Some o ->
          finish_call ~flow ctx ~span ~what:"`~`" o handle (fun impl args handler ->
              match List.filter_map arg_expr args with
              | [ v ] -> T.Expr.Flip { impl; value = v; handler }
              | _ -> T.Expr.Invalid)

(* concurrency.md §3.1, syntax.md §4.4. *)
and spawn ctx (call : N.Verb_call.t) =
  let span = call.N.Verb_call.span in
  let e, s = verb_call ~flow:false ctx call in
  (match (e.T.Expr.node, s) with
  | T.Expr.Invalid, _ -> ()
  | T.Expr.Call _, Some s ->
      if S.has_block_param s then
        error span
          (Printf.sprintf "%s takes a block, and a verb that takes a block cannot be spawned"
             (quote s.name))
  | T.Expr.Call_value _, _ -> ()
  | _ -> error span "`spawn` starts a function or method call, and this is neither");
  mk (T.Expr.Spawn e) e.T.Expr.ty span

(* ---------------------------------------------------------------------- *)
(* Match                                                                  *)
(* ---------------------------------------------------------------------- *)

and match_ ~flow ctx (m : N.Match_expr.t) =
  let span = m.N.Match_expr.span in
  let scrutinees = List.map (expr ctx) m.N.Match_expr.scrutinees in
  let shapes =
    List.map
      (fun (s : T.Expr.t) ->
        match (s.T.Expr.ty, definition s.T.Expr.ty) with
        | Ty.Error, _ -> `Unknown
        | _, Some (tid, Variant cases) -> `Variant (tid, cases)
        | _, Some (tid, Enum members) -> `Enum (tid, members)
        | t, _ ->
            error s.T.Expr.span
              (Printf.sprintf "a match dispatches on a variant or an enum, and %s is neither"
                 (quote (Ty.to_string t)));
            `Unknown)
      scrutinees
  in
  let results = { results = []; aborts = [] } in
  let arm_ctx = { ctx with ret_target = To_arm results } in
  let covered = Hashtbl.create 16 in
  let arms =
    List.map
      (fun (arm : N.Match_arm.t) ->
        let inner = push arm_ctx in
        let patterns = arm.N.Match_arm.patterns in
        if List.length patterns <> List.length shapes then
          error arm.N.Match_arm.span
            (Printf.sprintf "this arm selects %d case%s, and the match has %d scrutinee%s"
               (List.length patterns) (if List.length patterns = 1 then "" else "s")
               (List.length shapes) (if List.length shapes = 1 then "" else "s"));
        let typed =
          List.mapi
            (fun i (p : N.Match_pattern.t) ->
              let case = p.N.Match_pattern.case.N.Name.text in
              let shape = match List.nth_opt shapes i with Some s -> s | None -> `Unknown in
              let payload =
                match shape with
                | `Variant (tid, cases) -> (
                    match List.assoc_opt case cases with
                    | Some t -> Some t
                    | None ->
                        error p.N.Match_pattern.case.N.Name.span
                          (Printf.sprintf "%s has no case %s" (quote tid.Ty.name) (quote case));
                        Some Ty.Error)
                | `Enum (tid, members) ->
                    if not (List.mem case members) then
                      error p.N.Match_pattern.case.N.Name.span
                        (Printf.sprintf "%s has no member %s" (quote tid.Ty.name) (quote case));
                    (match p.N.Match_pattern.binder with
                    | Some b ->
                        error b.N.Name.span
                          (Printf.sprintf "%s is an enum member and carries no payload to bind" (quote case))
                    | None -> ());
                    None
                | `Unknown -> Some Ty.Error
              in
              let binder =
                match (p.N.Match_pattern.binder, payload) with
                | Some b, Some t -> Some (declare inner Binder b t)
                | _ -> None
              in
              { T.Pattern.binder; case; span = p.N.Match_pattern.span })
            patterns
        in
        let key = String.concat "," (List.map (fun (p : T.Pattern.t) -> p.T.Pattern.case) typed) in
        (match Hashtbl.find_opt covered key with
        | Some (first : Span.t) ->
            error arm.N.Match_arm.span
              (Printf.sprintf "%s is already covered by the arm at %s; every case is covered exactly once"
                 (quote key) (where first))
        | None -> Hashtbl.add covered key arm.N.Match_arm.span);
        let body = block_in inner arm.N.Match_arm.body in
        if not (ends ~resolve:false body.T.Block.stats) then
          error arm.N.Match_arm.body.N.Block.span "every path through a match arm ends in `return` or `abort`";
        { T.Arm.patterns = typed; body; span = arm.N.Match_arm.span })
      m.N.Match_expr.arms
  in
  (* Every combination of cases, covered (adt.md §5.2, §5.6). *)
  if List.for_all (fun s -> s <> `Unknown) shapes && List.length shapes > 0 then begin
    let cases_of = function
      | `Variant (_, cases) -> List.map fst cases
      | `Enum (_, members) -> members
      | `Unknown -> []
    in
    let combos =
      List.fold_right
        (fun shape acc -> List.concat_map (fun c -> List.map (fun rest -> c :: rest) acc) (cases_of shape))
        shapes [ [] ]
    in
    let missing = List.filter (fun combo -> not (Hashtbl.mem covered (String.concat "," combo))) combos in
    if missing <> [] then
      let shown = List.filteri (fun i _ -> i < 3) missing in
      error span
        (Printf.sprintf "the match does not cover %s%s; every case needs an arm, and there is no default"
           (String.concat ", " (List.map (fun c -> quote (String.concat ", " c)) shown))
           (if List.length missing > 3 then Printf.sprintf " (and %d more)" (List.length missing - 3) else ""))
  end;
  let ty =
    match results.results with
    | [] -> Ty.Error
    | (first, _) :: rest ->
        List.iter
          (fun (t, at) ->
            if not (Ty.equal t first) then
              error at
                (Printf.sprintf
                   "every arm of a match yields one type: this yields %s, and the first \
                    arm yields %s; an arm is not a coercion site"
                   (quote (Ty.to_string t)) (quote (Ty.to_string first))))
          rest;
        first
  in
  let abort =
    match results.aborts with
    | [] -> None
    | (first, _) :: rest ->
        List.iter
          (fun (t, at) ->
            if not (Ty.equal t first) then
              error at
                (Printf.sprintf "the arms of a match abort with one type: this is %s, and an earlier arm's is %s"
                   (quote (Ty.to_string t)) (quote (Ty.to_string first))))
          rest;
        Some first
  in
  let handler = owe_handler ~flow ctx ~what:"this match" ~span ~abort ~ok:ty m.N.Match_expr.abort_handle in
  mk (T.Expr.Match { scrutinees; arms; handler }) ty span

(* ---------------------------------------------------------------------- *)
(* Lambdas                                                                *)
(* ---------------------------------------------------------------------- *)

(* A lambda does not capture (functions.md §7.4): its body sees its own
   parameters and the package-scope names of its file, and no local of the
   verb it is written in. *)
and lambda ctx span ~this_type ~params ~ret_type ~is_mut ~body =
  let sc = type_scope ctx in
  let inner_scope = Hashtbl.create 8 in
  let this_ =
    Option.map
      (fun te ->
        let t = Types.resolve sc te in
        let local = fresh_local "this" t te.N.Type_expr.span in
        Hashtbl.replace inner_scope "this" { local; role = This };
        (t, local))
      this_type
  in
  let ps =
    List.map
      (fun (p : N.Param.t) ->
        let t = Types.param_type sc p.N.Param.type_ in
        let local = fresh_local p.N.Param.name.N.Name.text t p.N.Param.span in
        Hashtbl.replace inner_scope local.T.Local.name { local; role = Parameter };
        (t, local))
      params
  in
  let ret, abort = Types.ret_type_of sc ret_type in
  let inner =
    {
      ctx with
      scopes = [ inner_scope ];
      ret_target = To_verb { ret; abort };
      resolve_target = No_resolve;
      this_type = Option.map fst this_;
      is_mut;
      building = None;
    }
  in
  let typed = block_in inner body in
  if not (ends ~resolve:false typed.T.Block.stats) then
    error body.N.Block.span "not every path through this lambda returns; a block body returns explicitly";
  let v = { Ty.this_ = Option.map fst this_; params = List.map fst ps; ret; abort; is_mut } in
  mk
    (T.Expr.Lambda { params = List.map snd (Option.to_list this_) @ List.map snd ps; body = typed })
    (Ty.Verb v) span

(* ---------------------------------------------------------------------- *)
(* Statements                                                             *)
(* ---------------------------------------------------------------------- *)

and block_in ctx (b : N.Block.t) : T.Block.t =
  { T.Block.stats = List.map (stat ctx) b.N.Block.stats; span = b.N.Block.span }

and stat ctx (s : N.Stat.t) : T.Stat.t =
  let span = s.N.Stat.span in
  let node =
    match s.N.Stat.node with
    | N.Stat.VerbCall call -> T.Stat.Expr (fst (verb_call ~flow:false ctx call))
    | N.Stat.Spawn call -> T.Stat.Spawn (spawn ctx call)
    | N.Stat.Decl d -> local_declaration ctx d
    | N.Stat.Assign { target; value } -> assign ctx span target value
    | N.Stat.Abort value -> (
        let v = expr ctx value in
        match ctx.ret_target with
        | To_verb { abort = None; _ } ->
            error span "`abort` leaves by the abort path, and this verb declares no abort type";
            T.Stat.Abort v
        | To_verb { abort = Some a; _ } ->
            if not (Ty.assignable ~dst:a ~src:v.T.Expr.ty) then
              error v.T.Expr.span
                (Printf.sprintf "this aborts with %s, and the verb's abort type is %s"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string a)));
            T.Stat.Abort v
        | To_arm r ->
            r.aborts <- r.aborts @ [ (v.T.Expr.ty, v.T.Expr.span) ];
            T.Stat.Abort v
        | No_return ->
            error span "`abort` leaves a verb, and this is not in one";
            T.Stat.Abort v)
    | N.Stat.Ret value -> (
        match ctx.ret_target with
        | To_arm r ->
            let v = expr ~flow:true ctx value in
            escapes v;
            r.results <- r.results @ [ (v.T.Expr.ty, v.T.Expr.span) ];
            T.Stat.Return v
        | To_verb { ret; _ } ->
            let v = expr ctx value in
            escapes v;
            if not (Ty.assignable ~dst:ret ~src:v.T.Expr.ty) then
              error v.T.Expr.span
                (Printf.sprintf
                   "this returns %s, and the verb returns %s; `return` is not a coercion \
                    site, so a conversion is written out"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string ret)));
            T.Stat.Return v
        | No_return ->
            let v = expr ctx value in
            error span "`return` leaves a verb, and this is not in one";
            T.Stat.Return v)
    | N.Stat.Resolve value -> (
        let v = expr ctx value in
        match ctx.resolve_target with
        | To_handler ok ->
            if not (Ty.assignable ~dst:ok ~src:v.T.Expr.ty) then
              error v.T.Expr.span
                (Printf.sprintf
                   "this resolves %s, and the handled operation yields %s; `resolve` is \
                    not a coercion site"
                   (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string ok)));
            T.Stat.Resolve v
        | To_block y ->
            y.yields <- y.yields @ [ (v.T.Expr.ty, v.T.Expr.span) ];
            T.Stat.Resolve v
        | No_resolve ->
            error span "`resolve` finishes a handler or a block argument, and this is in neither";
            T.Stat.Resolve v)
  in
  { T.Stat.node; span }

(* A block never escapes the call it is written at (control-flow.md §2.2). *)
and escapes (v : T.Expr.t) =
  match v.T.Expr.ty with
  | Ty.Concept (Ty.Block _) -> error v.T.Expr.span "a block cannot be returned: it never escapes the call it is written at"
  | _ -> ()

(* A declaration is not a coercion site (types.md §4.2): the value has the
   declared type already. *)
and local_declaration ctx (d : N.Decl.t) =
  match d.N.Decl.node with
  | N.Decl.Var { name; type_; value } ->
      let v = expr ctx value in
      let declared = declared_type ctx type_ v.T.Expr.ty in
      Types.check_storage type_.N.Type_expr.span "a local" declared;
      if not (Ty.assignable ~dst:declared ~src:v.T.Expr.ty) then
        error v.T.Expr.span
          (Printf.sprintf
             "%s is declared %s, and its value is %s; a declaration is not a coercion \
              site, so a conversion is written out"
             (quote name.N.Name.text) (quote (Ty.to_string declared))
             (quote (Ty.to_string v.T.Expr.ty)));
      let local = declare ctx Symbol name declared in
      T.Stat.Let { local; value = v }
  | _ ->
      error d.N.Decl.span "only a symbol is declared in a body; every other declaration is at package scope";
      T.Stat.Expr (invalid d.N.Decl.span)

(* `p Pair(Int(1), Int(2))` declares `p` as the bare `Pair`, since the
   shorthand writes the constructor's name and a call carries no `< >`
   (docs/desugaring.md §2.7). A generic type named with no arguments takes
   them from the value it is declared with. *)
and declared_type ctx (te : N.Type_expr.t) (value_ty : Ty.t) =
  match te.N.Type_expr.node with
  | N.Type_expr.Path { name; generics = [] } -> (
      match Types.resolve_head (type_scope ctx) name with
      | Types.Declared d as head -> (
          match (Hashtbl.find_opt type_infos d.id, Ty.strip_guest value_ty) with
          | Some info, Ty.Named (tid, _) when info.params <> [] && tid = info.tid -> Ty.strip_guest value_ty
          | Some info, Ty.Error when info.params <> [] -> Ty.Error
          | _ -> Types.apply (type_scope ctx) te.N.Type_expr.span head name [])
      | Types.Intrinsic_type info as head when info.params <> [] -> (
          match Ty.strip_guest value_ty with
          | Ty.Intrinsic { namespace; name = n; _ } when namespace = info.namespace && n = info.name ->
              Ty.strip_guest value_ty
          | Ty.Error -> Ty.Error
          | _ -> Types.apply (type_scope ctx) te.N.Type_expr.span head name [])
      | Types.Unknown -> Ty.Error
      | head -> Types.apply (type_scope ctx) te.N.Type_expr.span head name [])
  | _ -> Types.resolve (type_scope ctx) te

(* functions.md §2.3, §2.7; packages.md §5.1. *)
and assign ctx span target value =
  let t = expr ctx target in
  let v = expr ctx value in
  let rec root (e : T.Expr.t) ~projected =
    match e.T.Expr.node with
    | T.Expr.Var (T.Name_ref.Local l) -> `Local (l, projected)
    | T.Expr.Var (T.Name_ref.Global _) -> `Global
    | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> root target ~projected:true
    | T.Expr.Invalid -> `Invalid
    | _ -> `Not_place
  in
  (match root t ~projected:false with
  | `Invalid -> ()
  | `Not_place -> error t.T.Expr.span "only a symbol, a field or a subscript can be assigned"
  | `Global -> error t.T.Expr.span "a package constant is immutable: package scope holds no mutable state"
  | `Local (l, _) -> (
      match find_local ctx l.T.Local.name with
      | Some { role = Parameter; _ } ->
          error t.T.Expr.span
            (Printf.sprintf "%s is a parameter, and a parameter is read-only" (quote l.T.Local.name))
      | Some { role = This; _ } when not ctx.is_mut ->
          error t.T.Expr.span "a method that is not `mut` may not write through `this`"
      | _ -> ()));
  if not (Ty.assignable ~dst:t.T.Expr.ty ~src:v.T.Expr.ty) then
    error v.T.Expr.span
      (Printf.sprintf
         "this assigns %s to %s; an assignment is not a coercion site, so a conversion \
          is written out"
         (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string t.T.Expr.ty)));
  ignore span;
  T.Stat.Assign { target = t; value = v }

(* ---------------------------------------------------------------------- *)
(* Subscripts                                                             *)
(* ---------------------------------------------------------------------- *)

(* A subscript declares no result type: it is the type of the place its body
   projects (functions.md §2.9), typed per set of arguments like any generic
   body. *)
and subscript_key id subst (s : S.t) =
  string_of_int id ^ ":"
  ^ String.concat "," (List.map (fun (_, a) -> Ty.arg_to_string a) (binding_args s subst))

and subscript_result (d : decl) (s : S.t) subst at =
  let key = subscript_key d.id subst s in
  match Hashtbl.find_opt subscript_results key with
  | Some (Some t) -> t
  | Some None ->
      error at "this subscript's type depends on itself";
      Ty.Error
  | None -> (
      Hashtbl.replace subscript_results key None;
      match d.kind with
      | Verb { N.Verb_decl.node = N.Verb_decl.Subscript { params; value; _ }; _ } ->
          let ctx, locals = verb_context d s subst in
          ignore params;
          let saved = !note in
          if subst <> [] then note := Some (describe_instance s subst at);
          let v = expr ctx value in
          let rec is_place (e : T.Expr.t) =
            match e.T.Expr.node with
            | T.Expr.Var (T.Name_ref.Local _) -> true
            | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> is_place target
            | T.Expr.Invalid -> true
            | _ -> false
          in
          if not (is_place v) then
            error v.T.Expr.span
              "a subscript's body is a place expression: a symbol, a field of one, or a \
               subscript of one (syntax.md §3.6)";
          note := saved;
          Hashtbl.replace subscript_results key (Some v.T.Expr.ty);
          Hashtbl.replace subscript_instances key (s, subst, locals, v);
          v.T.Expr.ty
      | _ -> Ty.Error)

(* ---------------------------------------------------------------------- *)
(* Verb bodies                                                            *)
(* ---------------------------------------------------------------------- *)

(* The context a verb's body is checked in, at one set of generic arguments:
   its parameters as locals, and the explicit `T Type` / `n Number` ones as the
   types and numbers they were given. *)
and verb_context (d : decl) (s : S.t) subst =
  let pkg = package d.package in
  let params = List.map (fun ((p : Ty.param), a) -> (p.name, a)) (binding_args s subst) in
  let scope = Hashtbl.create 8 in
  let locals =
    List.filter_map
      (fun (p : S.param) ->
        match p.binds with
        | Some _ -> None
        | None ->
            let local = fresh_local p.name (Ty.subst subst p.ty) d.span in
            let role = if p.name = "this" && S.is_method s then This else Parameter in
            Hashtbl.replace scope p.name { local; role };
            Some local)
      s.params
  in
  let this_type =
    if S.is_method s then Option.map (fun (p : S.param) -> Ty.subst subst p.ty) (List.nth_opt s.params 0)
    else None
  in
  let ctx =
    {
      file = d.file;
      package = d.package;
      is_root = pkg.is_root;
      params;
      scopes = [ scope ];
      ret_target = To_verb { ret = Ty.subst subst s.ret; abort = Option.map (Ty.subst subst) s.abort };
      resolve_target = No_resolve;
      this_type;
      is_mut = s.is_mut;
      building = (match s.kind with S.Constructor _ -> Some (Ty.subst subst s.ret) | _ -> None);
    }
  in
  (ctx, locals)

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
   default is a declaration, not a coercion site. *)
let check_defaults (d : decl) (s : S.t) =
  match d.kind with
  | Verb { N.Verb_decl.node = N.Verb_decl.Constructor { params = { N.Constructor_params.node = N.Constructor_params.Fields fs; _ }; _ }; _ } ->
      let ctx, _ = verb_context d s [] in
      let ctx = { ctx with scopes = [ Hashtbl.create 1 ]; building = None; ret_target = No_return } in
      List.iter2
        (fun (f : N.Constructor_field.t) (p : S.param) ->
          match f.N.Constructor_field.default with
          | Some default ->
              let v = expr ctx default in
              if not (Ty.assignable ~dst:p.ty ~src:v.T.Expr.ty) then
                error v.T.Expr.span
                  (Printf.sprintf "the default of %s is %s, and the entry is %s"
                     (quote p.name) (quote (Ty.to_string v.T.Expr.ty)) (quote (Ty.to_string p.ty)))
          | None -> ())
        fs s.params
  | _ -> ()

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
    | [ found ] -> coerce_value ~at:v.T.Expr.span v found
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
                   reference = Types.is_reference (Ty.Named (info.tid, List.map Types.param_arg info.params));
                   definition = type_definition info;
                 })
        | None -> (
            match Hashtbl.find_opt alias_infos d.id with
            | Some a ->
                Some (T.Decl.Alias { name = name.N.Name.text; params = a.alias_params; target = Types.alias_target a })
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
             { enum = Types.resolve (Types.scope d.file) enum; property = property.N.Name.text; ty; entries })
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
  Hashtbl.reset instance_keys;
  Hashtbl.reset instance_counts;
  Hashtbl.reset subscript_results;
  Hashtbl.reset subscript_instances;
  Queue.clear pending;
  instances := [];
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
  { T.Program.packages; instances = List.sort (fun a b -> compare (key a) (key b)) all }
