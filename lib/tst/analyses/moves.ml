(* Moves: which values a hosting store may take, and what a move leaves
   behind (lifetimes.md §1.2, §1.3, §1.6, §1.8). An analysis over the finished
   TST (docs/design/semantics.md D1).

   A reference-type value is never copied, so storing one where a host goes --
   a hosting local or field, a swallowing `T` parameter, a return, an element,
   a case payload -- moves it. What may be moved:

   - a symbol, local or parameter, named bare, and only in the block that
     declares it (§1.3), where a parameter is declared at the top of the body;
   - a verb's result, or a case form: a fresh value nothing hosts yet.

   A field, an element, a case payload, a package constant or a guest is not
   one (§1.2). A moved symbol is spent: any use of it is an error until a
   store refills it, and that store too is confined to its declaring block
   (§1.6). Passing to a `T` parameter is a move like any other (§1.8).

   Because a symbol changes between hosting and spent only in its own block,
   one walk in source order sees each use against the right state: a nested
   block can neither spend nor refill it. *)

module T = Nodes
module S = Signature

type walk = {
  (* The last block number given, shared by every walk of a run. *)
  blocks : int ref;
  (* The block each local is declared in. *)
  declared : (int, int) Hashtbl.t;
  (* Where each spent symbol was moved. *)
  spent : (int, Source.Span.t) Hashtbl.t;
  (* `this`, which a method never moves (memory.md §2.9). *)
  subjects : (int, unit) Hashtbl.t;
  (* A match binder is its case's payload (adt.md §5). *)
  binders : (int, unit) Hashtbl.t;
  mutable block : int;
  mutable ret : Ty.t;
  mutable resolve : Ty.t list;
}


(* Whether storage of type [t] hosts what is stored in it. *)
let hosting env (t : Ty.t) =
  match t with Ty.Guest _ | Ty.Param _ | Ty.Error -> false | t -> Type_decls.is_reference env t

let line (span : Source.Span.t) = span.Source.Span.start_.Lexing.pos_lnum

(* ---------------------------------------------------------------------- *)
(* Moving                                                                 *)
(* ---------------------------------------------------------------------- *)

let move env w (v : T.Expr.t) =
  let say what =
    Env.error env v.T.Expr.span
      (Printf.sprintf
         "%s is not a move-source: a host is moved only from a symbol, a verb's result or a \
          case form"
         what)
  in
  match v.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) ->
      let name = Env.quote l.T.Local.name in
      if Hashtbl.mem w.subjects l.T.Local.id then
        Env.error env v.T.Expr.span
          "`this` is the object the method was called on, and a method never moves it"
      else if Hashtbl.mem w.binders l.T.Local.id then say "a variant case's payload"
      else if (match l.T.Local.ty with Ty.Guest _ -> true | _ -> false) then
        say (name ^ ", a guest,")
      else if Hashtbl.find_opt w.declared l.T.Local.id <> Some w.block then
        Env.error env v.T.Expr.span
          (Printf.sprintf
             "%s is declared in an enclosing block, and a symbol is moved only in the block \
              that declares it"
             name)
      else if not (Hashtbl.mem w.spent l.T.Local.id) then
        Hashtbl.replace w.spent l.T.Local.id v.T.Expr.span
  | T.Expr.Var (T.Name_ref.Global _) -> say "a package constant"
  | T.Expr.Var _ -> say "this value"
  | T.Expr.Field _ -> say "a field"
  | T.Expr.Subscript _ -> say "an element of a container"
  | T.Expr.Case_read _ -> say "a variant case's payload"
  | _ -> ( match v.T.Expr.ty with Ty.Guest _ -> say "a guest" | _ -> ())

(* A value stored where a value of type [into] goes. *)
let store env w into v = if hosting env into then move env w v

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

(* [into] is where the expression's value goes: a `return` in one of its
   match arms, or a `resolve` in its handler, hands a value on to that same
   place, so whether it moves is the outer store's question. *)
let rec expr env ?(into = Ty.Error) w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match Hashtbl.find_opt w.spent l.T.Local.id with
      | Some at ->
          Env.error env e.T.Expr.span
            (Printf.sprintf
               "%s was moved on line %d, and is spent until a store refills it"
               (Env.quote l.T.Local.name) (line at))
      | None -> ())
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid | T.Expr.Var _ ->
      ()
  | T.Expr.Array_lit items ->
      let element =
        match e.T.Expr.ty with Ty.Concept (Ty.Array_lit (t, _)) -> t | _ -> Ty.Error
      in
      List.iter (value env w element) items
  | T.Expr.Map_lit entries ->
      let k, v =
        match e.T.Expr.ty with
        | Ty.Concept (Ty.Map_lit (k, v)) -> (k, v)
        | _ -> (Ty.Error, Ty.Error)
      in
      List.iter
        (fun (key, item) ->
          value env w k key;
          value env w v item)
        entries
  | T.Expr.Case { case; payload } ->
      value env w (Option.value ~default:Ty.Error (Guests.member_type env e.T.Expr.ty case)) payload
  | T.Expr.Field { target; _ } | T.Expr.Map_read { target; _ } | T.Expr.Ref target
  | T.Expr.Spawn target ->
      expr env w target
  | T.Expr.Case_read { target; handler; _ } ->
      expr env w target;
      (* A case read is a place, and so is what its handler resolves: the
         store it feeds decides whether anything moves. *)
      handler_block env w Ty.Error handler
  | T.Expr.Init fields -> fields_ env w e.T.Expr.ty fields
  | T.Expr.Construct_fields { ctor; fields; handler } ->
      fields_ env w
        (match Env.signature_of env ctor with Some sg -> sg.S.ret | None -> e.T.Expr.ty)
        fields;
      opt_handler env w into handler
  | T.Expr.Match m ->
      List.iter (expr env w) m.T.Match.scrutinees;
      List.iter
        (fun (a : T.Arm.t) ->
          let binders =
            List.filter_map (fun (p : T.Pattern.t) -> p.T.Pattern.binder) a.T.Arm.patterns
          in
          List.iter (fun (b : T.Local.t) -> Hashtbl.replace w.binders b.T.Local.id ()) binders;
          (* A `return` in an arm gives the arm's value (docs/design/semantics.md
             §9). *)
          let verb = w.ret in
          w.ret <- into;
          block env ~bind:binders w a.T.Arm.body;
          w.ret <- verb)
        m.T.Match.arms;
      opt_handler env w into m.T.Match.handler
  | T.Expr.Call { callee; args; handler } | T.Expr.Construct { ctor = callee; args; handler } ->
      let args =
        match (Env.signature_of env callee, args) with
        | Some sg, subject :: rest when S.is_method sg ->
            arg env w subject;
            rest
        | _ -> args
      in
      pass env w (Guests.param_types env callee) args;
      opt_handler env w into handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr env w callee;
      (match (callee.T.Expr.ty, args) with
      | Ty.Verb { Ty.this_ = Some _; params; _ }, subject :: rest ->
          arg env w subject;
          pass env w params rest
      | Ty.Verb { Ty.params; _ }, _ -> pass env w params args
      | _ -> List.iter (arg env w) args);
      opt_handler env w into handler
  | T.Expr.Subscript { target; impl; args } ->
      expr env w target;
      pass env w (Guests.param_types env impl) (List.map (fun a -> T.Arg.Value a) args)
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      let args = if swapped then [ right; left ] else [ left; right ] in
      let tys =
        match Env.signature_of env impl with
        (* An intrinsic operator reads its operands (docs/design/semantics.md §9). *)
        | Some { S.owner = S.Intrinsic _; _ } | None -> []
        | Some _ -> Guests.param_types env ~subject:true impl
      in
      pass env w tys (List.map (fun a -> T.Arg.Value a) args);
      opt_handler env w into handler
  | T.Expr.Flip { impl; value; handler } ->
      pass env w (read_by env impl) [ T.Arg.Value value ];
      opt_handler env w into handler
  | T.Expr.Coerce { ctor; value } -> pass env w (read_by env ctor) [ T.Arg.Value value ]
  | T.Expr.Lambda l -> lambda env w e l

(* An intrinsic operator or constructor reads what it is given. *)
and read_by env (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with S.Intrinsic _ -> [] | S.Declared _ -> Guests.param_types env r

and value env w into v =
  expr env ~into w v;
  store env w into v

(* Arguments in order, each read and then, for a `T` parameter, moved: a
   symbol passed twice is spent by the first. *)
and pass env w tys args =
  let rec go tys args =
    match (tys, args) with
    | ty :: tys, T.Arg.Value v :: args ->
        value env w ty v;
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

and fields_ env w ty fields =
  List.iter
    (fun (f : T.Field_value.t) ->
      let into = Guests.member_type env ty f.T.Field_value.name in
      value env w (Option.value ~default:Ty.Error into) f.T.Field_value.value)
    fields

and opt_handler env w ty = Option.iter (handler_block env w ty)

and handler_block env w ty (h : T.Handler.t) =
  w.resolve <- ty :: w.resolve;
  block env ~bind:(Option.to_list h.T.Handler.binder) w h.T.Handler.body;
  w.resolve <- (match w.resolve with _ :: r -> r | [] -> [])

and lambda env w (e : T.Expr.t) (l : T.Lambda.t) =
  let has_this, ret =
    match e.T.Expr.ty with
    | Ty.Verb v -> (Option.is_some v.Ty.this_, v.Ty.ret)
    | _ -> (false, Ty.Error)
  in
  (match l.T.Lambda.params with
  | this :: _ when has_this -> Hashtbl.replace w.subjects this.T.Local.id ()
  | _ -> ());
  let saved = (w.ret, w.resolve) in
  w.ret <- ret;
  w.resolve <- [];
  block env ~bind:l.T.Lambda.params w l.T.Lambda.body;
  w.ret <- fst saved;
  w.resolve <- snd saved

(* A block is its own scope: what it declares, [bind] included, is declared
   in it. *)
and block env ?(bind = []) w (b : T.Block.t) =
  let outer = w.block in
  incr w.blocks;
  w.block <- !(w.blocks);
  List.iter (fun (l : T.Local.t) -> Hashtbl.replace w.declared l.T.Local.id w.block) bind;
  List.iter (stat env w) b.T.Block.stats;
  w.block <- outer

and stat env w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e -> expr env w e
  | T.Stat.Let { local; value = v } ->
      value env w local.T.Local.ty v;
      Hashtbl.replace w.declared local.T.Local.id w.block
  | T.Stat.Assign { target; value = v } -> (
      value env w target.T.Expr.ty v;
      match target.T.Expr.node with
      | T.Expr.Var (T.Name_ref.Local l) when Hashtbl.mem w.spent l.T.Local.id ->
          (* A store into a spent symbol refills it (§1.6). *)
          if Hashtbl.find_opt w.declared l.T.Local.id = Some w.block then
            Hashtbl.remove w.spent l.T.Local.id
          else
            Env.error env target.T.Expr.span
              (Printf.sprintf
                 "%s is spent, and a store that refills it must be in the block that declares it"
                 (Env.quote l.T.Local.name))
      | T.Expr.Var _ -> ()
      | _ -> expr env w target)
  | T.Stat.Return e -> value env w w.ret e
  | T.Stat.Resolve e ->
      value env w (match w.resolve with ty :: _ -> ty | [] -> Ty.Error) e

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh blocks ret =
  {
    blocks;
    declared = Hashtbl.create 32;
    spent = Hashtbl.create 8;
    subjects = Hashtbl.create 2;
    binders = Hashtbl.create 8;
    block = 0;
    ret;
    resolve = [];
  }

let verb env blocks (sg : S.t) (params : T.Local.t list) body =
  let w = fresh blocks sg.S.ret in
  (match params with
  | this :: _ when S.is_method sg -> Hashtbl.replace w.subjects this.T.Local.id ()
  | _ -> ());
  block env ~bind:params w body

let run env (p : T.Program.t) =
  (* Blocks are numbered across the whole run. *)
  let blocks = ref 0 in
  let fresh = fresh blocks in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              verb env blocks signature params body
          (* A subscript's body is a place, not a value it hands over
             (functions.md §2.9): it is read, and moves nothing out. *)
          | T.Decl.Subscript { value = Some v; _ } -> expr env (fresh Ty.Error) v
          | T.Decl.Constant { ty; value; _ } ->
              let w = fresh ty in
              expr env w value;
              store env w ty value
          | T.Decl.Enum_map { ty; entries; _ } ->
              let w = fresh ty in
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
      let sg = i.T.Instance.signature in
      let sg = if sg.S.kind = S.Subscript then { sg with S.ret = Ty.Error } else sg in
      verb env blocks sg i.T.Instance.params i.T.Instance.body)
    p.T.Program.instances
