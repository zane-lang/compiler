(* Small builders of CGT nodes that the walk in [Lower] uses everywhere:
   pointers and their reads, new locals and the arenas that hold them, and a
   value leaving the arenas an exit drains. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout

let unit_ = { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }

let deref id t = { Expr.node = Expr.Deref { Expr.node = Expr.Local id; ty = Nodes.Ty.Ptr }; ty = t }

let binop : Sst.Nodes.Operator.node -> Expr.binop = function
  | Add -> Expr.Add
  | Mul -> Expr.Mul
  | Div -> Expr.Div
  | Eq -> Expr.Eq
  | Less -> Expr.Less

(* An exit ends the run of a block (docs/spec-divergences.md §11). Semantics
   rejects one anywhere else, so this is not reached. *)
let no_block span = Diagnostic.bug ~span "lowering: an exit ends the block its call is written in, and this is in none"

(* Where nothing leaves: an enum map's entry, which is a constant. *)
let constant_ctx () =
  let nowhere span = Diagnostic.bug ~span "lowering expected nothing here to leave" in
  {
    env = Hashtbl.create 1;
    exit = Function;
    expanding = [];
    abort = (fun span _ -> nowhere span);
    resolve = None;
    finish = nowhere;
    exit_call = nowhere;
    scope = { arena = None; settles = [] };
  }

(* A block's arena, made the first time it is needed. *)
let arena st scope =
  match scope.arena with
  | Some a -> a
  | None ->
      let a = fresh st in
      scope.arena <- Some a;
      a

(* A new local: held in the block's arena when it is a host or owns a
   block. *)
let bind st scope span t id value =
  if held st span t then Stat.Host { id; scope = arena st scope; value; layout = layout st span t }
  else Stat.Let { id; value }

let bind_local st scope (l : T.Local.t) id value =
  bind st scope l.T.Local.span l.T.Local.ty id value

let ptr node = { Expr.node; ty = Nodes.Ty.Ptr }

(* `@primitives$Array<T, n>`, and whether an expression is an array
   literal. *)
let array_type t n =
  Tty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Tty.Type t; Tty.Number n ] }

let is_array_lit (e : T.Expr.t) = match e.T.Expr.node with T.Expr.Array_lit _ -> true | _ -> false

(* A value of type [t] leaving the arenas an exit drains: a host, or a
   value that owns a block, takes its blocks out of them first. *)
let escape st span t exit (value : Expr.t) =
  if held st span t then
    { value with Expr.node = Expr.Escape { value; layout = layout st span t; exit } }
  else value
let layout_table l = ptr (Expr.Layout l)
let resolve (tether : Expr.t) = ptr (Expr.Resolve tether)
let local_ptr id = ptr (Expr.Local id)

(* A storage primitive's operator. The scalars have the machine's own, and
   `@primitives$String` joins and compares in the runtime. *)
let primitive_op span op t (l : Expr.t) (r : Expr.t) =
  match (l.Expr.ty, op) with
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Add ->
      { Expr.node = Expr.Runtime { fn = "zane_text_join"; args = [ l; r ] }; ty = t }
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Eq ->
      let same =
        { Expr.node = Expr.Runtime { fn = "zane_text_equal"; args = [ l; r ] }; ty = Nodes.Ty.I64 }
      in
      let yes = { Expr.node = Expr.Int 1L; ty = Nodes.Ty.I64 } in
      { Expr.node = Expr.Binary { op = Expr.Eq; left = same; right = yes }; ty = t }
  | Nodes.Ty.Handle, _ -> Diagnostic.bug ~span "lowering: `@primitives$String` has no such operator"
  | _ -> { Expr.node = Expr.Binary { op = binop op; left = l; right = r }; ty = t }
