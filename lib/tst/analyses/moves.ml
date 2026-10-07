(* Moves: which values a store into an owner may take, and what a move leaves
   behind (lifetimes.md §1.2, §1.3, §1.6, §1.8). An analysis over the finished
   TST (docs/design/semantics.md D1).

   A reference-type value is never copied, so storing one where an owner goes
   -- an owning local or field, a `^T` parameter, a return, an abort, an
   element, a case payload -- moves it. What may be moved is a roaming value the store is
   entitled to consume:

   - a roaming owner named by a symbol, a local or a parameter declared
     `^T`, and only in the block that declares it (§1.3), where a parameter
     is declared at the top of the body;
   - a field of such a symbol, which leaves the symbol partly spent;
   - a verb's result, or a case form: a fresh value nothing owns yet.

   A settled owner never moves (memory.md §2.1), a borrow -- a bare
   reference-type parameter, and `this` -- is the caller's, and an element, a
   case payload, a package constant and a reference are none of the above.
   A bare reference-type parameter is a borrow, so passing to one moves
   nothing; passing to a `^T` one is a move like any other (§1.8).

   A moved symbol is spent: any use of it is an error until a store refills
   it, and that store too is confined to its declaring block (§1.6). A field
   moved out of a roaming symbol leaves that field spent, and the symbol
   spent as a whole, until the field is refilled. Because a symbol changes
   between owning and spent only in its own block, one walk in source order
   sees each use against the right state: a nested block can neither spend
   nor refill it. *)

module T = Nodes
module S = Signature

type walk = {
  (* The last block number given, shared by every walk of a run. *)
  blocks : int ref;
  (* The block each local is declared in. *)
  declared : (int, int) Hashtbl.t;
  (* Where each spent symbol was moved. *)
  spent : (int, Source.Span.t) Hashtbl.t;
  (* The fields moved out of a roaming symbol, each with where it was moved. *)
  partly : (int, (string list * Source.Span.t) list) Hashtbl.t;
  states : States.t;
  mutable block : int;
  mutable ret : Ty.t;
  (* Where an `abort` hands its value: the enclosing verb's abort type. *)
  mutable abort : Ty.t;
  mutable resolve : Ty.t list;
}

(* Whether storage of type [t] owns what is stored in it. A reference names
   an owner elsewhere, and a type parameter is filled per instance (D12). *)
let owning env (t : Ty.t) =
  match t with
  | Ty.Reference _ | Ty.Param _ | Ty.Roaming (Ty.Param _) | Ty.Error -> false
  | t -> Type_decls.is_reference env (Ty.strip_mode t)

(* A parameter of type [t] takes its argument by moving it only when it is
   written `^T`. A bare reference-type parameter is a borrow (memory.md §2.9),
   which moves nothing. *)
let taken env (t : Ty.t) = if Ty.is_roaming t then t else if owning env t then Ty.Error else t

let line (span : Source.Span.t) = span.Source.Span.start_.Lexing.pos_lnum

let dotted path = String.concat "." path

(* Whether one field path lies inside the other: reading either reads the
   moved field. *)
let overlaps a b =
  let rec prefix x y = match (x, y) with [], _ -> true | p :: x, q :: y -> p = q && prefix x y | _ -> false in
  prefix a b || prefix b a

(* ---------------------------------------------------------------------- *)
(* Moving                                                                 *)
(* ---------------------------------------------------------------------- *)

let move env w (v : T.Expr.t) =
  let say what =
    Env.error env v.T.Expr.span
      (Printf.sprintf
         "%s is not a move-source: an owner is moved only from a roaming symbol (one declared \
          `^T`), a field of one, a verb's result or a case form"
         what)
  in
  if Ty.is_ref v.T.Expr.ty then
    say "a reference, which names an owner rather than being one,"
  else
    match States.described w.states v with
    | States.Fresh, _ -> ()
    | States.Roaming, _ -> (
        match States.field_path v with
        | Some (l, path) ->
            let name = Env.quote l.T.Local.name in
            if Hashtbl.find_opt w.declared l.T.Local.id <> Some w.block then
              Env.error env v.T.Expr.span
                (Printf.sprintf
                   "%s is declared in an enclosing block, and a roaming owner is moved only in \
                    the block that declares it"
                   name)
            else if
              (* Moving out of a place that is already spent was reported
                 as a use, and changes nothing. *)
              Hashtbl.mem w.spent l.T.Local.id
              || List.exists
                   (fun (p, _) -> overlaps p path)
                   (Option.value ~default:[] (Hashtbl.find_opt w.partly l.T.Local.id))
            then ()
            else if path = [] then begin
              if not (Hashtbl.mem w.spent l.T.Local.id) then
                Hashtbl.replace w.spent l.T.Local.id v.T.Expr.span
            end
            else
              let old = Option.value ~default:[] (Hashtbl.find_opt w.partly l.T.Local.id) in
              Hashtbl.replace w.partly l.T.Local.id ((path, v.T.Expr.span) :: old)
        | None -> say "this place")
    | States.Settled, T.Expr.Var (T.Name_ref.Local l) ->
        Env.error env v.T.Expr.span
          (Printf.sprintf
             "%s is a settled owner, which may be referenced and so never moves; an owner that \
              is to move is declared `^T`"
             (Env.quote l.T.Local.name))
    | States.Settled, T.Expr.Var (T.Name_ref.Global _) -> say "a package constant"
    | States.Settled, T.Expr.Field _ ->
        say "a field of a settled owner, which is overwritten in place and never moved out,"
    | States.Settled, _ -> say "this settled place"
    | States.Borrowed, T.Expr.Var (T.Name_ref.Local l) when Hashtbl.mem w.states.States.subjects l.T.Local.id ->
        Env.error env v.T.Expr.span
          "`this` is a borrow of the object the method was called on, and a method never moves it"
    | States.Borrowed, T.Expr.Var (T.Name_ref.Local l) ->
        Env.error env v.T.Expr.span
          (Printf.sprintf
             "%s is a borrow: the caller lends it for the call, and a borrow is never moved, \
              stored or returned; a parameter that takes its argument is declared `^T`"
             (Env.quote l.T.Local.name))
    | States.Borrowed, _ -> say "a part of a borrow"
    | States.Contingent, T.Expr.Subscript _ -> say "an element of a container"
    | States.Contingent, (T.Expr.Case_read _ | T.Expr.Var _) -> say "a variant case's payload"
    | States.Contingent, _ -> say "a part of a temporary value"

(* A value stored where a value of type [into] goes. *)
let store env w into v = if owning env into then move env w v

(* ---------------------------------------------------------------------- *)
(* Spent places                                                           *)
(* ---------------------------------------------------------------------- *)

(* A use of [l] at field [path] ([] for the symbol itself). *)
let use env w (e : T.Expr.t) (l : T.Local.t) path =
  let name = Env.quote l.T.Local.name in
  match Hashtbl.find_opt w.spent l.T.Local.id with
  | Some at ->
      Env.error env e.T.Expr.span
        (Printf.sprintf "%s was moved on line %d, and is spent until a store refills it" name (line at))
  | None -> (
      let moved = Option.value ~default:[] (Hashtbl.find_opt w.partly l.T.Local.id) in
      match List.find_opt (fun (p, _) -> overlaps p path) moved with
      | Some (p, at) ->
          Env.error env e.T.Expr.span
            (if path = [] then
               Printf.sprintf
                 "%s is partly spent: its field %s was moved on line %d, and the owner is spent \
                  as a whole until a store refills that field"
                 name (Env.quote (dotted p)) (line at)
             else
               Printf.sprintf "%s was moved on line %d, and is spent until a store refills it"
                 (Env.quote (dotted (l.T.Local.name :: p))) (line at))
      | None -> ())

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

(* [into] is where the expression's value goes: a `return` in one of its
   match arms, or a `resolve` in its handler, hands a value on to that same
   place, so whether it moves is the outer store's question. *)
let rec expr env ?(into = Ty.Error) w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> use env w e l []
  | T.Expr.Field _ when Option.is_some (States.field_path e) -> (
      match States.field_path e with Some (l, path) -> use env w e l path | None -> ())
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
      value env w (Option.value ~default:Ty.Error (References.member_type env e.T.Expr.ty case)) payload
  | T.Expr.Field { target; _ } | T.Expr.Map_read { target; _ } | T.Expr.Ref target
  | T.Expr.Spawn target ->
      expr env w target
  | T.Expr.Case_read { target; handler; _ } ->
      expr env w target;
      (* A case read is a place, and so is what its handler resolves: the
         store it feeds decides whether anything moves. *)
      handler_block env w Ty.Error handler
  | T.Expr.Init fields ->
      fields_ env w (fun f -> References.member_type env e.T.Expr.ty f.T.Field_value.name) fields
  | T.Expr.Construct_fields { ctor; fields; handler } ->
      fields_ env w (References.entry_type env ctor) fields;
      opt_handler env w into handler
  | T.Expr.Match m ->
      List.iter (expr env w) m.T.Match.scrutinees;
      List.iter
        (fun (a : T.Arm.t) ->
          let binders =
            List.filter_map (fun (p : T.Pattern.t) -> p.T.Pattern.binder) a.T.Arm.patterns
          in
          List.iter (States.binder w.states) binders;
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
            (lent_by subject, rest)
        | _ -> ([], args)
      in
      let lent, args = args in
      pass env ~lent w (References.param_types env callee) args;
      opt_handler env w into handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr env w callee;
      (match (callee.T.Expr.ty, args) with
      | Ty.Verb { Ty.this_ = Some _; params; _ }, subject :: rest ->
          arg env w subject;
          pass env ~lent:(lent_by subject) w params rest
      | Ty.Verb { Ty.params; _ }, _ -> pass env w params args
      | _ -> List.iter (arg env w) args);
      opt_handler env w into handler
  | T.Expr.Subscript { target; impl; args } ->
      expr env w target;
      pass env w (References.param_types env impl) (List.map (fun a -> T.Arg.Value a) args)
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      let args = if swapped then [ right; left ] else [ left; right ] in
      pass env w (References.param_types env ~subject:true impl) (List.map (fun a -> T.Arg.Value a) args);
      opt_handler env w into handler
  | T.Expr.Flip { impl; value; handler } ->
      pass env w (read_by env impl) [ T.Arg.Value value ];
      opt_handler env w into handler
  | T.Expr.Coerce { ctor; value } -> pass env w (read_by env ctor) [ T.Arg.Value value ]
  | T.Expr.Lambda l -> lambda env w e l

(* An intrinsic constructor reads what it is given (docs/design/semantics.md §9). *)
and read_by env (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with S.Intrinsic _ -> [] | S.Declared _ -> References.param_types env r

and value env w into v =
  expr env ~into w v;
  store env w into v

(* Arguments in order, each read and then, for a `^T` parameter, moved: a
   symbol passed twice is spent by the first. An argument passed to a borrow
   is lent for the whole call (memory.md §2.9), so a later argument may not
   take the place it lends, or any place overlapping it; [lent] starts with
   the subject's. *)
and pass env ?(lent = []) w tys args =
  let lent = ref lent in
  let rec go tys args =
    match (tys, args) with
    | ty :: tys, T.Arg.Value v :: args ->
        let into = taken env ty in
        if owning env into then not_lent env !lent v;
        value env w into v;
        if not (Ty.is_roaming ty || Ty.is_ref ty) then lent := lent_by (T.Arg.Value v) @ !lent;
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

(* The place an argument lends to a borrow, as its root symbol and field
   path. *)
and lent_by = function
  | T.Arg.Value e -> (
      match States.field_path e with Some (l, path) -> [ (l, path) ] | None -> [])
  | T.Arg.Block _ -> []

and not_lent env lent (v : T.Expr.t) =
  match States.field_path v with
  | Some (l, path) -> (
      match
        List.find_opt
          (fun ((m : T.Local.t), p) -> m.T.Local.id = l.T.Local.id && overlaps p path)
          lent
      with
      | Some (m, p) ->
          Env.error env v.T.Expr.span
            (Printf.sprintf
               "this takes %s, while an earlier argument of the same call borrows %s, and a \
                borrow lasts for the whole call"
               (Env.quote (dotted (l.T.Local.name :: path)))
               (Env.quote (dotted (m.T.Local.name :: p))))
      | None -> ())
  | None -> ()

(* `init{ }` entries fill the fields of what it builds, and a field
   constructor's entries are its parameters (types.md §3.3); [slot_type]
   gives each one's type. They run in the order written, so an entry that
   moves a symbol spends it for every entry after it. *)
and fields_ env w slot_type fields =
  List.iter
    (fun (f : T.Field_value.t) ->
      let into = Option.value ~default:Ty.Error (slot_type f) in
      value env w into f.T.Field_value.value)
    fields

and opt_handler env w ty = Option.iter (handler_block env w ty)

and handler_block env w ty (h : T.Handler.t) =
  w.resolve <- ty :: w.resolve;
  block env ~bind:(Option.to_list h.T.Handler.binder) w h.T.Handler.body;
  w.resolve <- (match w.resolve with _ :: r -> r | [] -> [])

and lambda env w (e : T.Expr.t) (l : T.Lambda.t) =
  let has_this, ret, abort =
    match e.T.Expr.ty with
    | Ty.Verb v -> (Option.is_some v.Ty.this_, v.Ty.ret, Option.value ~default:Ty.Error v.Ty.abort)
    | _ -> (false, Ty.Error, Ty.Error)
  in
  params w has_this l.T.Lambda.params;
  let saved = (w.ret, w.abort, w.resolve) in
  w.ret <- ret;
  w.abort <- abort;
  w.resolve <- [];
  block env ~bind:l.T.Lambda.params w l.T.Lambda.body;
  let r, a, s = saved in
  w.ret <- r;
  w.abort <- a;
  w.resolve <- s

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
  | T.Stat.Expr e | T.Stat.Spawn e -> expr env w e
  (* An abort hands its value to the caller's handler as a return hands it
     to the caller (lifetimes.md §1.7): a store like any other. *)
  | T.Stat.Abort e -> value env w w.abort e
  | T.Stat.Let { local; value = v } ->
      value env w local.T.Local.ty v;
      Hashtbl.replace w.declared local.T.Local.id w.block
  | T.Stat.Assign { target; value = v } -> (
      value env w target.T.Expr.ty v;
      match States.field_path target with
      | Some (l, path) -> refill env w target l path
      | None -> expr env w target)
  | T.Stat.Return e -> value env w w.ret e
  | T.Stat.Resolve e ->
      value env w (match w.resolve with ty :: _ -> ty | [] -> Ty.Error) e

(* A store into a symbol, or into a field of one: an owner it holds is
   overwritten, and a spent symbol or field is refilled, which is confined
   to the symbol's declaring block (§1.6). What the store reads of the
   symbol on its way down is only where it writes, not a use. *)
and refill env w (target : T.Expr.t) (l : T.Local.t) path =
  let moved = Option.value ~default:[] (Hashtbl.find_opt w.partly l.T.Local.id) in
  let refilled = List.filter (fun (p, _) -> overlaps p path && List.length p >= List.length path) moved in
  let spent = Hashtbl.mem w.spent l.T.Local.id in
  let blocked = List.filter (fun (p, _) -> overlaps p path && List.length p < List.length path) moved in
  if spent && path <> [] then use env w target l path
  else if blocked <> [] then use env w target l path
  else if spent || refilled <> [] then
    if Hashtbl.find_opt w.declared l.T.Local.id = Some w.block then begin
      Hashtbl.remove w.spent l.T.Local.id;
      Hashtbl.replace w.partly l.T.Local.id (List.filter (fun e -> not (List.memq e refilled)) moved)
    end
    else
      Env.error env target.T.Expr.span
        (Printf.sprintf
           "%s is spent, and a store that refills it must be in the block that declares %s"
           (Env.quote (dotted (l.T.Local.name :: path))) (Env.quote l.T.Local.name))

and params w has_this (ps : T.Local.t list) =
  List.iteri
    (fun i (p : T.Local.t) ->
      if i = 0 && has_this then States.subject w.states p else States.param w.states p)
    ps

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh ?(abort = Ty.Error) projections blocks ret =
  {
    blocks;
    declared = Hashtbl.create 32;
    spent = Hashtbl.create 8;
    partly = Hashtbl.create 4;
    states = States.create projections;
    block = 0;
    ret;
    abort;
    resolve = [];
  }

let verb env projections blocks (sg : S.t) (ps : T.Local.t list) body =
  let w = fresh ?abort:sg.S.abort projections blocks sg.S.ret in
  params w (S.is_method sg || sg.S.kind = S.Subscript) ps;
  block env ~bind:ps w body

let run env (p : T.Program.t) =
  let projections = States.projections p in
  (* Blocks are numbered across the whole run. *)
  let blocks = ref 0 in
  let fresh = fresh projections blocks in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              verb env projections blocks signature params body
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
      Env.in_instance env i (fun () ->
          verb env projections blocks sg i.T.Instance.params i.T.Instance.body))
    p.T.Program.instances
