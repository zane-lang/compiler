(* Borrows a call keeps quiet (memory.md §2.9.1, adt.md §5.1): an analysis
   over the finished TST (docs/design/semantics.md D1).

   A call's borrows are its subject and every argument it passes to a borrow:
   a bare parameter, or a `^T` filled with a value type. Each lends its place
   for the whole call, so nothing else in the same call may write a place
   that overlaps one: not the subject of a `mut` call, for a borrow argument;
   not a block argument, for the subject or a borrow argument; and not the
   evaluation of an argument written after a borrow argument. The subject is
   located after the arguments run (memory.md §2.12), so an argument that
   writes the subject's place is no conflict.

   A `match` binder names its payload for the whole arm, so an arm with a
   binder may not write a place that overlaps its scrutinee, other than
   through the binder.

   A part of a call writes a place when it assigns to it, makes it the
   subject of a `!` call, or moves an owner out of it, anywhere inside that
   part except a lambda's body, which has a frame of its own. A `!` call also
   writes whatever its subject reaches through `&` fields, and passing on a
   block parameter writes whatever the caller's block does.

   A place reached through an `&` is found where the checker can follow it.
   An `&` symbol stands for every place it is initialized from or repointed
   to anywhere in the body. An `&T` parameter is a root of its own, apart
   from the subject and every block parameter: where the body relies on
   that, the verb's [summary] records the pair, and each call checks it with
   the arguments it passes, which may record it in the caller in turn. Any
   other place reached through an `&` -- an `&` field, a call's result -- may
   be any place of its type. *)

module T = Nodes
module S = Signature

(* A place, as [Spawns] has it. *)
type place = Spawns.place

(* A claim on storage: the places it may be, when the checker can follow it
   ([None]: any place of its type), and the type of what it holds. [runs] is
   [Some i] for running block parameter [i], which writes whatever the
   caller's block does; [-1] for a block the checker cannot name. *)
type claim = { expr : T.Expr.t; at : place list option; ty : Ty.t; runs : int option; behind : bool }

(* Each `&T` parameter that must not overlap the subject (index 0) or a
   block parameter, as the pair of their indices. *)
module Needs = Set.Make (struct
  type t = int * int

  let compare = compare
end)

let summary_of summaries (r : T.Verb_ref.t) =
  match r.T.Verb_ref.owner with
  | S.Declared id -> Fixpoint.find summaries id
  | S.Intrinsic _ -> Needs.empty

(* What a parameter is to the body checking it. *)
type role = Subject | Ref of int | Block_param of int | Other

(* A path that steps through an `&` field reaches a tree its root does not
   name, so where it lands is not known from the root. *)
let rec through_reference (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    -> (
      match (target.T.Expr.ty, target.T.Expr.node) with
      | Ty.Reference _, T.Expr.Var _ -> false
      | Ty.Reference _, _ -> true
      | _ -> through_reference target)
  | _ -> false

let same_place (a : place) (b : place) =
  a.Spawns.local.T.Local.id = b.Spawns.local.T.Local.id && a.Spawns.path = b.Spawns.path

let union a b =
  match (a, b) with
  | Some xs, Some ys ->
      Some (xs @ List.filter (fun y -> not (List.exists (same_place y) xs)) ys)
  | _ -> None

let equal_places a b =
  match (a, b) with
  | Some xs, Some ys ->
      List.length xs = List.length ys && List.for_all (fun x -> List.exists (same_place x) ys) xs
  | None, None -> true
  | _ -> false

(* Every binding of an `&` local in [start], its declaration and each
   repointing, in any order. *)
let bindings start =
  let found = ref [] in
  let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) =
    (match s.T.Stat.node with
    | T.Stat.Let { local = { T.Local.ty = Ty.Reference _; id; _ }; value } ->
        found := (id, value) :: !found
    | T.Stat.Assign
        { target = { T.Expr.ty = Ty.Reference _; node = T.Expr.Var (T.Name_ref.Local l); _ }; value }
      ->
        found := (l.T.Local.id, value) :: !found
    | _ -> ());
    List.iter expr (Exits.stat_exprs s)
  and expr (e : T.Expr.t) =
    List.iter
      (function
        | Exits.Same x -> expr x
        | Exits.Arm b | Exits.Handler b | Exits.Block b | Exits.Lambda b -> block b)
      (Exits.parts e)
  in
  (match start with `Block b -> block b | `Expr e -> expr e);
  List.rev !found

(* The types a value of type [t] reaches through `&` fields, at any depth. *)
let behind_references env t =
  let rec go seen acc t =
    if List.exists (Ty.equal t) seen then acc
    else
      List.fold_left
        (fun acc m ->
          match m with
          | Ty.Reference r ->
              let acc = if List.exists (Ty.equal r) acc then acc else r :: acc in
              go (t :: seen) acc r
          | m -> go (t :: seen) acc m)
        acc (Spawns.members env t)
  in
  go [] [] (Ty.strip_mode t)

(* How a pair of claims stands: apart, overlapping, or apart only if the
   caller keeps the listed pairs apart. *)
type verdict = Apart | Clash of bool | Apart_if of (int * int) list

let walk env summaries ~report ~(params : (T.Local.t * role) list) start =
  let role_of (l : T.Local.t) =
    match List.find_opt (fun ((p : T.Local.t), _) -> p.T.Local.id = l.T.Local.id) params with
    | Some (_, r) -> r
    | None -> Other
  in
  let is_param (l : T.Local.t) =
    List.exists (fun ((p : T.Local.t), _) -> p.T.Local.id = l.T.Local.id) params
  in
  (* Where each `&` local may point: every place any of its bindings names,
     to a fixed point, since one may be bound from another. *)
  let origins : (int, place list option) Hashtbl.t = Hashtbl.create 8 in
  let rec resolve (p : place) =
    let l = p.Spawns.local in
    match (l.T.Local.ty, role_of l) with
    | Ty.Reference _, Ref _ -> Some [ p ]
    | Ty.Reference _, _ -> (
        match Hashtbl.find_opt origins l.T.Local.id with
        | Some (Some os) ->
            Some (List.map (fun (o : place) -> { o with Spawns.path = o.Spawns.path @ p.Spawns.path }) os)
        | _ -> None)
    | _ -> Some [ p ]
  (* The places a value of reference type, or a place minted from, names. *)
  and origin (e : T.Expr.t) =
    match (e.T.Expr.ty, e.T.Expr.node) with
    | Ty.Reference _, T.Expr.Var (T.Name_ref.Local l) -> resolve { Spawns.local = l; path = [] }
    | Ty.Reference _, _ -> None
    | _ -> if through_reference e then None else Option.bind (Spawns.place_of e) resolve
  in
  let binds = bindings start in
  List.iter (fun (id, _) -> Hashtbl.replace origins id (Some [])) binds;
  (* A binding from a path through itself grows without end; after a few
     rounds what still grows may point anywhere. *)
  let rec settle n =
    let grew = ref false in
    List.iter
      (fun (id, v) ->
        let old = match Hashtbl.find_opt origins id with Some o -> o | None -> Some [] in
        let now = if n = 0 then None else union old (origin v) in
        if not (equal_places old now) then begin
          Hashtbl.replace origins id now;
          grew := true
        end)
      binds;
    if !grew && n > 0 then settle (n - 1)
  in
  settle 8;
  (* A claim on the place [e] names, when it names one. An `&` field written
     or borrowed is the object it names, wherever that is. *)
  let claim (e : T.Expr.t) =
    match Spawns.place_of e with
    | None -> None
    | Some p ->
        let at =
          match (e.T.Expr.ty, e.T.Expr.node) with
          | Ty.Reference _, T.Expr.Var _ -> resolve p
          | Ty.Reference _, _ -> None
          | _ -> if through_reference e then None else resolve p
        in
        Some { expr = e; at; ty = e.T.Expr.ty; runs = None; behind = false }
  in
  (* The object an argument passed to an `&T` parameter names. *)
  let named (e : T.Expr.t) = { expr = e; at = origin e; ty = e.T.Expr.ty; runs = None; behind = false } in
  let describe (c : claim) =
    match Spawns.place_of c.expr with
    | Some p when c.behind -> "what " ^ Spawns.describe p ^ " reaches through an `&` field"
    | Some p -> Spawns.describe p
    | None -> "this place"
  in
  (* Where [p] may be part of something the caller passed for [q]. *)
  let root_pair (x : place) (y : place) =
    match (role_of x.Spawns.local, role_of y.Spawns.local) with
    | Ref i, Subject -> Some (i, 0)
    | Subject, Ref i -> Some (i, 0)
    | _ -> None
  in
  (* The locals the body owns: what it declares, and its `^T` parameters. *)
  let owned = Hashtbl.create 16 in
  List.iter
    (fun ((l : T.Local.t), _) -> if Ty.is_roaming l.T.Local.ty then Hashtbl.replace owned l.T.Local.id ())
    params;
  (let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
   and stat (s : T.Stat.t) =
     (match s.T.Stat.node with
     | T.Stat.Let { local; _ } -> (
         match local.T.Local.ty with
         | Ty.Reference _ -> ()
         | _ -> Hashtbl.replace owned local.T.Local.id ())
     | _ -> ());
     List.iter expr (Exits.stat_exprs s)
   and expr (e : T.Expr.t) =
     List.iter
       (function
         | Exits.Same x -> expr x
         | Exits.Arm b | Exits.Handler b | Exits.Block b | Exits.Lambda b -> block b)
       (Exits.parts e)
   in
   match start with `Block b -> block b | `Expr e -> expr e);
  (* A place the body owns cannot sit inside what the caller passed, and
     the subject and a borrowed parameter are the caller's to keep apart
     from what the call writes. *)
  let covered (l : T.Local.t) =
    Hashtbl.mem owned l.T.Local.id
    || (is_param l && match role_of l with Subject | Other -> true | _ -> false)
  in
  (* Whether the known claim [c] may hold, or be part of, an object of type
     [r] the checker cannot place: [r] inside it, or [r] on its path, or, for
     a place the body does not own, anything that can hold it. *)
  let meets (c : claim) r =
    let t = Ty.strip_mode c.ty in
    Spawns.contains env t r
    || List.exists (fun pt -> Ty.equal pt r) (Spawns.chain c.expr)
    ||
    match c.at with
    | Some ps ->
        List.exists (fun (p : place) -> not (covered p.Spawns.local)) ps && Spawns.contains env r t
    | None -> true
  in
  let verdict (a : claim) (b : claim) =
    let by_type () =
      let a_ty = Ty.strip_mode a.ty and b_ty = Ty.strip_mode b.ty in
      match (a.at, b.at) with
      | Some _, None -> meets a b_ty
      | None, Some _ -> meets b a_ty
      | _ -> Spawns.contains env a_ty b_ty || Spawns.contains env b_ty a_ty
    in
    let running i (c : claim) =
      match c.at with
      | None -> Clash false
      | Some ps ->
          let needs =
            List.filter_map
              (fun (p : place) ->
                match role_of p.Spawns.local with Ref j -> Some (j, i) | _ -> None)
              ps
          in
          if needs = [] then Apart
          else if i < 0 || List.exists (fun (j, _) -> j < 0) needs then Clash false
          else Apart_if needs
    in
    match (a.runs, b.runs) with
    | Some _, Some _ -> Apart
    | Some i, None -> running i b
    | None, Some i -> running i a
    | None, None -> (
        match (a.at, b.at) with
        | Some xs, Some ys ->
            let pairs = List.concat_map (fun x -> List.map (fun y -> (x, y)) ys) xs in
            if List.exists (fun (x, y) -> Spawns.overlap x y) pairs then Clash (List.length pairs = 1)
            else if not (by_type ()) then Apart
            else (
              match List.filter_map (fun (x, y) -> root_pair x y) pairs with
              | [] -> Apart
              | needs -> Apart_if needs)
        | _ -> if by_type () then Clash false else Apart)
  in
  let needs = ref Needs.empty in
  (* Settles a verdict: a clash is reported, a condition becomes the body's
     own need. *)
  let settle_verdict v on_clash =
    match v with
    | Apart -> ()
    | Clash sure -> if report then on_clash (if sure then "overlaps" else "may overlap")
    | Apart_if ps -> List.iter (fun p -> needs := Needs.add p !needs) ps
  in
  (* The parameters of a call, by position, and its subject's when it has
     one, with what the callee needs kept apart. *)
  let params_of (e : T.Expr.t) =
    match e.T.Expr.node with
    | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } -> (
        match Env.signature_of env callee with
        | Some sg ->
            (* A type or number given to a binding parameter picks the
               instance, which takes no parameter for it (generics.md §5.3),
               so the rest line up with the instance's, as summaries count
               them. *)
            let pairs =
              if List.length sg.S.params = List.length args then
                List.filter
                  (fun ((p : S.param), a) ->
                    Option.is_none p.S.binds
                    && match a with T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> false | _ -> true)
                  (List.combine sg.S.params args)
              else []
            in
            Some
              ( S.is_method sg,
                sg.S.is_mut,
                List.map (fun ((p : S.param), _) -> p.S.ty) pairs,
                List.map snd pairs,
                summary_of summaries callee )
        | None -> None)
    | T.Expr.Call_value { callee = { T.Expr.ty = Ty.Verb v; _ }; args; _ } ->
        (* A function type carries no summary, so a call through a value
           keeps every `&T` argument apart from the `mut` subject and every
           block argument. *)
        let tys = Option.to_list v.Ty.this_ @ v.Ty.params in
        let refs =
          List.filter_map (fun (i, t) -> match t with Ty.Reference _ -> Some i | _ -> None)
            (List.mapi (fun i t -> (i, t)) tys)
        in
        let blocks =
          List.filter_map (fun (i, t) -> match t with Ty.Concept Ty.Block -> Some i | _ -> None)
            (List.mapi (fun i t -> (i, t)) tys)
        in
        let others =
          (if Option.is_some v.Ty.this_ && v.Ty.is_mut then [ 0 ] else []) @ blocks
        in
        let needs =
          List.fold_left
            (fun acc p -> List.fold_left (fun acc o -> Needs.add (p, o) acc) acc others)
            Needs.empty refs
        in
        Some (Option.is_some v.Ty.this_, v.Ty.is_mut, tys, args, needs)
    | T.Expr.Op { impl = { owner = S.Declared _; _ } as impl; left; right; swapped; _ } -> (
        match Env.signature_of env impl with
        | Some sg ->
            let tys = List.map (fun (p : S.param) -> p.S.ty) sg.S.params in
            (* The operands in written order, each with its parameter. *)
            let tys = if swapped then List.rev tys else tys in
            Some (false, false, tys, [ T.Arg.Value left; T.Arg.Value right ], Needs.empty)
        | None -> None)
    | _ -> None
  in
  (* Whether an argument of type [arg] passed to a parameter of type [param]
     is a borrow. *)
  let borrows (param : Ty.t) (arg : Ty.t) =
    match param with
    | Ty.Reference _ | Ty.Concept _ | Ty.Verb _ -> false
    | Ty.Roaming _ -> not (Type_decls.is_reference env (Ty.strip_mode arg))
    | _ -> ( match arg with Ty.Reference _ -> false | _ -> true)
  in
  (* Running a block parameter passed as an argument. *)
  let runs_of (a : T.Arg.t) =
    match a with
    | T.Arg.Value ({ T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } as v) -> (
        match (l.T.Local.ty, role_of l) with
        | _, Block_param i -> Some { expr = v; at = Some []; ty = l.T.Local.ty; runs = Some i; behind = false }
        (* A lambda's block parameter: no summary names it. *)
        | Ty.Concept Ty.Block, _ -> Some { expr = v; at = Some []; ty = l.T.Local.ty; runs = Some (-1); behind = false }
        | _ -> None)
    | _ -> None
  in
  (* What a `!` call on [subject] writes: its place, and what it reaches
     through `&` fields. *)
  let subject_writes (subject : T.Expr.t) =
    match claim subject with
    | None -> []
    | Some c ->
        let held = match c.ty with Ty.Reference r -> r | t -> Ty.strip_mode t in
        c
        :: List.map
             (fun ty -> { expr = subject; at = None; ty; runs = None; behind = true })
             (behind_references env held)
  in
  (* Every place a part writes, reached through anything but a lambda. *)
  let rec writes_expr acc (e : T.Expr.t) =
    let acc =
      match params_of e with
      | Some (_, true, _, T.Arg.Value subject :: _, _) -> subject_writes subject @ acc
      | _ -> acc
    in
    let acc =
      match (e.T.Expr.node, params_of e) with
      | (T.Expr.Call _ | T.Expr.Construct _ | T.Expr.Call_value _), Some (_, _, tys, args, _)
        when List.length tys = List.length args ->
          List.fold_left2
            (fun acc ty a ->
              let acc = match runs_of a with Some r -> r :: acc | None -> acc in
              match (ty, a) with
              | Ty.Roaming _, T.Arg.Value v -> moved acc v
              | _ -> acc)
            acc tys args
      | _ -> acc
    in
    List.fold_left writes_part acc (Exits.parts e)
  and writes_part acc = function
    | Exits.Same x -> writes_expr acc x
    | Exits.Arm b | Exits.Handler b | Exits.Block b -> writes_block acc b
    | Exits.Lambda _ -> acc
  and writes_block acc (b : T.Block.t) = List.fold_left writes_stat acc b.T.Block.stats
  and writes_stat acc (s : T.Stat.t) =
    match s.T.Stat.node with
    | T.Stat.Assign { target; value } -> (
        let acc = writes_expr acc value in
        (* What locates the destination runs too: `xs[ys!grow()] = v`. *)
        let acc = List.fold_left writes_part acc (Exits.parts target) in
        let acc = match target.T.Expr.ty with Ty.Reference _ -> acc | _ -> moved acc value in
        match (target.T.Expr.ty, target.T.Expr.node) with
        (* Repointing a reference writes no place it names. *)
        | Ty.Reference _, T.Expr.Var _ -> acc
        (* An `&` field repointed writes the field's own storage, inside
           the object that holds it. *)
        | Ty.Reference _, (T.Expr.Field { target = holder; _ } | T.Expr.Subscript { target = holder; _ }) -> (
            match Spawns.place_of target with
            | Some p ->
                let at = if through_reference target then None else resolve p in
                { expr = target; at; ty = holder.T.Expr.ty; runs = None; behind = false } :: acc
            | None -> acc)
        | _ -> ( match claim target with Some c -> c :: acc | None -> acc))
    | T.Stat.Let { local = { T.Local.ty = Ty.Reference _; _ }; value } | T.Stat.Return value ->
        writes_expr acc value
    | T.Stat.Let { value; _ } -> moved (writes_expr acc value) value
    | _ -> List.fold_left writes_expr acc (Exits.stat_exprs s)
  (* An owner read from a place into owning storage moves out of it. *)
  and moved acc (v : T.Expr.t) =
    match v.T.Expr.ty with
    | Ty.Reference _ -> acc
    | t when Type_decls.is_reference env (Ty.strip_mode t) -> (
        match claim v with Some c -> c :: acc | None -> acc)
    | _ -> acc
  in
  let report_write (w : claim) (b : claim) why overlaps =
    Env.error env w.expr.T.Expr.span
      (Printf.sprintf
         "this writes %s, which %s %s, %s: nothing else in a call writes what the call borrows \
          (memory.md §2.9.1)"
         (if w.runs <> None then "whatever the block passed in writes" else describe w)
         overlaps (describe b) why)
  in
  let check_call (e : T.Expr.t) =
    match params_of e with
    | Some (is_method, is_mut, tys, args, apart) when List.length tys = List.length args ->
        let indexed = List.mapi (fun i (ty, a) -> (i, ty, a)) (List.combine tys args) in
        let subject =
          match (is_method, args) with
          | true, T.Arg.Value s :: _ -> Option.map (fun c -> (0, c)) (claim s)
          | _ -> None
        in
        let borrowed =
          List.filter_map
            (fun (i, ty, a) ->
              match a with
              | T.Arg.Value v when i > 0 || not is_method ->
                  if borrows ty v.T.Expr.ty then Option.map (fun c -> (i, c)) (claim v) else None
              | _ -> None)
            indexed
        in
        (* The `mut` subject writes its place for the whole call. *)
        (match (subject, args) with
        | Some _, T.Arg.Value s :: _ when is_mut ->
            let ws = subject_writes s in
            List.iter
              (fun (_, b) ->
                List.iter
                  (fun w ->
                    settle_verdict (verdict w b) (fun overlaps ->
                        Env.error env b.expr.T.Expr.span
                          (Printf.sprintf
                             "%s is borrowed by this call, and its `mut` subject %s %s it: \
                              nothing else in a call writes what the call borrows (memory.md \
                              §2.9.1)"
                             (describe b)
                             (describe { w with behind = false })
                             (if w.behind then "reaches, through an `&` field, what may hold"
                              else overlaps))))
                  ws)
              borrowed
        | _ -> ());
        (* A block argument runs during the call. *)
        List.iter
          (fun (_, _, a) ->
            let ws =
              match (a, runs_of a) with
              | T.Arg.Block blk, _ -> writes_block [] blk
              | _, Some r -> [ r ]
              | _ -> []
            in
            List.iter
              (fun (_, b) ->
                List.iter
                  (fun w -> settle_verdict (verdict w b) (report_write w b "which this call borrows"))
                  ws)
              (Option.to_list subject @ borrowed))
          indexed;
        (* An argument written later runs while the borrow is already lent. *)
        List.iter
          (fun (i, b) ->
            List.iter
              (fun (j, ty, a) ->
                match a with
                | T.Arg.Value v when j > i ->
                    let ws = writes_expr [] v in
                    (* A take of the very place borrowed is the moves
                       analysis's to report (lifetimes.md §1.5). *)
                    let ws =
                      match ty with
                      | Ty.Roaming _ ->
                          List.filter
                            (fun (w : claim) -> not (w.at <> None && equal_places w.at b.at))
                            (moved [] v)
                          @ ws
                      | _ -> ws
                    in
                    List.iter
                      (fun w ->
                        settle_verdict (verdict w b)
                          (report_write w b "which an earlier argument of this call borrows"))
                      ws
                | _ -> ())
              indexed)
          borrowed;
        (* What the callee needs kept apart: an `&T` argument from the
           subject it writes, or from a block it runs. *)
        let arg i = match List.nth_opt args i with Some a -> a | None -> T.Arg.Value e in
        Needs.iter
          (fun (p, o) ->
            match arg p with
            | T.Arg.Value pv ->
                let n = named pv in
                let ws =
                  match arg o with
                  (* The callee's own writes through the subject's `&`
                     fields were checked in its body. *)
                  | T.Arg.Value s when o = 0 && is_method -> Option.to_list (claim s)
                  | T.Arg.Block blk -> writes_block [] blk
                  | a -> (
                      match runs_of a with
                      | Some r -> [ r ]
                      | None -> [ { expr = pv; at = None; ty = pv.T.Expr.ty; runs = Some (-1); behind = false } ])
                in
                List.iter
                  (fun w ->
                    settle_verdict (verdict w n) (fun overlaps ->
                        Env.error env pv.T.Expr.span
                          (Printf.sprintf
                             "%s is passed to an `&` parameter this call reads through while %s, \
                              and the two may overlap: nothing else in a call writes what the call \
                              borrows (memory.md §2.9.1)"
                             (match Spawns.place_of pv with
                             | Some pl -> Spawns.describe pl
                             | None -> "this reference")
                             (if o = 0 && is_method then "it writes its subject"
                              else "it runs a block that writes it"))))
                  ws
            | T.Arg.Block _ -> ())
          apart
    | _ -> ()
  in
  (* A binder names its payload for the whole arm. *)
  let check_match (m : T.Match.t) =
    List.iteri
      (fun pos (scrutinee : T.Expr.t) ->
        match claim scrutinee with
        | None -> ()
        | Some s ->
            List.iter
              (fun (arm : T.Arm.t) ->
                match List.nth_opt arm.T.Arm.patterns pos with
                | Some { T.Pattern.binder = Some binder; _ } ->
                    List.iter
                      (fun w ->
                        settle_verdict (verdict w s) (fun overlaps ->
                            Env.error env w.expr.T.Expr.span
                              (Printf.sprintf
                                 "this writes %s, which %s the scrutinee %s while `%s` names \
                                  its payload: an arm with a binder writes its scrutinee only \
                                  through the binder (adt.md §5.1)"
                                 (if w.runs <> None then "whatever the block passed in writes"
                                  else describe w)
                                 overlaps (describe s) binder.T.Local.name)))
                      (writes_block [] arm.T.Arm.body)
                | _ -> ())
              m.T.Match.arms)
      m.T.Match.scrutinees
  in
  let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) = List.iter expr (Exits.stat_exprs s)
  and expr (e : T.Expr.t) =
    check_call e;
    (match e.T.Expr.node with T.Expr.Match m -> check_match m | _ -> ());
    List.iter
      (function
        | Exits.Same x -> expr x
        | Exits.Arm b | Exits.Handler b | Exits.Block b -> block b
        (* A lambda has a frame of its own, walked as its own body. *)
        | Exits.Lambda b -> block b)
      (Exits.parts e)
  in
  (match start with `Block b -> block b | `Expr e -> expr e);
  !needs

let roles is_method (params : T.Local.t list) =
  List.mapi
    (fun i (p : T.Local.t) ->
      ( p,
        match p.T.Local.ty with
        | _ when i = 0 && is_method -> Subject
        | Ty.Reference _ -> Ref i
        | Ty.Concept Ty.Block -> Block_param i
        | _ -> Other ))
    params

(* Every verb's needs first, to a fixed point, since verbs may call each
   other in a cycle; then every body once more to report. *)
let run env (p : T.Program.t) =
  let summaries = Fixpoint.create ~empty:Needs.empty ~union:Needs.union ~equal:Needs.equal in
  let plain f = f () in
  let verbs =
    List.concat_map
      (fun (pkg : T.Package.t) ->
        List.concat_map
          (fun (d : T.Decl.t) ->
            match d.T.Decl.node with
            | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
                [ (Some d.T.Decl.id, roles (S.is_method signature) params, `Block body, plain) ]
            | T.Decl.Subscript { value = Some v; _ } | T.Decl.Constant { value = v; _ } ->
                [ (None, [], `Expr v, plain) ]
            | T.Decl.Enum_map { entries; _ } -> List.map (fun (_, v) -> (None, [], `Expr v, plain)) entries
            | _ -> [])
          pkg.T.Package.decls)
      p.T.Program.packages
    @ List.map
        (fun (i : T.Instance.t) ->
          ( Some i.T.Instance.decl,
            roles (S.is_method i.T.Instance.signature) i.T.Instance.params,
            `Block i.T.Instance.body,
            fun f -> Env.in_instance env i f ))
        p.T.Program.instances
  in
  Fixpoint.settle summaries (fun ~report ->
      List.iter
        (fun (decl, params, start, within) ->
          within (fun overlaps ->
              let needs = walk env summaries ~report ~params start in
              Option.iter (fun d -> Fixpoint.add summaries d needs) decl))
        verbs)
