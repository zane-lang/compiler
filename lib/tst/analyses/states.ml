(* The state of the place an expression denotes (memory.md §2.1, §2.8.1): the
   one fact the move, reference and scope analyses all read, so that none of
   them can decide it differently.

   An owner of a reference type is settled or roaming. A bare symbol of a
   reference type and a package constant are settled; a symbol or parameter
   declared `^T` is roaming. What a reference names is settled. A borrow --
   a bare reference-type parameter, and `this` -- is neither: it is the
   caller's owner, lent for the call (§2.9). Fixed storage takes its root's
   state: a struct field, an `ArrayRef` element. Dynamic storage is
   [Contingent]: a list's element and a variant's payload come and go while
   their container lives, so they are roaming, and they are never moved out
   of it either (lifetimes.md §1.2). A verb's result and a case form are
   [Fresh]: nothing owns them yet.

   Every decision is made from the declared types along the path, so it is
   the same at every point of the body. *)

module T = Nodes
module S = Signature

type state = Settled | Roaming | Borrowed | Contingent | Fresh

(* What an analysis tells the function about the body it is in: which
   locals are the subject, ordinary parameters, and match binders. *)
type t = {
  subjects : (int, unit) Hashtbl.t;
  params : (int, unit) Hashtbl.t;
  binders : (int, unit) Hashtbl.t;
  (* A declared subscript's place, by declaration: its `this` and the place
     its body projects (functions.md §2.9). *)
  projections : (int, int * T.Expr.t) Hashtbl.t;
}

let create projections =
  {
    subjects = Hashtbl.create 2;
    params = Hashtbl.create 8;
    binders = Hashtbl.create 8;
    projections;
  }

let subject s (l : T.Local.t) = Hashtbl.replace s.subjects l.T.Local.id ()
let param s (l : T.Local.t) = Hashtbl.replace s.params l.T.Local.id ()
let binder s (l : T.Local.t) = Hashtbl.replace s.binders l.T.Local.id ()

(* The place each declared subscript's body projects, read from the
   declaration, or from any instance of a generic one: which place it is
   does not depend on the arguments. *)
let projections (p : T.Program.t) =
  let table = Hashtbl.create 8 in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Subscript { params = this :: _; value = Some v; _ } ->
              Hashtbl.replace table d.T.Decl.id (this.T.Local.id, v)
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) ->
      match (i.T.Instance.params, i.T.Instance.body.T.Block.stats) with
      | this :: _, [ { T.Stat.node = T.Stat.Return v; _ } ]
        when i.T.Instance.signature.S.kind = S.Subscript
             && not (Hashtbl.mem table i.T.Instance.decl) ->
          Hashtbl.replace table i.T.Instance.decl (this.T.Local.id, v)
      | _ -> ())
    p.T.Program.instances;
  table

let is_intrinsic name = function
  | Ty.Intrinsic { namespace = "primitives"; name = n; _ } -> n = name
  | _ -> false

(* A step into fixed storage keeps its base's state. A member of a fresh
   value is part of a temporary, which is neither an owner a store may move
   from nor a place a reference may name, as an element is not. *)
let fixed base = match base with Fresh -> Contingent | s -> s

(* [inside] maps a subscript body's `this` to the state of the place it was
   called on, while that body's projection is followed. *)
let rec state ?(inside = []) s (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match List.assoc_opt l.T.Local.id inside with
      | Some st -> st
      | None ->
          if Hashtbl.mem s.binders l.T.Local.id then Contingent
          else if Hashtbl.mem s.subjects l.T.Local.id then Borrowed
          else (
            match l.T.Local.ty with
            | Ty.Roaming _ -> Roaming
            | Ty.Reference _ -> Settled
            | _ -> if Hashtbl.mem s.params l.T.Local.id then Borrowed else Settled))
  | T.Expr.Var (T.Name_ref.Global _ | T.Name_ref.Intrinsic _) -> Settled
  | T.Expr.Var _ -> Fresh
  | T.Expr.Field { target; _ } ->
      if Ty.is_ref target.T.Expr.ty then Settled else fixed (state ~inside s target)
  | T.Expr.Subscript { target; impl; _ } -> (
      let base () = if Ty.is_ref target.T.Expr.ty then Settled else state ~inside s target in
      match impl.T.Verb_ref.owner with
      | S.Intrinsic _ ->
          let t = Ty.strip_mode target.T.Expr.ty in
          if is_intrinsic "List" t then Contingent else fixed (base ())
      | S.Declared id -> (
          match Hashtbl.find_opt s.projections id with
          (* A projection that reaches itself again is settled by nothing it
             finds, so it is taken as the dynamic kind. *)
          | Some (this, body) when List.length inside < 16 ->
              state ~inside:((this, base ()) :: inside) s body
          | _ -> Contingent))
  | T.Expr.Case_read _ -> Contingent
  | _ -> if Ty.is_ref e.T.Expr.ty then Settled else Fresh

(* The step a [Contingent] place is found through: a field of a list's
   element or of a payload is contingent because of that element or
   payload, which a message names. *)
let rec contingent_step (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } when not (Ty.is_ref target.T.Expr.ty) -> contingent_step target
  | _ -> e

(* A place's state, and the node a message describes it by. *)
let described s (e : T.Expr.t) =
  match state s e with
  | Contingent -> (Contingent, (contingent_step e).T.Expr.node)
  | st -> (st, e.T.Expr.node)

(* The local a place is reached from, and the field steps from it to the
   place, outermost first: `car.engine.rotor` is `car` and
   [engine; rotor]. [None] when the path holds any other step. *)
let rec field_path (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> Some (l, [])
  | T.Expr.Field { target; field; _ } when not (Ty.is_ref target.T.Expr.ty) ->
      Option.map (fun (l, path) -> (l, path @ [ field ])) (field_path target)
  | _ -> None
