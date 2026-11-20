(* A worker pool's element may hold an `&` only to a package constant or a
   capability (concurrency.md §6.4): an analysis over the finished TST
   (docs/design/semantics.md D1).

   An `&` whose target type is a capability names a capability wherever it
   was taken. Every other `&` an element holds must have been taken from a
   package constant, or from a path through a reference that was itself
   taken from one. The analysis gives each local a provenance, which covers
   every `&` the local's value holds, at any depth:

   - [Needs ps]: every such `&` names a package constant, provided the
     arguments of the enclosing verb's parameters [ps] do. [Needs] of the
     empty set is a value whose every `&` names a constant.
   - [Bad]: some `&` may name storage the program writes, and [why] says
     which.

   Provenance is flow-insensitive: a local's is the meet of every value
   bound or assigned to it anywhere in its body, so a body is walked until
   no local's provenance changes. A call's result holds only the
   references its arguments hold and references to package constants,
   since a verb mints a reference only from a reference it was passed or
   from a package constant, so the result's provenance is the meet of its
   arguments'. A `mut` call, and a call passed an `&` to a local's place,
   may store the other arguments' references in that local.

   A pool's `start` requires its element's provenance to be [Needs] of no
   parameter; [Needs ps] instead makes [ps] a requirement of the enclosing
   verb, which every call of the verb checks of its arguments. These
   requirements are per-verb summaries, settled to a fixed point
   ([Fixpoint]). A lambda's parameters, and a handler's binder, have no
   arguments to check, so their provenance is [Bad], except the `this` of a
   lambda written as a pool's step: it is an element, of which this rule
   already holds. *)

module T = Nodes
module S = Signature
module Ints = Set.Make (Int)
module Span = Source.Span

type prov = Needs of Ints.t | Bad of string

let constant = Needs Ints.empty

let meet a b =
  match (a, b) with
  | (Bad _ as x), _ | _, (Bad _ as x) -> x
  | Needs x, Needs y -> Needs (Ints.union x y)

let same a b =
  match (a, b) with Bad _, Bad _ -> true | Needs x, Needs y -> Ints.equal x y | _ -> false

let meets = List.fold_left meet constant

(* Whether a value of [t] holds an `&` that names no capability. *)
let reaches env t = Option.is_some (Type_decls.stray_reference env t)

type 'env walk = {
  env : 'env;
  summaries : Ints.t Fixpoint.t;
  report : bool;
  (* The enclosing verb, whose requirements a [Needs] adds to. *)
  decl : int option;
  provs : (int, prov) Hashtbl.t;
  (* The bodies of the lambdas written as a pool's step: such a lambda's
     `this` is an element, so this rule already holds of it. *)
  mutable steps : T.Block.t list;
  mutable changed : bool;
  mutable needs : Ints.t;
}

let line (span : Span.t) = span.Span.start_.Lexing.pos_lnum

let local w (l : T.Local.t) = Option.value ~default:constant (Hashtbl.find_opt w.provs l.T.Local.id)

let bind w (l : T.Local.t) p =
  let old = local w l in
  let now = meet old p in
  if not (same old now) then begin
    Hashtbl.replace w.provs l.T.Local.id now;
    w.changed <- true
  end

(* The parameter types of a call, subject included, at the callee's generic
   arguments. *)
let slots env (r : T.Verb_ref.t) =
  match Env.signature_of env r with
  | None -> []
  | Some sg ->
      let s = List.map (fun ((p : Ty.param), a) -> (p.Ty.id, a)) r.T.Verb_ref.instance in
      List.map (fun (p : S.param) -> Ty.subst s p.S.ty) sg.S.params

(* The parameter types of a call through the function value [f], its
   subject first, as Check.call_value passes the arguments. *)
let value_slots (f : T.Expr.t) =
  match Ty.strip_mode f.T.Expr.ty with
  | Ty.Verb { Ty.this_; params; _ } -> Option.to_list this_ @ params
  | _ -> []

(* The local a place is reached through, without passing a reference. *)
let rec root (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ } ->
      if Ty.is_ref target.T.Expr.ty then None else root target
  | T.Expr.Var (T.Name_ref.Local l) when not (Ty.is_ref l.T.Local.ty) -> Some l
  | _ -> None

(* The `return`s and `resolve`s of a block, outside its lambdas: what a
   match arm or a handler gives its expression. *)
let rec results (b : T.Block.t) =
  List.concat_map
    (fun (s : T.Stat.t) ->
      (match s.T.Stat.node with T.Stat.Return e | T.Stat.Resolve e -> [ e ] | _ -> [])
      @ List.concat_map inner (Traverse.stat_exprs s))
    b.T.Block.stats

and inner e =
  List.concat_map
    (function
      | Traverse.Same x -> inner x
      | Traverse.Arm b | Traverse.Handler b | Traverse.Block b -> results b
      | Traverse.Lambda _ -> [])
    (Traverse.parts e)

(* The provenance of [v], stored where a value of [into] goes: an `&` taken
   of [v] when [into] is a reference and [v] is not. *)
let rec into w (slot : Ty.t) (v : T.Expr.t) =
  if Ty.is_ref slot && not (Ty.is_ref v.T.Expr.ty) then taken w v else value w v

(* An `&` taken of the place [v]. *)
and taken w (v : T.Expr.t) =
  if Type_decls.is_capability w.env v.T.Expr.ty then constant
  else
    let rec from (e : T.Expr.t) =
      match e.T.Expr.node with
      | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ } ->
          if Ty.is_ref target.T.Expr.ty then value w target else from target
      | T.Expr.Var (T.Name_ref.Global _ | T.Name_ref.Intrinsic _) | T.Expr.Foreign_global _ -> constant
      | T.Expr.Var (T.Name_ref.Local l) when Ty.is_ref l.T.Local.ty -> local w l
      | T.Expr.Var (T.Name_ref.Local l) ->
          Bad
            (Printf.sprintf "the `&` taken at line %d names %s`%s`, a local of the program"
               (line v.T.Expr.span)
               (if e == v then "" else "part of ")
               l.T.Local.name)
      | _ -> Bad (Printf.sprintf "the `&` taken at line %d names no package constant" (line v.T.Expr.span))
    in
    from v

(* The provenance of the value [e]. *)
and value w (e : T.Expr.t) =
  let p = node w e in
  if reaches w.env e.T.Expr.ty then p else constant

and node w (e : T.Expr.t) =
  let args slots a =
    let rec go slots a =
      match (slots, a) with
      | s :: slots, T.Arg.Value v :: a -> into w s v :: go slots a
      | _ :: slots, T.Arg.Block _ :: a -> go slots a
      | [], T.Arg.Value v :: a -> value w v :: go [] a
      | [], T.Arg.Block _ :: a -> go [] a
      | _, [] -> []
    in
    go slots a
  in
  let given = List.concat_map (function Traverse.Arm b | Traverse.Handler b -> results b | _ -> []) in
  let resolved = meets (List.map (value w) (given (Traverse.parts e))) in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> local w l
  | T.Expr.Var _ | T.Expr.Foreign_global _ | T.Expr.Lambda _ -> constant
  | T.Expr.Call { callee; args = a; _ } | T.Expr.Construct { ctor = callee; args = a; _ } ->
      meet resolved (meets (args (slots w.env callee) a))
  | T.Expr.Call_value { callee; args = a; _ } -> meet resolved (meets (args (value_slots callee) a))
  | T.Expr.Construct_fields { ctor; fields; _ } ->
      let ss = slots w.env ctor in
      meet resolved
        (meets
           (List.map
              (fun (f : T.Field_value.t) ->
                match List.nth_opt ss f.T.Field_value.slot with
                | Some s -> into w s f.T.Field_value.value
                | None -> value w f.T.Field_value.value)
              fields))
  | T.Expr.Init fields ->
      meets
        (List.map
           (fun (f : T.Field_value.t) ->
             match References.member_type w.env e.T.Expr.ty f.T.Field_value.name with
             | Some s -> into w s f.T.Field_value.value
             | None -> value w f.T.Field_value.value)
           fields)
  | T.Expr.Case { case; payload } -> (
      match References.member_type w.env e.T.Expr.ty case with
      | Some s -> into w s payload
      | None -> value w payload)
  | T.Expr.Array_lit items ->
      let element = match e.T.Expr.ty with Ty.Concept (Ty.Array_lit (t, _)) -> t | _ -> Ty.Error in
      meets (List.map (into w element) items)
  | _ ->
      meet resolved
        (meets
           (List.filter_map (function Traverse.Same x -> Some (value w x) | _ -> None) (Traverse.parts e)))

(* A requirement on the value [p] describes: met, added to the enclosing
   verb's requirements, or reported with [say]. *)
let require w p say =
  match p with
  | Needs ps -> w.needs <- Ints.union w.needs ps
  | Bad why -> if w.report then say why

let pool_start (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Intrinsic ("@primitives$start" | "@primitives$startOn" | "@primitives$startAlone" | "@primitives$startAloneOn") ->
      true
  | _ -> false

(* A call's value arguments, by position, each with its provenance in the
   slot [ss] gives it. *)
let given w ss (a : T.Arg.t list) =
  let prov i (v : T.Expr.t) = match List.nth_opt ss i with Some s -> into w s v | None -> value w v in
  List.filter_map (function i, T.Arg.Value v -> Some (i, v, prov i v) | _ -> None) (List.mapi (fun i x -> (i, x)) a)

(* What a call may store: the arguments other than the [i]th, into the
   subject's local when the call is [mutating], and into the local of each
   place an `&` is taken of. *)
let stores w ss ~mutating given =
  let others i = meets (List.filter_map (fun (j, _, p) -> if j = i then None else Some p) given) in
  let writes = match given with (0, subject, _) :: _ when mutating -> [ (0, subject) ] | _ -> [] in
  let lent =
    List.filter_map
      (fun (i, v, _) ->
        match List.nth_opt ss i with
        | Some s when Ty.is_ref s && not (Ty.is_ref v.T.Expr.ty) -> Some (i, v)
        | _ -> None)
      given
  in
  List.iter (fun (i, v) -> Option.iter (fun l -> bind w l (others i)) (root v)) (writes @ lent)

(* The index among a verb's parameter locals of the argument at each
   position: a type or a number that picks the instance passes nothing and
   has no local (Repeats.passed). *)
let locals w (callee : T.Verb_ref.t) (a : T.Arg.t list) =
  let bound =
    match Env.signature_of w.env callee with
    | Some sg when List.length sg.S.params = List.length a ->
        List.map (fun (p : S.param) -> Option.is_some p.S.binds) sg.S.params
    | _ -> List.map (fun _ -> false) a
  in
  let next = ref 0 in
  List.map2
    (fun bound arg ->
      match arg with
      | T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> None
      | _ when bound -> None
      | _ ->
          let i = !next in
          incr next;
          Some i)
    bound a

(* A call's effects: the requirements it checks of its arguments, and the
   references it may store in the places it may write. *)
let call w (callee : T.Verb_ref.t) (a : T.Arg.t list) =
  let ss = slots w.env callee in
  let given = given w ss a in
  let mutating = match Env.signature_of w.env callee with Some sg -> sg.S.is_mut | None -> false in
  stores w ss ~mutating given;
  if pool_start callee then begin
    List.iter
      (function
        | T.Arg.Value { T.Expr.node = T.Expr.Lambda { body; _ }; _ } ->
            if not (List.memq body w.steps) then w.steps <- body :: w.steps
        | _ -> ())
      a;
    List.iter
      (fun (i, (v : T.Expr.t), p) ->
        if i = 1 then
          require w p (fun why ->
              Env.error w.env v.T.Expr.span
                (Printf.sprintf
                   "a worker pool's element may hold an `&` only to a package constant or a capability, \
                    since nothing else it could name is safe from the writes of the program while its \
                    workers run (concurrency.md §6.4), and %s"
                   why)))
      given
  end;
  match callee.T.Verb_ref.owner with
  | S.Declared id ->
      let needs = Fixpoint.read w.summaries id in
      let locals = Array.of_list (locals w callee a) in
      List.iter
        (fun (i, (v : T.Expr.t), p) ->
          let needed = match locals.(i) with Some j -> Ints.mem j needs | None -> false in
          if needed then
            require w p (fun why ->
                Env.error w.env v.T.Expr.span
                  (Printf.sprintf
                     "this argument reaches the element of a worker pool in %s, which may hold an `&` \
                      only to a package constant or a capability (concurrency.md §6.4), and %s"
                     (Env.quote callee.T.Verb_ref.name) why)))
        given
  | S.Intrinsic _ -> ()

let rec block w (b : T.Block.t) = List.iter (stat w) b.T.Block.stats

and stat w (s : T.Stat.t) =
  (match s.T.Stat.node with
  | T.Stat.Let { local; value } -> bind w local (into w local.T.Local.ty value)
  | T.Stat.Assign { target; value } ->
      Option.iter (fun l -> bind w l (into w target.T.Expr.ty value)) (root target)
  | _ -> ());
  List.iter (expr w) (Traverse.stat_exprs s)

and expr w (e : T.Expr.t) =
  (match e.T.Expr.node with
  | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } -> call w callee args
  | T.Expr.Call_value { callee; args; _ } ->
      let ss = value_slots callee in
      let mutating =
        match Ty.strip_mode callee.T.Expr.ty with
        | Ty.Verb { Ty.this_ = Some _; is_mut; _ } -> is_mut
        | _ -> false
      in
      stores w ss ~mutating (given w ss args)
  | T.Expr.Match { scrutinees; arms; _ } ->
      let p = meets (List.map (value w) scrutinees) in
      List.iter
        (fun (a : T.Arm.t) ->
          List.iter (fun (q : T.Pattern.t) -> Option.iter (fun l -> bind w l p) q.T.Pattern.binder) a.T.Arm.patterns)
        arms
  | T.Expr.Lambda { params; body } ->
      let step = List.memq body w.steps in
      List.iteri
        (fun i (l : T.Local.t) ->
          if not (step && i = 0) then
            bind w l
              (Bad
                 (Printf.sprintf "`%s` is a parameter of a lambda, whose arguments this check cannot follow"
                    l.T.Local.name)))
        params
  | _ -> ());
  let handler (h : T.Handler.t) =
    Option.iter
      (fun (l : T.Local.t) ->
        bind w l (Bad (Printf.sprintf "`%s` is a handler's binder, which this check cannot follow" l.T.Local.name)))
      h.T.Handler.binder
  in
  (match e.T.Expr.node with
  | T.Expr.Call { handler = Some h; _ }
  | T.Expr.Construct { handler = Some h; _ }
  | T.Expr.Call_value { handler = Some h; _ }
  | T.Expr.Construct_fields { handler = Some h; _ }
  | T.Expr.Op { handler = Some h; _ }
  | T.Expr.Flip { handler = Some h; _ }
  | T.Expr.Case_read { handler = h; _ } ->
      handler h
  | T.Expr.Match { handler = Some h; _ } -> handler h
  | _ -> ());
  List.iter
    (function
      | Traverse.Same x -> expr w x
      | Traverse.Arm b | Traverse.Handler b | Traverse.Block b | Traverse.Lambda b -> block w b)
    (Traverse.parts e)

(* A body walked until no local's provenance changes, then once more to
   report when [report]. *)
let walk env summaries ~report decl params (body : [ `Block of T.Block.t | `Expr of T.Expr.t ]) =
  let w =
    { env; summaries; report = false; decl; provs = Hashtbl.create 16; steps = []; changed = true; needs = Ints.empty }
  in
  List.iteri (fun i (l : T.Local.t) -> Hashtbl.replace w.provs l.T.Local.id (Needs (Ints.singleton i))) params;
  let once w = match body with `Block b -> block w b | `Expr e -> expr w e in
  while w.changed do
    w.changed <- false;
    w.needs <- Ints.empty;
    once w
  done;
  if report then once { w with report = true };
  Option.iter (fun d -> Fixpoint.add summaries d w.needs) w.decl

let run env (p : T.Program.t) =
  let summaries = Fixpoint.create ~empty:Ints.empty ~union:Ints.union ~equal:Ints.equal in
  let plain f = f () in
  let bodies =
    List.concat_map
      (fun (pkg : T.Package.t) ->
        List.concat_map
          (fun (d : T.Decl.t) ->
            match d.T.Decl.node with
            | T.Decl.Verb { body = T.Decl.Checked { params; body }; _ } ->
                [ (Some d.T.Decl.id, params, `Block body, plain) ]
            | T.Decl.Subscript { value = Some v; params; _ } -> [ (None, params, `Expr v, plain) ]
            | T.Decl.Constant { value = v; _ } -> [ (None, [], `Expr v, plain) ]
            | T.Decl.Enum_map { entries; _ } -> List.map (fun (_, v) -> (None, [], `Expr v, plain)) entries
            | _ -> [])
          pkg.T.Package.decls)
      p.T.Program.packages
    @ List.map
        (fun (i : T.Instance.t) ->
          (Some i.T.Instance.decl, i.T.Instance.params, `Block i.T.Instance.body, fun f -> Env.in_instance env i f))
        p.T.Program.instances
  in
  Fixpoint.settle summaries bodies (fun ~report (decl, params, body, within) ->
      within (fun () -> walk env summaries ~report decl params body))
