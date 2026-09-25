(* Where a guest may come from, and where it may be stored: the local half of
   the store rules, an analysis over the finished TST (docs/semantics.md D1).

   Three rules, each decided by the store it looks at alone:

   - A new guest is minted only from a stable place (memory.md §2.8): a
     symbol, or fields reached from one, with no `[]` and no variant case on
     the way. A value that is already a guest is copied, and may come from
     anywhere.
   - A swallowed parameter is never bound into `&` storage (memory.md §2.9).
     Its value is hosted at the call site, which has given up its host.
   - A store never goes through a guest (lifetimes.md §1.1). What lies beyond
     one belongs to a tree the path's root does not name. A guest parameter,
     `this` included, may be the root: the call site settles a store through
     it.

   The owner comparison of lifetimes.md §1.1 and where a parameter comes to
   rest (§1.11) need more than the store in hand, and are not here. *)

module T = Nodes
module S = Signature

type param_kind = This | Guest | Swallow | Borrow

type walk = {
  params : (int, string * param_kind) Hashtbl.t;
  (* A match binder is its case's payload (adt.md §5), so it is not stable. *)
  binders : (int, unit) Hashtbl.t;
  (* Where a `return` and a `resolve` send their value. *)
  mutable ret : Ty.t;
  mutable resolve : Ty.t list;
}

let quote s = "`" ^ s ^ "`"
let is_guest = function Ty.Guest _ -> true | _ -> false

(* The declared type of a struct field or a variant case, with the type's
   arguments substituted. *)
let member_type (t : Ty.t) name =
  match Ty.strip_guest t with
  | Ty.Named (tid, args) -> (
      match Hashtbl.find_opt Env.type_infos_by_id tid with
      | Some { Env.definition = Some (Env.Struct ms | Env.Variant ms); params; _ } -> (
          match List.assoc_opt name ms with
          | Some mt -> (
              let ids = List.map (fun (p : Ty.param) -> p.Ty.id) params in
              try Some (Ty.subst (List.combine ids args) mt) with Invalid_argument _ -> Some mt)
          | None -> None)
      | _ -> None)
  | _ -> None

let signature_of (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Hashtbl.find_opt Env.signatures id
  | S.Intrinsic spelling ->
      List.find_map
        (fun (_, (sg : S.t)) -> if sg.S.owner = S.Intrinsic spelling then Some sg else None)
        Intrinsics.methods

(* A parameter's types, the subject left out: a method takes its subject as a
   guest, and never mints one for it (memory.md §2.9). *)
let param_types (r : T.Verb_ref.t) =
  match signature_of r with
  | None -> []
  | Some sg ->
      let ps =
        match sg.S.params with _ :: r when S.is_method sg -> r | ps -> ps
      in
      List.map (fun (p : S.param) -> p.S.ty) ps

(* ---------------------------------------------------------------------- *)
(* The three rules                                                        *)
(* ---------------------------------------------------------------------- *)

(* Whether a path is a stable place a guest may be minted from. A path that
   starts at a value which is already a guest -- a call that returns one --
   starts at stable storage. *)
let rec source w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) when Hashtbl.mem w.binders l.T.Local.id -> `Case
  | T.Expr.Var _ | T.Expr.Invalid -> `Stable
  | T.Expr.Field { target; _ } -> source w target
  | T.Expr.Subscript _ -> `Subscript
  | T.Expr.Case_read _ -> `Case
  | _ when is_guest e.T.Expr.ty -> `Stable
  | _ -> `Temporary

let mint w (v : T.Expr.t) =
  let say = Env.error v.T.Expr.span in
  match source w v with
  | `Stable -> ()
  | `Subscript -> say "a new guest must come from a stable place, and this path crosses `[]`"
  | `Case ->
      say "a new guest must come from a stable place, and a variant case's payload is not one"
  | `Temporary -> say "a new guest names a place, and this is a temporary value"

let rec root (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> Some l
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      root target
  | _ -> None

(* A value [v] stored where a value of type [into] goes. [storage] is a field,
   an element or a case payload: somewhere a guest comes to rest, rather than
   a local or an argument. *)
let store w ?(storage = false) (into : Ty.t) (v : T.Expr.t) =
  if is_guest into then begin
    (match v.T.Expr.ty with
    | Ty.Guest _ | Ty.Error | Ty.Param _ -> ()
    | _ -> mint w v);
    if storage then
      match root v with
      | Some l -> (
          match Hashtbl.find_opt w.params l.T.Local.id with
          | Some (name, Swallow) ->
              Env.error v.T.Expr.span
                (Printf.sprintf
                   "%s swallows its argument, so it may not be bound into `&` storage; a \
                    parameter stored as a guest is declared `&`"
                   (quote name))
          | _ -> ())
      | None -> ()
  end

(* lifetimes.md §1.1: no step of a store's destination goes through a guest,
   unless it is the root and a parameter. *)
let rec through w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      let param_root =
        match target.T.Expr.node with
        | T.Expr.Var (T.Name_ref.Local l) -> Hashtbl.mem w.params l.T.Local.id
        | _ -> false
      in
      if is_guest target.T.Expr.ty && not param_root then
        Env.error target.T.Expr.span
          "a store may not go through a guest: what it names belongs to a tree this path's \
           root does not own"
      else through w target
  | _ -> ()

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

let rec expr w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid | T.Expr.Var _ ->
      ()
  | T.Expr.Array_lit items -> List.iter (expr w) items
  | T.Expr.Map_lit entries ->
      List.iter
        (fun (k, v) ->
          expr w k;
          expr w v)
        entries
  | T.Expr.Case { case; payload } ->
      expr w payload;
      Option.iter (fun t -> store w ~storage:true t payload) (member_type e.T.Expr.ty case)
  | T.Expr.Field { target; _ } | T.Expr.Map_read { target; _ } -> expr w target
  | T.Expr.Case_read { target; handler; _ } ->
      expr w target;
      handler_block w e.T.Expr.ty handler
  | T.Expr.Ref inner ->
      expr w inner;
      store w e.T.Expr.ty inner
  | T.Expr.Spawn inner -> expr w inner
  | T.Expr.Init fields -> fields_ w e.T.Expr.ty fields
  | T.Expr.Construct_fields { ctor; fields; handler } ->
      fields_ w (match signature_of ctor with Some sg -> sg.S.ret | None -> e.T.Expr.ty) fields;
      opt_handler w e.T.Expr.ty handler
  | T.Expr.Match m ->
      List.iter (expr w) m.T.Match.scrutinees;
      List.iter
        (fun (a : T.Arm.t) ->
          List.iter
            (fun (p : T.Pattern.t) ->
              Option.iter
                (fun (b : T.Local.t) -> Hashtbl.replace w.binders b.T.Local.id ())
                p.T.Pattern.binder)
            a.T.Arm.patterns;
          (* A `return` in an arm gives the arm's value (docs/semantics.md
             §9). *)
          let verb = w.ret in
          w.ret <- e.T.Expr.ty;
          block w a.T.Arm.body;
          w.ret <- verb)
        m.T.Match.arms;
      opt_handler w e.T.Expr.ty m.T.Match.handler
  | T.Expr.Call { callee; args; handler } | T.Expr.Construct { ctor = callee; args; handler } ->
      let args =
        match (signature_of callee, args) with
        | Some sg, subject :: rest when S.is_method sg ->
            arg w subject;
            rest
        | _ -> args
      in
      pass w (param_types callee) args;
      opt_handler w e.T.Expr.ty handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr w callee;
      (match callee.T.Expr.ty with
      | Ty.Verb { Ty.this_ = Some _; params; _ } -> (
          match args with
          | subject :: rest ->
              arg w subject;
              pass w params rest
          | [] -> ())
      | Ty.Verb { Ty.params; _ } -> pass w params args
      | _ -> List.iter (arg w) args);
      opt_handler w e.T.Expr.ty handler
  | T.Expr.Subscript { target; impl; args } ->
      expr w target;
      pass w (param_types impl) (List.map (fun a -> T.Arg.Value a) args)
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      let args = if swapped then [ right; left ] else [ left; right ] in
      let tys =
        match signature_of impl with
        | Some sg -> List.map (fun (p : S.param) -> p.S.ty) sg.S.params
        | None -> []
      in
      pass w tys (List.map (fun a -> T.Arg.Value a) args);
      opt_handler w e.T.Expr.ty handler
  | T.Expr.Flip { impl; value; handler } ->
      pass w (param_types impl) [ T.Arg.Value value ];
      opt_handler w e.T.Expr.ty handler
  | T.Expr.Coerce { ctor; value } -> pass w (param_types ctor) [ T.Arg.Value value ]
  | T.Expr.Lambda l -> lambda w e l

(* Arguments against the parameters they bind. *)
and pass w tys args =
  let rec go tys args =
    match (tys, args) with
    | ty :: tys, (T.Arg.Value v as a) :: args ->
        arg w a;
        store w ty v;
        go tys args
    | _ :: tys, a :: args ->
        arg w a;
        go tys args
    | [], a :: args ->
        arg w a;
        go [] args
    | _, [] -> ()
  in
  go tys args

and arg w = function T.Arg.Value e -> expr w e | T.Arg.Block b -> block w b

and fields_ w ty fields =
  List.iter
    (fun (f : T.Field_value.t) ->
      let v = f.T.Field_value.value in
      expr w v;
      Option.iter (fun t -> store w ~storage:true t v) (member_type ty f.T.Field_value.name))
    fields

and opt_handler w ty = Option.iter (handler_block w ty)

and handler_block w ty (h : T.Handler.t) =
  w.resolve <- ty :: w.resolve;
  block w h.T.Handler.body;
  w.resolve <- (match w.resolve with _ :: r -> r | [] -> [])

and lambda w (e : T.Expr.t) (l : T.Lambda.t) =
  match e.T.Expr.ty with
  | Ty.Verb v ->
      let saved = (w.ret, w.resolve) in
      params w (Option.is_some v.Ty.this_) l.T.Lambda.params;
      w.ret <- v.Ty.ret;
      w.resolve <- [];
      block w l.T.Lambda.body;
      w.ret <- fst saved;
      w.resolve <- snd saved
  | _ -> block w l.T.Lambda.body

and block w (b : T.Block.t) = List.iter (stat w) b.T.Block.stats

and stat w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e -> expr w e
  | T.Stat.Let { local; value } ->
      expr w value;
      store w local.T.Local.ty value
  | T.Stat.Assign { target; value } ->
      expr w value;
      through w target;
      let storage = match target.T.Expr.node with T.Expr.Var _ -> false | _ -> true in
      store w ~storage target.T.Expr.ty value
  | T.Stat.Return e ->
      expr w e;
      store w w.ret e
  | T.Stat.Resolve e -> (
      expr w e;
      match w.resolve with ty :: _ -> store w ty e | [] -> ())

and params w has_this (ps : T.Local.t list) =
  List.iteri
    (fun i (p : T.Local.t) ->
      let kind =
        if i = 0 && has_this then This
        else if is_guest p.T.Local.ty then Guest
        else if Types.is_reference p.T.Local.ty then Swallow
        else Borrow
      in
      Hashtbl.replace w.params p.T.Local.id (p.T.Local.name, kind))
    ps

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh ret = { params = Hashtbl.create 8; binders = Hashtbl.create 8; ret; resolve = [] }

let verb (sg : S.t) ps run =
  let w = fresh sg.S.ret in
  params w (S.is_method sg) ps;
  run w

let run (p : T.Program.t) =
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              verb signature params (fun w -> block w body)
          | T.Decl.Subscript { signature; params; value = Some v } ->
              verb signature params (fun w ->
                  expr w v;
                  store w w.ret v)
          | T.Decl.Constant { ty; value; _ } ->
              let w = fresh ty in
              expr w value;
              store w ty value
          | T.Decl.Enum_map { ty; entries; _ } ->
              let w = fresh ty in
              List.iter
                (fun (_, v) ->
                  expr w v;
                  store w ty v)
                entries
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) ->
      verb i.T.Instance.signature i.T.Instance.params (fun w -> block w i.T.Instance.body))
    p.T.Program.instances
