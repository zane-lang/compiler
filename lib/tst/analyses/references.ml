(* Where a reference may come from, and where one may be stored: the local
   half of the store rules, an analysis over the finished TST
   (docs/design/semantics.md D1).

   Two rules, each decided by the store it looks at alone:

   - A new reference is minted only from a settled place (memory.md §2.8): a
     settled symbol or package constant, or a path from one -- or from an
     `&T` parameter, or through any reference -- that passes only through
     struct fields and `ArrayRef` elements. A roaming owner may still move, a
     list's element and a variant's payload come and go, a borrow is the
     caller's for the call, and a temporary is no place at all. A value that
     is already a reference is copied, and may come from anywhere. A declared
     subscript is followed to the projection its body ends at (functions.md
     §2.9).
   - A store never goes through a reference (lifetimes.md §1.1). What lies
     beyond one belongs to a tree the path's root does not name. A reference
     parameter, or `this`, may be the root: the call site settles a store
     through it.

   Every borrow falls out of the first rule and the move rule together
   (moves.ml): it is no place to mint from and no owner to move, so it is
   never stored or returned. The scope comparison of lifetimes.md §1.1, and
   where a parameter comes to rest (§1.11), need more than the store in hand,
   and are in scopes.ml. *)

module T = Nodes
module S = Signature

type walk = {
  states : States.t;
  (* Where a `return` and a `resolve` send their value. *)
  mutable ret : Ty.t;
  mutable resolve : Ty.t list;
}

(* The declared type of a struct field or a variant case, with the type's
   arguments substituted. *)
let member_type env (t : Ty.t) name =
  match Ty.strip_mode t with
  | Ty.Named (tid, args) -> (
      match Hashtbl.find_opt env.Env.type_infos_by_id tid with
      | Some { Env.definition = Some (Env.Struct ms | Env.Variant ms); params; _ } -> (
          match List.assoc_opt name ms with
          | Some mt -> Some (Ty.instantiate params args mt)
          | None -> None)
      | _ -> None)
  | _ -> None

(* A call's parameter types, at the generic arguments it was instantiated
   with. The subject is left out unless [subject]: a method takes its subject
   as a borrow, and never mints a reference for it (memory.md §2.9). *)
let param_types env ?(subject = false) (r : T.Verb_ref.t) =
  match Env.signature_of env r with
  | None -> []
  | Some sg ->
      let ps =
        match sg.S.params with _ :: r when S.is_method sg && not subject -> r | ps -> ps
      in
      let s = List.map (fun ((p : Ty.param), a) -> (p.Ty.id, a)) r.T.Verb_ref.instance in
      List.map (fun (p : S.param) -> Ty.subst s p.S.ty) ps

(* A field constructor's entry is its parameter in the entry's slot
   (types.md §3.3). *)
let entry_type env (r : T.Verb_ref.t) (f : T.Field_value.t) =
  List.nth_opt (param_types env r) f.T.Field_value.slot

(* ---------------------------------------------------------------------- *)
(* The two rules                                                          *)
(* ---------------------------------------------------------------------- *)

let mint env w (v : T.Expr.t) =
  let say = Env.error env v.T.Expr.span in
  match (States.state w.states v, v.T.Expr.node) with
  | States.Settled, _ -> ()
  | States.Roaming, _ ->
      say
        "a new reference must come from a settled place, and this is a roaming owner, which \
         may still move; settle it first by moving it into an owner declared without `^`"
  | States.Borrowed, _
    when match States.field_path v with
         | Some (l, _) -> Hashtbl.mem w.states.States.subjects l.T.Local.id
         | None -> false ->
      say
        "`this` is a borrow, never a source of a reference; a verb that hands out a reference \
         into an object takes the object as an `&T` parameter"
  | States.Borrowed, _ ->
      say
        "a new reference must come from a settled place, and this is a borrow, which is the \
         caller's only for the call; take the parameter as `&T` to keep a reference to it"
  | States.Contingent, (T.Expr.Case_read _ | T.Expr.Var _) ->
      say
        "a new reference must come from a settled place, and a variant case's payload is \
         roaming: the variant may change case while it lives"
  | States.Contingent, T.Expr.Subscript _ ->
      say
        "a new reference must come from a settled place, and a list's element is roaming: \
         elements come and go while the list lives; an `ArrayRef`'s elements may be referenced"
  | States.Contingent, _ ->
      say "a new reference must come from a settled place, and this is part of a temporary value"
  | States.Fresh, _ -> say "a new reference names a place, and this is a temporary value"

(* A value [v] stored where a value of type [into] goes. *)
let store env w (into : Ty.t) (v : T.Expr.t) =
  if Ty.is_ref into then
    match v.T.Expr.ty with Ty.Reference _ | Ty.Error | Ty.Param _ -> () | _ -> mint env w v

(* lifetimes.md §1.1: no step of a store's destination goes through a
   reference, unless it is the root and a parameter. What a reference names
   is changed by a `mut` call on it (effects.md §4.3), which the message
   points to. *)
let rec through env w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      let param_root =
        match target.T.Expr.node with
        | T.Expr.Var (T.Name_ref.Local l) ->
            Hashtbl.mem w.states.States.params l.T.Local.id
            || Hashtbl.mem w.states.States.subjects l.T.Local.id
        | _ -> false
      in
      if Ty.is_ref target.T.Expr.ty && not param_root then
        Env.error env target.T.Expr.span
          "a store may not go through a reference, since what it names belongs to a tree this \
           path's root does not hold; change it with a `mut` method called through the reference"
      else through env w target
  | _ -> ()

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

let rec expr env w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid | T.Expr.Var _ ->
      ()
  | T.Expr.Array_lit items ->
      let element =
        match e.T.Expr.ty with Ty.Concept (Ty.Array_lit (t, _)) -> t | _ -> Ty.Error
      in
      List.iter
        (fun i ->
          expr env w i;
          store env w element i)
        items
  | T.Expr.Map_lit entries ->
      List.iter
        (fun (k, v) ->
          expr env w k;
          expr env w v)
        entries
  | T.Expr.Case { case; payload } ->
      expr env w payload;
      Option.iter (fun t -> store env w t payload) (member_type env e.T.Expr.ty case)
  | T.Expr.Field { target; _ } | T.Expr.Map_read { target; _ } -> expr env w target
  | T.Expr.Case_read { target; handler; _ } ->
      expr env w target;
      handler_block env w e.T.Expr.ty handler
  | T.Expr.Ref inner ->
      expr env w inner;
      store env w e.T.Expr.ty inner
  | T.Expr.Spawn inner -> expr env w inner
  | T.Expr.Init fields ->
      fields_ env w (fun f -> member_type env e.T.Expr.ty f.T.Field_value.name) fields
  | T.Expr.Construct_fields { ctor; fields; handler } ->
      fields_ env w (entry_type env ctor) fields;
      opt_handler env w e.T.Expr.ty handler
  | T.Expr.Match m ->
      List.iter (expr env w) m.T.Match.scrutinees;
      List.iter
        (fun (a : T.Arm.t) ->
          List.iter
            (fun (p : T.Pattern.t) -> Option.iter (States.binder w.states) p.T.Pattern.binder)
            a.T.Arm.patterns;
          (* A `return` in an arm gives the arm's value (docs/design/semantics.md
             §9). *)
          let verb = w.ret in
          w.ret <- e.T.Expr.ty;
          block env w a.T.Arm.body;
          w.ret <- verb)
        m.T.Match.arms;
      opt_handler env w e.T.Expr.ty m.T.Match.handler
  | T.Expr.Call { callee; args; handler } | T.Expr.Construct { ctor = callee; args; handler } ->
      let args =
        match (Env.signature_of env callee, args) with
        | Some sg, subject :: rest when S.is_method sg ->
            arg env w subject;
            rest
        | _ -> args
      in
      pass env w (param_types env callee) args;
      opt_handler env w e.T.Expr.ty handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr env w callee;
      (match callee.T.Expr.ty with
      | Ty.Verb { Ty.this_ = Some _; params; _ } -> (
          match args with
          | subject :: rest ->
              arg env w subject;
              pass env w params rest
          | [] -> ())
      | Ty.Verb { Ty.params; _ } -> pass env w params args
      | _ -> List.iter (arg env w) args);
      opt_handler env w e.T.Expr.ty handler
  | T.Expr.Subscript { target; impl; args } ->
      expr env w target;
      pass env w (param_types env impl) (List.map (fun a -> T.Arg.Value a) args)
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      let args = if swapped then [ right; left ] else [ left; right ] in
      pass env w (param_types env ~subject:true impl) (List.map (fun a -> T.Arg.Value a) args);
      opt_handler env w e.T.Expr.ty handler
  | T.Expr.Flip { impl; value; handler } ->
      pass env w (param_types env impl) [ T.Arg.Value value ];
      opt_handler env w e.T.Expr.ty handler
  | T.Expr.Coerce { ctor; value } -> pass env w (param_types env ctor) [ T.Arg.Value value ]
  | T.Expr.Lambda l -> lambda env w e l

(* Arguments against the parameters they bind. *)
and pass env w tys args =
  let rec go tys args =
    match (tys, args) with
    | ty :: tys, (T.Arg.Value v as a) :: args ->
        arg env w a;
        store env w ty v;
        go tys args
    | _ :: tys, a :: args ->
        arg env w a;
        go tys args
    | [], a :: args ->
        arg env w a;
        go [] args
    | _, [] -> ()
  in
  go tys args

and arg env w = function T.Arg.Value e -> expr env w e | T.Arg.Block b -> block env w b

and fields_ env w slot_type fields =
  List.iter
    (fun (f : T.Field_value.t) ->
      let v = f.T.Field_value.value in
      expr env w v;
      Option.iter (fun t -> store env w t v) (slot_type f))
    fields

and opt_handler env w ty = Option.iter (handler_block env w ty)

and handler_block env w ty (h : T.Handler.t) =
  w.resolve <- ty :: w.resolve;
  block env w h.T.Handler.body;
  w.resolve <- (match w.resolve with _ :: r -> r | [] -> [])

and lambda env w (e : T.Expr.t) (l : T.Lambda.t) =
  let has_this, ret =
    match e.T.Expr.ty with
    | Ty.Verb v -> (Option.is_some v.Ty.this_, v.Ty.ret)
    | _ -> (false, Ty.Error)
  in
  let saved = (w.ret, w.resolve) in
  params w has_this l.T.Lambda.params;
  w.ret <- ret;
  w.resolve <- [];
  block env w l.T.Lambda.body;
  w.ret <- fst saved;
  w.resolve <- snd saved

and block env w (b : T.Block.t) = List.iter (stat env w) b.T.Block.stats

and stat env w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e -> expr env w e
  | T.Stat.Let { local; value } ->
      expr env w value;
      store env w local.T.Local.ty value
  | T.Stat.Assign { target; value } ->
      expr env w value;
      expr env w target;
      through env w target;
      store env w target.T.Expr.ty value
  | T.Stat.Return e ->
      expr env w e;
      store env w w.ret e
  | T.Stat.Resolve e -> (
      expr env w e;
      match w.resolve with ty :: _ -> store env w ty e | [] -> ())

and params w has_this (ps : T.Local.t list) =
  List.iteri
    (fun i (p : T.Local.t) ->
      if i = 0 && has_this then States.subject w.states p else States.param w.states p)
    ps

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh projections ret = { states = States.create projections; ret; resolve = [] }

let verb env projections (sg : S.t) ps run =
  let w = fresh projections sg.S.ret in
  params w (S.is_method sg || sg.S.kind = S.Subscript) ps;
  run w

let run env (p : T.Program.t) =
  let projections = States.projections p in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              verb env projections signature params (fun w -> block env w body)
          | T.Decl.Subscript { signature; params; value = Some v } ->
              verb env projections signature params (fun w -> expr env w v)
          | T.Decl.Constant { ty; value; _ } ->
              let w = fresh projections ty in
              expr env w value;
              store env w ty value
          | T.Decl.Enum_map { ty; entries; _ } ->
              let w = fresh projections ty in
              List.iter
                (fun (_, v) ->
                  expr env w v;
                  store env w ty v)
                entries
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) ->
      verb env projections i.T.Instance.signature i.T.Instance.params (fun w ->
          block env w i.T.Instance.body))
    p.T.Program.instances
