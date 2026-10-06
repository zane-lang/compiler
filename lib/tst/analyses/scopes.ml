(* Scopes: a store may not raise a value above what it names (lifetimes.md
   §1.1, §1.4, §1.7, §1.10, §1.11). An analysis over the finished TST
   (docs/design/semantics.md D1).

   Every place has a scope. A local's is the block that declares it, and a
   field's or element's is its root symbol's. A `^T` parameter is an owner of
   the body, scoped to the body's top block (§1.5). Any other parameter,
   `this` included, and a constructor's `init{ }` stand for places in the
   caller's frame: their scope is the call site, which outlives every block
   of the body.

   What a value [names] is the scopes of the owners it reaches through a
   reference: its own, if it is one, and those it carries (§1.10). A store --
   a `let`, an assignment, a field of `init{ }`, a return -- is legal only
   when every scope the stored value names outlives the destination's. A
   block outlives the blocks nested in it; the call site outlives the body.

   A local's names are the union of every value stored in it, at any path, so
   a body is walked until they stop growing and then once more to report. A
   call's result names what its arguments name, and the scope of every place
   a reference parameter mints one from, since a verb may return a reference
   rooted in any `&T` parameter (§1.7). §1.4 needs no check of its own: a
   symbol moves only in its declaring block, so the owner it moves into is
   declared there or above.

   A store the body cannot settle -- one from a parameter into a place reached
   from another -- is where the first comes to rest (§1.11), and is published
   in the verb's [summary]. Each call substitutes its arguments: what the one
   names is stored into the place the other is, and compared there. A call in
   a body can itself store a parameter into another, so summaries are
   transitive, and are computed to a fixed point before any body reports. *)

module T = Nodes
module S = Signature

(* [Param i] is the verb's parameter [i], the subject first: the caller's,
   like [Caller], but told apart from the others. *)
type scope = Caller | Global | Block of int | Param of int

(* Each parameter that comes to rest in a place reached from another, as the
   pair of their indices. *)
module Rests = Set.Make (struct
  type t = int * int

  let compare = compare
end)

(* An intrinsic has no body to summarise: `push` keeps its value in `this`. *)
let summary_of summaries (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Fixpoint.find summaries id
  | S.Intrinsic "@primitives$push" -> Rests.singleton (1, 0)
  | S.Intrinsic _ -> Rests.empty

(* A scope, and the symbol it was found through, for the message. *)
module Names = Set.Make (struct
  type t = scope * string

  let compare = compare
end)

type sink = Verb of Ty.t | Value of Ty.t * Names.t ref

type walk = {
  summaries : Rests.t Fixpoint.t;
  (* What each local names, at any path. *)
  names : (int, Names.t) Hashtbl.t;
  (* The block each local is declared in, and each block's parent. *)
  declared : (int, int) Hashtbl.t;
  parent : (int, int) Hashtbl.t;
  (* Each parameter's index; a lambda's are -1, since no summary names them. *)
  params : (int, int) Hashtbl.t;
  (* The `^T` parameters, which the body owns (§1.5). *)
  roaming : (int, unit) Hashtbl.t;
  (* Where the verb's parameters come to rest. *)
  mutable rests : Rests.t;
  mutable block : int;
  mutable fresh : int;
  (* Where a `return` sends its value: the verb's caller, or the match it is
     an arm of. A `resolve` sends its value to its handler's expression. *)
  mutable ret : sink;
  (* Where an `abort` sends its value: the verb's caller's handler, at the
     verb's abort type. *)
  mutable abort : Ty.t;
  mutable resolve : (Ty.t * Names.t ref) list;
  (* What a match's arms or a handler's `resolve` hand on, by the span of the
     expression they belong to. *)
  results : (Source.Span.t, Names.t) Hashtbl.t;
  mutable report : bool;
  mutable grew : bool;
}

(* Whether block [b] is [d] or encloses it. *)
let rec within w b d =
  b = d || match Hashtbl.find_opt w.parent d with Some p -> within w b p | None -> false

(* Whether scope [a] outlives scope [d]: lives at least as long. *)
let outlives w a d =
  match (a, d) with
  | (Caller | Global | Param _), _ -> true
  | Block _, (Caller | Global | Param _) -> false
  | Block b, Block d -> within w b d

let names_of w (l : T.Local.t) =
  Option.value ~default:Names.empty (Hashtbl.find_opt w.names l.T.Local.id)

let add w (l : T.Local.t) n =
  if not (Names.is_empty n) then begin
    let old = names_of w l in
    let now = Names.union old n in
    if not (Names.equal old now) then begin
      Hashtbl.replace w.names l.T.Local.id now;
      w.grew <- true
    end
  end

(* A `^T` parameter is declared at the top of the body, which is block 1:
   every walk numbers the body's own block first. *)
let scope_of_local w (l : T.Local.t) =
  if Hashtbl.mem w.roaming l.T.Local.id then Block 1
  else
  match Hashtbl.find_opt w.params l.T.Local.id with
  | Some i when i >= 0 -> Param i
  | Some _ -> Caller
  | None -> (
      match Hashtbl.find_opt w.declared l.T.Local.id with Some b -> Block b | None -> Caller)

let result w (e : T.Expr.t) =
  Option.value ~default:Names.empty (Hashtbl.find_opt w.results e.T.Expr.span)

let carries env t = match t with Ty.Reference _ -> true | t -> Read_only.carries env t
let keep env t n = if carries env t then n else Names.empty

(* ---------------------------------------------------------------------- *)
(* What a value names                                                     *)
(* ---------------------------------------------------------------------- *)

(* The scope of the owner at place [e], for a reference minted from it. A
   step through a reference leaves the root's tree for the one it names. *)
let rec place env w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> Names.singleton (scope_of_local w l, l.T.Local.name)
  | T.Expr.Var (T.Name_ref.Global { name; _ }) -> Names.singleton (Global, name)
  | T.Expr.Var _ -> Names.empty
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      if Ty.is_ref target.T.Expr.ty then names env w target else place env w target
  | _ -> if Ty.is_ref e.T.Expr.ty then names env w e else Names.empty

(* What a value of an expression names, before any store. *)
and names env w (e : T.Expr.t) =
  keep env e.T.Expr.ty
    (match e.T.Expr.node with
    | T.Expr.Var (T.Name_ref.Local l) -> names_of w l
    | T.Expr.Var (T.Name_ref.Global { name; _ }) -> Names.singleton (Global, name)
    | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> names env w target
    | T.Expr.Case_read { target; _ } -> names env w target
    | T.Expr.Ref inner -> if Ty.is_ref inner.T.Expr.ty then names env w inner else place env w inner
    | T.Expr.Spawn inner -> names env w inner
    | T.Expr.Array_lit items ->
        let element =
          match e.T.Expr.ty with Ty.Concept (Ty.Array_lit (t, _)) -> t | _ -> Ty.Error
        in
        List.fold_left (fun acc i -> Names.union acc (stored env w element i)) Names.empty items
    | T.Expr.Case { case; payload } ->
        stored env w (Option.value ~default:payload.T.Expr.ty (References.member_type env e.T.Expr.ty case))
          payload
    | T.Expr.Init fields -> fields_names env w e.T.Expr.ty fields
    | T.Expr.Construct_fields { ctor; fields; _ } ->
        fields_names env w
          (match Env.signature_of env ctor with Some sg -> sg.S.ret | None -> e.T.Expr.ty)
          fields
    | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } ->
        let subject, args =
          match (Env.signature_of env callee, args) with
          | Some sg, T.Arg.Value s :: rest when S.is_method sg ->
              ((if Ty.is_ref s.T.Expr.ty then names env w s else place env w s), rest)
          | _ -> (Names.empty, args)
        in
        Names.union subject (passed env w (References.param_types env callee) args)
    | T.Expr.Call_value { callee; args; _ } -> (
        match callee.T.Expr.ty with
        | Ty.Verb { Ty.this_; params; _ } -> passed env w (Option.to_list this_ @ params) args
        | _ -> Names.empty)
    | T.Expr.Op { left; right; impl; swapped; _ } ->
        let args = if swapped then [ right; left ] else [ left; right ] in
        passed env w (References.param_types env ~subject:true impl) (List.map (fun a -> T.Arg.Value a) args)
    | T.Expr.Flip { impl; value; _ } | T.Expr.Coerce { ctor = impl; value } ->
        passed env w (References.param_types env impl) [ T.Arg.Value value ]
    | _ -> Names.empty)
    (* A match's arms, and a handler's `resolve`, were walked before the
       store asked: what they handed on is kept by the expression's span. *)
    |> Names.union (keep env e.T.Expr.ty (result w e))

(* What a value names once stored where a value of type [into] goes: a
   reference minted from a place names that place's owner. *)
and stored env w into (v : T.Expr.t) =
  keep env into
    (if Ty.is_ref into && not (Ty.is_ref v.T.Expr.ty) then place env w v else names env w v)

(* A verb may hand back a reference rooted in any `&T` parameter, or one a
   parameter carries, so its result names what each argument names as that
   parameter takes it. *)
and passed env w tys args =
  let rec go tys args acc =
    match (tys, args) with
    | ty :: tys, T.Arg.Value v :: args -> go tys args (Names.union acc (stored env w ty v))
    | [], T.Arg.Value v :: args -> go [] args (Names.union acc (names env w v))
    | _ :: tys, _ :: args -> go tys args acc
    | [], _ :: args -> go [] args acc
    | _, [] -> acc
  in
  go tys args Names.empty

and fields_names env w ty fields =
  List.fold_left
    (fun acc (f : T.Field_value.t) ->
      let into = Option.value ~default:Ty.Error (References.member_type env ty f.T.Field_value.name) in
      Names.union acc (stored env w into f.T.Field_value.value))
    Names.empty fields

(* ---------------------------------------------------------------------- *)
(* Stores                                                                 *)
(* ---------------------------------------------------------------------- *)

(* §1.1: every scope a stored value names outlives the destination's. One
   parameter stored into another's place comes to rest there (§1.11), which
   only a call can settle. [via] says which call stored it. *)
let check env ?(via = "") w (at : T.Expr.t) dest (what : string) n =
  Names.iter
    (fun (o, name) ->
      match (o, dest) with
      | Param i, Param j -> if i <> j then w.rests <- Rests.add (i, j) w.rests
      | _ ->
          if w.report && not (outlives w o dest) then
            Env.error env at.T.Expr.span
              ((match dest with
               | Block _ ->
                   Printf.sprintf
                     "this stores a reference to %s, whose block ends before %s's does" (Env.quote name)
                     what
               | Caller | Global | Param _ ->
                   Printf.sprintf
                     "this stores a reference to %s in %s, which outlives the body %s is scoped to"
                     (Env.quote name) what (Env.quote name))
              ^ via))
    n

(* The scope of an assignment's destination, the local it is reached from
   unless that is a parameter, and how a message names it. *)
let rec destination w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) ->
      let o = scope_of_local w l in
      let param = Hashtbl.mem w.params l.T.Local.id in
      Some
        ( o,
          (if param then None else Some l),
          if param then "the caller's " ^ Env.quote l.T.Local.name else Env.quote l.T.Local.name )
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      destination w target
  | _ -> None

(* ---------------------------------------------------------------------- *)
(* Walking a body                                                         *)
(* ---------------------------------------------------------------------- *)

let rec expr env w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid | T.Expr.Var _ ->
      ()
  | T.Expr.Array_lit items -> List.iter (expr env w) items
  | T.Expr.Map_lit entries ->
      List.iter
        (fun (k, v) ->
          expr env w k;
          expr env w v)
        entries
  | T.Expr.Case { payload = inner; _ } | T.Expr.Field { target = inner; _ }
  | T.Expr.Map_read { target = inner; _ } | T.Expr.Ref inner | T.Expr.Spawn inner ->
      expr env w inner
  | T.Expr.Coerce { ctor; value } ->
      expr env w value;
      rest env w ctor [ T.Arg.Value value ]
  | T.Expr.Case_read { target; handler; _ } ->
      expr env w target;
      handler_block env w e handler
  | T.Expr.Init fields ->
      (* `init{ }` fills an object whose destination the body cannot see: the
         caller's, like a return (§1.1). *)
      List.iter
        (fun (f : T.Field_value.t) ->
          let v = f.T.Field_value.value in
          expr env w v;
          let into =
            Option.value ~default:Ty.Error (References.member_type env e.T.Expr.ty f.T.Field_value.name)
          in
          check env w v Caller "the object `init{ }` fills" (stored env w into v))
        fields
  | T.Expr.Construct_fields { fields; handler; _ } ->
      List.iter (fun (f : T.Field_value.t) -> expr env w f.T.Field_value.value) fields;
      opt_handler env w e handler
  | T.Expr.Match m ->
      List.iter (expr env w) m.T.Match.scrutinees;
      let acc = ref Names.empty in
      List.iter
        (fun (a : T.Arm.t) ->
          (* A binder is its scrutinee's payload, so it names what the
             scrutinee does, and is declared in the arm. *)
          let binders =
            List.concat
              (List.mapi
                 (fun i (p : T.Pattern.t) ->
                   match (List.nth_opt m.T.Match.scrutinees i, p.T.Pattern.binder) with
                   | Some s, Some b ->
                       add w b (names env w s);
                       [ b ]
                   | _, Some b -> [ b ]
                   | _, None -> [])
                 a.T.Arm.patterns)
          in
          let verb = w.ret in
          w.ret <- Value (e.T.Expr.ty, acc);
          block env ~bind:binders w a.T.Arm.body;
          w.ret <- verb)
        m.T.Match.arms;
      record w e !acc;
      opt_handler env w e m.T.Match.handler
  | T.Expr.Call { callee; args; handler; _ } | T.Expr.Construct { ctor = callee; args; handler; _ }
    ->
      List.iter (arg env w e) args;
      rest env w callee args;
      opt_handler env w e handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr env w callee;
      List.iter (arg env w e) args;
      (match callee.T.Expr.ty with Ty.Verb v -> rest_value env w v args | _ -> ());
      opt_handler env w e handler
  | T.Expr.Subscript { target; args; _ } ->
      expr env w target;
      List.iter (expr env w) args
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      expr env w left;
      expr env w right;
      let args = if swapped then [ right; left ] else [ left; right ] in
      rest env w impl (List.map (fun a -> T.Arg.Value a) args);
      opt_handler env w e handler
  | T.Expr.Flip { impl; value; handler; _ } ->
      expr env w value;
      rest env w impl [ T.Arg.Value value ];
      opt_handler env w e handler
  | T.Expr.Lambda l ->
      (* A lambda captures nothing (concurrency.md §5.2): its parameters are
         its caller's, and so is its return. *)
      (* A `^T` parameter is the body's own, declared in its top block. *)
      let roaming, lent = List.partition (fun (p : T.Local.t) -> Ty.is_roaming p.T.Local.ty) l.T.Lambda.params in
      List.iter (fun (p : T.Local.t) -> Hashtbl.replace w.params p.T.Local.id (-1)) lent;
      let ret, abort =
        match e.T.Expr.ty with
        | Ty.Verb v -> (v.Ty.ret, Option.value ~default:Ty.Error v.Ty.abort)
        | _ -> (Ty.Error, Ty.Error)
      in
      let saved = (w.ret, w.abort, w.resolve) in
      w.ret <- Verb ret;
      w.abort <- abort;
      w.resolve <- [];
      block env ~bind:roaming w l.T.Lambda.body;
      let r, a, s = saved in
      w.ret <- r;
      w.abort <- a;
      w.resolve <- s

(* §1.11: each parameter the callee keeps is stored into the place the
   argument for the other names, and the local that place is in now names it
   too. A subject is a borrow, never minted a reference for. *)
and rest env w callee args =
  let rs = summary_of w.summaries callee in
  if not (Rests.is_empty rs) then begin
    let sg = Env.signature_of env callee in
    let method_ = match sg with Some sg -> S.is_method sg | None -> false in
    let tys = References.param_types env ~subject:true callee in
    let name i =
      match sg with
      | Some sg -> (
          match List.nth_opt sg.S.params i with Some p -> Env.quote p.S.name | None -> "")
      | None -> ""
    in
    let via i j =
      match sg with
      | Some sg -> Printf.sprintf " (%s keeps %s in %s)" (Env.quote sg.S.name) (name i) (name j)
      | None -> ""
    in
    rests env w rs ~method_ tys via args
  end

(* A function type carries no summary, so a call through a function value
   that may write its subject is taken to keep every argument there
   (lifetimes.md §1.11). *)
and rest_value env w (v : Ty.verb) args =
  match v.Ty.this_ with
  | Some this_ when v.Ty.is_mut ->
      let rs = List.mapi (fun i _ -> (i + 1, 0)) v.Ty.params |> Rests.of_list in
      rests env w rs ~method_:true (this_ :: v.Ty.params)
        (fun _ _ ->
          " (a call through a function value is taken to keep every argument in its subject)")
        args
  | _ -> ()

and rests env w rs ~method_ tys via args =
  begin
    let tys = Array.of_list tys in
    let args = Array.of_list args in
    Rests.iter
      (fun (i, j) ->
        if i < Array.length args && j < Array.length args && i < Array.length tys then
          match (args.(i), args.(j)) with
          | T.Arg.Value v, T.Arg.Value d ->
              let n =
                if method_ && i = 0 then if Ty.is_ref v.T.Expr.ty then names env w v else place env w v
                else stored env w tys.(i) v
              in
              let via = via i j in
              Names.iter
                (fun (o, root) ->
                  let what =
                    match o with
                    | Caller | Param _ -> "the caller's " ^ Env.quote root
                    | Global | Block _ -> Env.quote root
                  in
                  check env ~via w v o what n)
                (place env w d);
              Option.iter (fun l -> add w l n) (root_local w d)
          | _ -> ())
      rs
  end

(* The local an argument is a place in, unless it is a parameter or the place
   is reached through a reference: that local holds what is stored there. *)
and root_local w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) when not (Hashtbl.mem w.params l.T.Local.id) -> Some l
  | T.Expr.Ref inner -> root_local w inner
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    when not (Ty.is_ref target.T.Expr.ty) ->
      root_local w target
  | _ -> None

and record w (e : T.Expr.t) n =
  let old = result w e in
  let now = Names.union old n in
  if not (Names.equal old now) then begin
    Hashtbl.replace w.results e.T.Expr.span now;
    w.grew <- true
  end

(* A block argument's `resolve` yields to the verb it is passed to
   (control-flow.md §2), which may hand that value back as its result. *)
and arg env w (call : T.Expr.t) = function
  | T.Arg.Value e -> expr env w e
  | T.Arg.Block b ->
      let acc = ref Names.empty in
      let saved = w.resolve in
      w.resolve <- [ (call.T.Expr.ty, acc) ];
      block env w b;
      w.resolve <- saved;
      record w call !acc
and opt_handler env w e = Option.iter (handler_block env w e)

and handler_block env w (e : T.Expr.t) (h : T.Handler.t) =
  (* The handler's binder holds what the call aborted with, which may carry
     a reference to whatever its arguments name, as its result may. *)
  Option.iter
    (fun (b : T.Local.t) -> add w b (names env w { e with T.Expr.ty = b.T.Local.ty }))
    h.T.Handler.binder;
  let acc = ref Names.empty in
  let saved = w.resolve in
  w.resolve <- (e.T.Expr.ty, acc) :: saved;
  block env ~bind:(Option.to_list h.T.Handler.binder) w h.T.Handler.body;
  w.resolve <- saved;
  record w e !acc

and block env ?(bind = []) w (b : T.Block.t) =
  let outer = w.block in
  w.fresh <- w.fresh + 1;
  w.block <- w.fresh;
  Hashtbl.replace w.parent w.block outer;
  List.iter (fun (l : T.Local.t) -> Hashtbl.replace w.declared l.T.Local.id w.block) bind;
  List.iter (stat env w) b.T.Block.stats;
  w.block <- outer

and stat env w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e -> expr env w e
  (* An abort is a store into the caller's frame, as a return is (§1.7). *)
  | T.Stat.Abort e ->
      expr env w e;
      check env w e Caller "the caller's handler" (stored env w w.abort e)
  | T.Stat.Let { local; value } ->
      expr env w value;
      Hashtbl.replace w.declared local.T.Local.id w.block;
      let n = stored env w local.T.Local.ty value in
      check env w value (Block w.block) (Env.quote local.T.Local.name) n;
      add w local n
  | T.Stat.Assign { target; value } -> (
      expr env w value;
      expr env w target;
      let n = stored env w target.T.Expr.ty value in
      match destination w target with
      | Some (dest, local, what) -> (
          check env w value dest what n;
          match local with Some l -> add w l n | None -> ())
      | None -> ())
  | T.Stat.Return e -> (
      expr env w e;
      match w.ret with
      | Verb ty -> check env w e Caller "the caller's result" (stored env w ty e)
      | Value (ty, acc) -> acc := Names.union !acc (stored env w ty e))
  | T.Stat.Resolve e -> (
      expr env w e;
      match w.resolve with
      | (ty, acc) :: _ -> acc := Names.union !acc (stored env w ty e)
      | [] -> ())

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh summaries =
  {
    summaries;
    names = Hashtbl.create 32;
    declared = Hashtbl.create 32;
    parent = Hashtbl.create 16;
    params = Hashtbl.create 8;
    roaming = Hashtbl.create 4;
    rests = Rests.empty;
    results = Hashtbl.create 8;
    block = 0;
    fresh = 0;
    ret = Verb Ty.Error;
    abort = Ty.Error;
    resolve = [];
    report = false;
    grew = false;
  }

(* Walk until no local names anything new, then once more if [report]. Block
   numbers restart each walk, so every walk numbers them alike. *)
let walk summaries ~report decl (ret, abort) (params : T.Local.t list) body =
  let w = fresh summaries in
  List.iteri
    (fun i (p : T.Local.t) ->
      Hashtbl.replace w.params p.T.Local.id i;
      if Ty.is_roaming p.T.Local.ty then Hashtbl.replace w.roaming p.T.Local.id ();
      Hashtbl.replace w.names p.T.Local.id (Names.singleton (Param i, p.T.Local.name)))
    params;
  let once () =
    w.fresh <- 0;
    w.block <- 0;
    w.ret <- Verb ret;
    w.abort <- Option.value ~default:Ty.Error abort;
    w.resolve <- [];
    body w
  in
  let rec settle () =
    w.grew <- false;
    once ();
    if w.grew then settle ()
  in
  settle ();
  if report then begin
    w.report <- true;
    once ()
  end;
  Fixpoint.add summaries decl w.rests

let bodies env (p : T.Program.t) =
  List.concat_map
    (fun (pkg : T.Package.t) ->
      List.filter_map
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              Some (d.T.Decl.id, (signature.S.ret, signature.S.abort), params, fun w -> block env w body)
          | _ -> None)
        pkg.T.Package.decls)
    p.T.Program.packages
  @ List.filter_map
      (fun (i : T.Instance.t) ->
        if i.T.Instance.signature.S.kind = S.Subscript then None
        else
          Some
            ( i.T.Instance.decl,
              (i.T.Instance.signature.S.ret, i.T.Instance.signature.S.abort),
              i.T.Instance.params,
              fun w -> block env w i.T.Instance.body ))
      p.T.Program.instances

(* Summaries first, to a fixed point, since verbs may call each other in a
   cycle; then each body once more to report. *)
let run env (p : T.Program.t) =
  let summaries = Fixpoint.create ~empty:Rests.empty ~union:Rests.union ~equal:Rests.equal in
  let bodies = bodies env p in
  Fixpoint.settle summaries (fun ~report ->
      List.iter (fun (d, ret, ps, b) -> walk summaries ~report d ret ps b) bodies)
