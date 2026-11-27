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

let binop span : Sst.Nodes.Operator.node -> Expr.binop = function
  | Add -> Expr.Add
  | Mul -> Expr.Mul
  | Div -> Expr.Div
  | Eq -> Expr.Eq
  | Less -> Expr.Less
  | And | Or -> Diagnostic.bug ~span "lowering: a storage primitive has no `and` or `or`"

(* An exit ends the run of a block (control-flow.md §2.3). Semantics
   rejects an exit anywhere else, so this case is not reached. *)
let no_block span = Diagnostic.bug ~span "lowering: an exit ends the block its call is written in, and this is in none"

(* The exit for code that nothing leaves: an enum map's entry, which is a
   constant. *)
let constant_ctx () =
  let nowhere span = Diagnostic.bug ~span "lowering expected nothing here to leave" in
  {
    env = Hashtbl.create 1;
    exit = Function;
    expanding = [];
    loop = Outside;
    abort = (fun span _ -> nowhere span);
    resolve = None;
    finish = nowhere;
    exit_call = nowhere;
    scope = { arena = None; settles = []; wants = [] };
  }

(* A block's arena, made the first time it is needed. *)
let arena st scope =
  match scope.arena with
  | Some a -> a
  | None ->
      let a = fresh st in
      scope.arena <- Some a;
      a

(* A block's statements in its arena, when the block has one: either an arena
   the block holds values in, or an arena kept for the fresh owners the block
   moves into callees that may drop them, which Regions decides once every
   function is lowered. *)
let close st scope body =
  match (scope.arena, scope.wants) with
  | None, [] -> body
  | arena, wants ->
      let id = match arena with Some id -> id | None -> fresh st in
      if wants <> [] then Hashtbl.replace st.wants (st.current, id) wants;
      [ Stat.Scope { id; body } ]

(* A new local: held in the block's arena when it is an owner or owns a
   block. *)
let bind st scope span t id value =
  if held st span t then Stat.Hold { id; scope = arena st scope; value; layout = layout st span t }
  else Stat.Let { id; value }

let bind_local st scope (l : T.Local.t) id value =
  bind st scope l.T.Local.span l.T.Local.ty id value

let ptr node = { Expr.node; ty = Nodes.Ty.Ptr }

(* The block of the boxed member whose slot is at [at] (adt.md §4), and a
   block on its way into such a slot: stored as a [Box32] with image boxes
   (experimental; Type_layout.box_type). *)
let box_block at =
  match Type_layout.box_type () with
  | Nodes.Ty.Ptr -> ptr (Expr.Deref at)
  | t -> ptr (Expr.Convert { Expr.node = Expr.Deref at; ty = t })

let boxed_value (block : Expr.t) =
  match Type_layout.box_type () with
  | Nodes.Ty.Ptr -> block
  | t -> { Expr.node = Expr.Convert block; ty = t }

(* A reference read from a member, element or payload slot, and a reference
   on its way into such a slot (Type_layout.ref_slot): [read] is the slot's
   read, typed as the reference it holds, and [value] is the reference. *)
let loaded_ref ~slot (read : Expr.t) =
  if slot then ptr (Expr.Convert { read with Expr.ty = Nodes.Ty.Ref }) else read

let stored_ref ~slot (value : Expr.t) =
  if slot then { Expr.node = Expr.Convert value; ty = Nodes.Ty.Ref } else value

(* `@primitives$Array<T, n>`, and whether an expression is an array
   literal. *)
let array_type t n =
  Tty.Intrinsic { namespace = "primitives"; name = "Array"; args = [ Tty.Type t; Tty.Number n ] }

let is_array_lit (e : T.Expr.t) = match e.T.Expr.node with T.Expr.Array_lit _ -> true | _ -> false

(* A value of type [t] leaving the arenas an exit drains: an owner, or a
   value that owns a block, first takes its blocks out of those arenas. *)
let escape st span t exit (value : Expr.t) =
  if held st span t then
    { value with Expr.node = Expr.Escape { value; layout = layout st span t; exit } }
  else value

(* What a `return` to an expansion does: store the result, and leave. *)
let leave label result value =
  match result with
  | Some id -> [ Stat.assign id value; Stat.Leave label ]
  | None -> [ Stat.Eval value; Stat.Leave label ]

let layout_table l = ptr (Expr.Layout l)
let local_ptr id = ptr (Expr.Local id)

(* A storage primitive's operator. The scalars use the machine's own
   operations, and `@primitives$String` joins and compares in the runtime. *)
let primitive_op span op t (l : Expr.t) (r : Expr.t) =
  match (l.Expr.ty, op) with
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Add ->
      { Expr.node = Expr.Runtime { fn = Runtime.Text_join; args = [ l; r ] }; ty = t }
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Eq ->
      let same =
        { Expr.node = Expr.Runtime { fn = Runtime.Text_equal; args = [ l; r ] }; ty = Nodes.Ty.I64 }
      in
      let yes = { Expr.node = Expr.Int 1L; ty = Nodes.Ty.I64 } in
      { Expr.node = Expr.Binary { op = Expr.Eq; left = same; right = yes }; ty = t }
  | Nodes.Ty.Handle, _ -> Diagnostic.bug ~span "lowering: `@primitives$String` has no such operator"
  | _ -> { Expr.node = Expr.Binary { op = binop span op; left = l; right = r }; ty = t }
