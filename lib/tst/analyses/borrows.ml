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
   part except a lambda's body, which has a frame of its own. *)

module T = Nodes
module S = Signature

(* A place, as [Spawns] has it. *)
type place = Spawns.place

(* A place and what is known of it: the place itself when the checker can
   follow it, and the type of what it holds. *)
type claim = { expr : T.Expr.t; at : place option; ty : Ty.t }

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

(* Two claims clash when their places overlap; where either place is
   unknown, when either's type may hold the other's. *)
let clashes env a b =
  match (a.at, b.at) with
  | Some x, Some y -> Spawns.overlap x y
  | _ ->
      let a_ty = Ty.strip_mode a.ty and b_ty = Ty.strip_mode b.ty in
      Spawns.contains env a_ty b_ty || Spawns.contains env b_ty a_ty

(* The reference locals bound again anywhere in [start]. *)
let rebound start =
  let found = Hashtbl.create 8 in
  let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) =
    (match s.T.Stat.node with
    | T.Stat.Assign { target = { T.Expr.ty = Ty.Reference _; node = T.Expr.Var (T.Name_ref.Local l); _ }; _ }
      ->
        Hashtbl.replace found l.T.Local.id ()
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
  found

let walk env start =
  (* Where each reference local points, when the checker knows: only one
     never bound again, since a binding later in a loop body or a block
     argument is seen by what runs before it on the next run. *)
  let origins : (int, place option) Hashtbl.t = Hashtbl.create 8 in
  let rebound = rebound start in
  let resolve (p : place) =
    match p.Spawns.local.T.Local.ty with
    | Ty.Reference _ -> (
        match Hashtbl.find_opt origins p.Spawns.local.T.Local.id with
        | Some (Some o) -> Some { o with Spawns.path = o.Spawns.path @ p.Spawns.path }
        | _ -> None)
    | _ -> Some p
  in
  let origin (e : T.Expr.t) =
    match (e.T.Expr.ty, e.T.Expr.node) with
    | Ty.Reference _, T.Expr.Var (T.Name_ref.Local l) -> (
        match Hashtbl.find_opt origins l.T.Local.id with Some o -> o | None -> None)
    | Ty.Reference _, _ -> None
    | _ -> if through_reference e then None else Option.bind (Spawns.place_of e) resolve
  in
  (* A claim on the place [e] names, when it names one. *)
  let claim (e : T.Expr.t) =
    match Spawns.place_of e with
    | None -> None
    | Some p ->
        let at = if through_reference e then None else resolve p in
        Some { expr = e; at; ty = e.T.Expr.ty }
  in
  let describe (c : claim) =
    match Spawns.place_of c.expr with Some p -> Spawns.describe p | None -> "this place"
  in
  (* The parameters of a call, by position, and its subject's when it has
     one. *)
  let params_of (e : T.Expr.t) =
    match e.T.Expr.node with
    | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } -> (
        match Env.signature_of env callee with
        | Some sg ->
            Some (S.is_method sg, sg.S.is_mut, List.map (fun (p : S.param) -> p.S.ty) sg.S.params, args)
        | None -> None)
    | T.Expr.Call_value { callee = { T.Expr.ty = Ty.Verb v; _ }; args; _ } ->
        Some (Option.is_some v.Ty.this_, v.Ty.is_mut, Option.to_list v.Ty.this_ @ v.Ty.params, args)
    | T.Expr.Op { impl = { owner = S.Declared _; _ } as impl; left; right; swapped; _ } -> (
        match Env.signature_of env impl with
        | Some sg ->
            let tys = List.map (fun (p : S.param) -> p.S.ty) sg.S.params in
            (* The operands in written order, each with its parameter. *)
            let tys = if swapped then List.rev tys else tys in
            Some (false, false, tys, [ T.Arg.Value left; T.Arg.Value right ])
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
  (* Every place a part writes, reached through anything but a lambda. *)
  let rec writes_expr acc (e : T.Expr.t) =
    let acc =
      match params_of e with
      | Some (_, true, _, T.Arg.Value subject :: _) -> (
          match claim subject with Some c -> c :: acc | None -> acc)
      | _ -> acc
    in
    let acc =
      match (e.T.Expr.node, params_of e) with
      | (T.Expr.Call _ | T.Expr.Construct _ | T.Expr.Call_value _), Some (_, _, tys, args)
        when List.length tys = List.length args ->
          List.fold_left2
            (fun acc ty a ->
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
        (* Binding a reference again writes no place it names. *)
        | Ty.Reference _, T.Expr.Var _ -> acc
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
  let report (w : claim) (b : claim) why =
    Env.error env w.expr.T.Expr.span
      (Printf.sprintf
         "this writes %s, which overlaps %s, %s: nothing else in a call writes what the call \
          borrows (memory.md §2.9.1)"
         (describe w) (describe b) why)
  in
  let check_call (e : T.Expr.t) =
    match params_of e with
    | Some (is_method, is_mut, tys, args) when List.length tys = List.length args ->
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
        (match subject with
        | Some (_, s) when is_mut ->
            List.iter
              (fun (_, b) ->
                if clashes env s b then
                  Env.error env b.expr.T.Expr.span
                    (Printf.sprintf
                       "%s is borrowed by this call, and its `mut` subject %s overlaps it: nothing \
                        else in a call writes what the call borrows (memory.md §2.9.1)"
                       (describe b) (describe s)))
              borrowed
        | _ -> ());
        (* A block argument runs during the call. *)
        List.iter
          (fun (_, _, a) ->
            match a with
            | T.Arg.Block blk ->
                let ws = writes_block [] blk in
                List.iter
                  (fun (_, b) ->
                    List.iter
                      (fun w -> if clashes env w b then report w b "which this call borrows")
                      ws)
                  (Option.to_list subject @ borrowed)
            | T.Arg.Value _ -> ())
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
                            (fun (w : claim) -> not (w.at <> None && w.at = b.at))
                            (moved [] v)
                          @ ws
                      | _ -> ws
                    in
                    List.iter
                      (fun w ->
                        if clashes env w b then
                          report w b "which an earlier argument of this call borrows")
                      ws
                | _ -> ())
              indexed)
          borrowed
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
                        if clashes env w s then
                          Env.error env w.expr.T.Expr.span
                            (Printf.sprintf
                               "this writes %s, which overlaps the scrutinee %s while `%s` names its \
                                payload: an arm with a binder writes its scrutinee only through the \
                                binder (adt.md §5.1)"
                               (describe w) (describe s) binder.T.Local.name))
                      (writes_block [] arm.T.Arm.body)
                | _ -> ())
              m.T.Match.arms)
      m.T.Match.scrutinees
  in
  let rec block (b : T.Block.t) = List.iter stat b.T.Block.stats
  and stat (s : T.Stat.t) =
    List.iter expr (Exits.stat_exprs s);
    match s.T.Stat.node with
    | T.Stat.Let { local = { T.Local.ty = Ty.Reference _; id; _ }; value } ->
        Hashtbl.replace origins id (if Hashtbl.mem rebound id then None else origin value)
    | _ -> ()
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
  match start with `Block b -> block b | `Expr e -> expr e

let run env (p : T.Program.t) =
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> walk env (`Block body)
          | T.Decl.Subscript { value = Some v; _ } | T.Decl.Constant { value = v; _ } ->
              walk env (`Expr v)
          | T.Decl.Enum_map { entries; _ } -> List.iter (fun (_, v) -> walk env (`Expr v)) entries
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) -> Env.in_instance env i (fun () -> walk env (`Block i.T.Instance.body)))
    p.T.Program.instances
