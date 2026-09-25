(* Owners: a store may not raise a value above what it names (lifetimes.md
   §1.1, §1.4, §1.7, §1.10, §1.11). An analysis over the finished TST
   (docs/semantics.md D1).

   Every place has an owner. A local is owned by the block that declares it,
   and a field or element by its root symbol's owner. A parameter, `this`
   included, and a constructor's `init{ }` stand for places in the caller's
   frame: their owner is the call site, which outlives every block of the
   body.

   What a value [names] is the owners of the hosts it reaches through a guest:
   its own, if it is one, and those it carries (§1.10). A store -- a `let`, an
   assignment, a field of `init{ }`, a return -- is legal only when every
   owner the stored value names outlives the destination's. A block outlives
   the blocks nested in it; the call site outlives the body.

   A local's names are the union of every value stored in it, at any path, so
   a body is walked until they stop growing and then once more to report. A
   call's result names what its arguments name, and the owner of every place a
   guest parameter mints one from, since a verb may return a guest rooted in
   any parameter (§1.7). §1.4 needs no check of its own: a symbol moves only in
   its declaring block, so the host it moves into is declared there or above.

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
type owner = Caller | Global | Block of int | Param of int

(* Each parameter that comes to rest in a place reached from another, as the
   pair of their indices. *)
module Rests = Set.Make (struct
  type t = int * int

  let compare = compare
end)

let summaries : (int, Rests.t) Hashtbl.t = Hashtbl.create 64
let changed = ref false

let merge id r =
  let old = Option.value ~default:Rests.empty (Hashtbl.find_opt summaries id) in
  let now = Rests.union old r in
  if not (Rests.equal old now) then begin
    Hashtbl.replace summaries id now;
    changed := true
  end

(* An intrinsic has no body to summarise: `push` keeps its value in `this`. *)
let summary_of (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Option.value ~default:Rests.empty (Hashtbl.find_opt summaries id)
  | S.Intrinsic "@primitives$push" -> Rests.singleton (1, 0)
  | S.Intrinsic _ -> Rests.empty

(* An owner, and the symbol it was found through, for the message. *)
module Names = Set.Make (struct
  type t = owner * string

  let compare = compare
end)

type sink = Verb of Ty.t | Value of Ty.t * Names.t ref

type walk = {
  (* What each local names, at any path. *)
  names : (int, Names.t) Hashtbl.t;
  (* The block each local is declared in, and each block's parent. *)
  declared : (int, int) Hashtbl.t;
  parent : (int, int) Hashtbl.t;
  (* Each parameter's index; a lambda's are -1, since no summary names them. *)
  params : (int, int) Hashtbl.t;
  (* Where the verb's parameters come to rest. *)
  mutable rests : Rests.t;
  mutable block : int;
  mutable fresh : int;
  (* Where a `return` sends its value: the verb's caller, or the match it is
     an arm of. A `resolve` sends its value to its handler's expression. *)
  mutable ret : sink;
  mutable resolve : (Ty.t * Names.t ref) list;
  (* What a match's arms or a handler's `resolve` hand on, by the span of the
     expression they belong to. *)
  results : (Source.Span.t, Names.t) Hashtbl.t;
  mutable report : bool;
  mutable grew : bool;
}

let quote s = "`" ^ s ^ "`"

(* Whether block [b] is [d] or encloses it. *)
let rec within w b d =
  b = d || match Hashtbl.find_opt w.parent d with Some p -> within w b p | None -> false

(* Whether owner [a] outlives owner [d]: lives at least as long. *)
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

let owner_of_local w (l : T.Local.t) =
  match Hashtbl.find_opt w.params l.T.Local.id with
  | Some i when i >= 0 -> Param i
  | Some _ -> Caller
  | None -> (
      match Hashtbl.find_opt w.declared l.T.Local.id with Some b -> Block b | None -> Caller)

let result w (e : T.Expr.t) =
  Option.value ~default:Names.empty (Hashtbl.find_opt w.results e.T.Expr.span)

let carries t = match t with Ty.Guest _ -> true | t -> Read_only.carries t
let keep t n = if carries t then n else Names.empty
let is_guest = function Ty.Guest _ -> true | _ -> false

(* ---------------------------------------------------------------------- *)
(* What a value names                                                     *)
(* ---------------------------------------------------------------------- *)

(* The owner of the host at place [e], for a guest minted from it. A step
   through a guest leaves the root's tree for the one the guest names. *)
let rec host w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> Names.singleton (owner_of_local w l, l.T.Local.name)
  | T.Expr.Var (T.Name_ref.Global { name; _ }) -> Names.singleton (Global, name)
  | T.Expr.Var _ -> Names.empty
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      if is_guest target.T.Expr.ty then names w target else host w target
  | _ -> if is_guest e.T.Expr.ty then names w e else Names.empty

(* What a value of an expression names, before any store. *)
and names w (e : T.Expr.t) =
  keep e.T.Expr.ty
    (match e.T.Expr.node with
    | T.Expr.Var (T.Name_ref.Local l) -> names_of w l
    | T.Expr.Var (T.Name_ref.Global { name; _ }) -> Names.singleton (Global, name)
    | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } -> names w target
    | T.Expr.Case_read { target; _ } -> names w target
    | T.Expr.Ref inner -> if is_guest inner.T.Expr.ty then names w inner else host w inner
    | T.Expr.Spawn inner -> names w inner
    | T.Expr.Array_lit items ->
        let element =
          match e.T.Expr.ty with Ty.Concept (Ty.Array_lit (t, _)) -> t | _ -> Ty.Error
        in
        List.fold_left (fun acc i -> Names.union acc (stored w element i)) Names.empty items
    | T.Expr.Case { case; payload } ->
        stored w (Option.value ~default:payload.T.Expr.ty (Guests.member_type e.T.Expr.ty case))
          payload
    | T.Expr.Init fields -> fields_names w e.T.Expr.ty fields
    | T.Expr.Construct_fields { ctor; fields; _ } ->
        fields_names w
          (match Guests.signature_of ctor with Some sg -> sg.S.ret | None -> e.T.Expr.ty)
          fields
    | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } ->
        let subject, args =
          match (Guests.signature_of callee, args) with
          | Some sg, T.Arg.Value s :: rest when S.is_method sg ->
              ((if is_guest s.T.Expr.ty then names w s else host w s), rest)
          | _ -> (Names.empty, args)
        in
        Names.union subject (passed w (Guests.param_types callee) args)
    | T.Expr.Call_value { callee; args; _ } -> (
        match callee.T.Expr.ty with
        | Ty.Verb { Ty.this_; params; _ } -> passed w (Option.to_list this_ @ params) args
        | _ -> Names.empty)
    | T.Expr.Op { left; right; impl; swapped; _ } ->
        let args = if swapped then [ right; left ] else [ left; right ] in
        passed w (Guests.param_types ~subject:true impl) (List.map (fun a -> T.Arg.Value a) args)
    | T.Expr.Flip { impl; value; _ } | T.Expr.Coerce { ctor = impl; value } ->
        passed w (Guests.param_types impl) [ T.Arg.Value value ]
    | _ -> Names.empty)
    (* A match's arms, and a handler's `resolve`, were walked before the
       store asked: what they handed on is kept by the expression's span. *)
    |> Names.union (keep e.T.Expr.ty (result w e))

(* What a value names once stored where a value of type [into] goes: a
   guest minted from a place names that place's host. *)
and stored w into (v : T.Expr.t) =
  keep into
    (if is_guest into && not (is_guest v.T.Expr.ty) then host w v else names w v)

(* A verb may hand back a guest rooted in any parameter, so its result
   names what each argument names as that parameter takes it. *)
and passed w tys args =
  let rec go tys args acc =
    match (tys, args) with
    | ty :: tys, T.Arg.Value v :: args -> go tys args (Names.union acc (stored w ty v))
    | [], T.Arg.Value v :: args -> go [] args (Names.union acc (names w v))
    | _ :: tys, _ :: args -> go tys args acc
    | [], _ :: args -> go [] args acc
    | _, [] -> acc
  in
  go tys args Names.empty

and fields_names w ty fields =
  List.fold_left
    (fun acc (f : T.Field_value.t) ->
      let into = Option.value ~default:Ty.Error (Guests.member_type ty f.T.Field_value.name) in
      Names.union acc (stored w into f.T.Field_value.value))
    Names.empty fields

(* ---------------------------------------------------------------------- *)
(* Stores                                                                 *)
(* ---------------------------------------------------------------------- *)

(* §1.1: every owner a stored value names outlives the destination's. One
   parameter stored into another's place comes to rest there (§1.11), which
   only a call can settle. [via] says which call stored it. *)
let check ?(via = "") w (at : T.Expr.t) dest (what : string) n =
  Names.iter
    (fun (o, name) ->
      match (o, dest) with
      | Param i, Param j -> if i <> j then w.rests <- Rests.add (i, j) w.rests
      | _ ->
          if w.report && not (outlives w o dest) then
            Env.error at.T.Expr.span
              ((match dest with
               | Block _ ->
                   Printf.sprintf
                     "this stores a guest to %s, whose block ends before %s's does" (quote name)
                     what
               | Caller | Global | Param _ ->
                   Printf.sprintf
                     "this stores a guest to %s in %s, which outlives the body %s is owned by"
                     (quote name) what (quote name))
              ^ via))
    n

(* The owner of an assignment's destination, the local it is reached from
   unless that is a parameter, and how a message names it. *)
let rec destination w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) ->
      let o = owner_of_local w l in
      let param = Hashtbl.mem w.params l.T.Local.id in
      Some
        ( o,
          (if param then None else Some l),
          if param then "the caller's " ^ quote l.T.Local.name else quote l.T.Local.name )
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      destination w target
  | _ -> None

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
  | T.Expr.Case { payload = inner; _ } | T.Expr.Field { target = inner; _ }
  | T.Expr.Map_read { target = inner; _ } | T.Expr.Ref inner | T.Expr.Spawn inner ->
      expr w inner
  | T.Expr.Coerce { ctor; value } ->
      expr w value;
      rest w ctor [ T.Arg.Value value ]
  | T.Expr.Case_read { target; handler; _ } ->
      expr w target;
      handler_block w e handler
  | T.Expr.Init fields ->
      (* `init{ }` fills an object whose destination the body cannot see: the
         caller's, like a return (§1.1). *)
      List.iter
        (fun (f : T.Field_value.t) ->
          let v = f.T.Field_value.value in
          expr w v;
          let into =
            Option.value ~default:Ty.Error (Guests.member_type e.T.Expr.ty f.T.Field_value.name)
          in
          check w v Caller "the object `init{ }` fills" (stored w into v))
        fields
  | T.Expr.Construct_fields { fields; handler; _ } ->
      List.iter (fun (f : T.Field_value.t) -> expr w f.T.Field_value.value) fields;
      opt_handler w e handler
  | T.Expr.Match m ->
      List.iter (expr w) m.T.Match.scrutinees;
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
                       add w b (names w s);
                       [ b ]
                   | _, Some b -> [ b ]
                   | _, None -> [])
                 a.T.Arm.patterns)
          in
          let verb = w.ret in
          w.ret <- Value (e.T.Expr.ty, acc);
          block ~bind:binders w a.T.Arm.body;
          w.ret <- verb)
        m.T.Match.arms;
      record w e !acc;
      opt_handler w e m.T.Match.handler
  | T.Expr.Call { callee; args; handler; _ } | T.Expr.Construct { ctor = callee; args; handler; _ }
    ->
      List.iter (arg w e) args;
      rest w callee args;
      opt_handler w e handler
  | T.Expr.Call_value { callee; args; handler } ->
      expr w callee;
      List.iter (arg w e) args;
      opt_handler w e handler
  | T.Expr.Subscript { target; args; _ } ->
      expr w target;
      List.iter (expr w) args
  | T.Expr.Op { left; right; impl; swapped; handler; _ } ->
      expr w left;
      expr w right;
      let args = if swapped then [ right; left ] else [ left; right ] in
      rest w impl (List.map (fun a -> T.Arg.Value a) args);
      opt_handler w e handler
  | T.Expr.Flip { impl; value; handler; _ } ->
      expr w value;
      rest w impl [ T.Arg.Value value ];
      opt_handler w e handler
  | T.Expr.Lambda l ->
      (* A lambda captures nothing (concurrency.md §5.2): its parameters are
         its caller's, and so is its return. *)
      List.iter
        (fun (p : T.Local.t) -> Hashtbl.replace w.params p.T.Local.id (-1))
        l.T.Lambda.params;
      let ret = match e.T.Expr.ty with Ty.Verb v -> v.Ty.ret | _ -> Ty.Error in
      let saved = (w.ret, w.resolve) in
      w.ret <- Verb ret;
      w.resolve <- [];
      block w l.T.Lambda.body;
      w.ret <- fst saved;
      w.resolve <- snd saved

(* §1.11: each parameter the callee keeps is stored into the place the
   argument for the other names, and the local that place is in now names it
   too. A subject is taken as a guest, never minted one for. *)
and rest w callee args =
  let rs = summary_of callee in
  if not (Rests.is_empty rs) then begin
    let sg = Guests.signature_of callee in
    let method_ = match sg with Some sg -> S.is_method sg | None -> false in
    let tys = Array.of_list (Guests.param_types ~subject:true callee) in
    let args = Array.of_list args in
    let name i =
      match sg with
      | Some sg -> (
          match List.nth_opt sg.S.params i with Some p -> quote p.S.name | None -> "")
      | None -> ""
    in
    Rests.iter
      (fun (i, j) ->
        if i < Array.length args && j < Array.length args && i < Array.length tys then
          match (args.(i), args.(j)) with
          | T.Arg.Value v, T.Arg.Value d ->
              let n =
                if method_ && i = 0 then if is_guest v.T.Expr.ty then names w v else host w v
                else stored w tys.(i) v
              in
              let via =
                match sg with
                | Some sg ->
                    Printf.sprintf " (%s keeps %s in %s)" (quote sg.S.name) (name i) (name j)
                | None -> ""
              in
              Names.iter
                (fun (o, root) ->
                  let what =
                    match o with
                    | Caller | Param _ -> "the caller's " ^ quote root
                    | Global | Block _ -> quote root
                  in
                  check ~via w v o what n)
                (host w d);
              Option.iter (fun l -> add w l n) (root_local w d)
          | _ -> ())
      rs
  end

(* The local an argument is a place in, unless it is a parameter or the place
   is reached through a guest: that local holds what is stored there. *)
and root_local w (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) when not (Hashtbl.mem w.params l.T.Local.id) -> Some l
  | T.Expr.Ref inner -> root_local w inner
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    when not (is_guest target.T.Expr.ty) ->
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
and arg w (call : T.Expr.t) = function
  | T.Arg.Value e -> expr w e
  | T.Arg.Block b ->
      let acc = ref Names.empty in
      let saved = w.resolve in
      w.resolve <- [ (call.T.Expr.ty, acc) ];
      block w b;
      w.resolve <- saved;
      record w call !acc
and opt_handler w e = Option.iter (handler_block w e)

and handler_block w (e : T.Expr.t) (h : T.Handler.t) =
  let acc = ref Names.empty in
  let saved = w.resolve in
  w.resolve <- (e.T.Expr.ty, acc) :: saved;
  block ~bind:(Option.to_list h.T.Handler.binder) w h.T.Handler.body;
  w.resolve <- saved;
  record w e !acc

and block ?(bind = []) w (b : T.Block.t) =
  let outer = w.block in
  w.fresh <- w.fresh + 1;
  w.block <- w.fresh;
  Hashtbl.replace w.parent w.block outer;
  List.iter (fun (l : T.Local.t) -> Hashtbl.replace w.declared l.T.Local.id w.block) bind;
  List.iter (stat w) b.T.Block.stats;
  w.block <- outer

and stat w (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e -> expr w e
  | T.Stat.Let { local; value } ->
      expr w value;
      Hashtbl.replace w.declared local.T.Local.id w.block;
      let n = stored w local.T.Local.ty value in
      check w value (Block w.block) (quote local.T.Local.name) n;
      add w local n
  | T.Stat.Assign { target; value } -> (
      expr w value;
      expr w target;
      let n = stored w target.T.Expr.ty value in
      match destination w target with
      | Some (dest, local, what) -> (
          check w value dest what n;
          match local with Some l -> add w l n | None -> ())
      | None -> ())
  | T.Stat.Return e -> (
      expr w e;
      match w.ret with
      | Verb ty -> check w e Caller "the caller's result" (stored w ty e)
      | Value (ty, acc) -> acc := Names.union !acc (stored w ty e))
  | T.Stat.Resolve e -> (
      expr w e;
      match w.resolve with
      | (ty, acc) :: _ -> acc := Names.union !acc (stored w ty e)
      | [] -> ())

(* ---------------------------------------------------------------------- *)
(* Declarations                                                           *)
(* ---------------------------------------------------------------------- *)

let fresh () =
  {
    names = Hashtbl.create 32;
    declared = Hashtbl.create 32;
    parent = Hashtbl.create 16;
    params = Hashtbl.create 8;
    rests = Rests.empty;
    results = Hashtbl.create 8;
    block = 0;
    fresh = 0;
    ret = Verb Ty.Error;
    resolve = [];
    report = false;
    grew = false;
  }

(* Walk until no local names anything new, then once more if [report]. Block
   numbers restart each walk, so every walk numbers them alike. *)
let walk ~report decl ret (params : T.Local.t list) body =
  let w = fresh () in
  List.iteri
    (fun i (p : T.Local.t) ->
      Hashtbl.replace w.params p.T.Local.id i;
      Hashtbl.replace w.names p.T.Local.id (Names.singleton (Param i, p.T.Local.name)))
    params;
  let once () =
    w.fresh <- 0;
    w.block <- 0;
    w.ret <- Verb ret;
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
  merge decl w.rests

let bodies (p : T.Program.t) =
  List.concat_map
    (fun (pkg : T.Package.t) ->
      List.filter_map
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              Some (d.T.Decl.id, signature.S.ret, params, fun w -> block w body)
          | _ -> None)
        pkg.T.Package.decls)
    p.T.Program.packages
  @ List.filter_map
      (fun (i : T.Instance.t) ->
        if i.T.Instance.signature.S.kind = S.Subscript then None
        else
          Some
            ( i.T.Instance.decl,
              i.T.Instance.signature.S.ret,
              i.T.Instance.params,
              fun w -> block w i.T.Instance.body ))
      p.T.Program.instances

(* Summaries first, to a fixed point, since verbs may call each other in a
   cycle; then each body once more to report. *)
let run (p : T.Program.t) =
  Hashtbl.reset summaries;
  let bodies = bodies p in
  let each report = List.iter (fun (d, ret, ps, b) -> walk ~report d ret ps b) bodies in
  let rec settle () =
    changed := false;
    each false;
    if !changed then settle ()
  in
  settle ();
  each true
