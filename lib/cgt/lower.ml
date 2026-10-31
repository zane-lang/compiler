(* Lowering: the TST to the CGT (docs/design/lowering.md).

   What is lowered is what `main` reaches. A verb is lowered once, the first
   time a call reaches it, so a program pays only for the verbs it uses and a
   package's other declarations need not lower yet. Anything lowering cannot
   handle yet is refused with a diagnostic at the node, rather than lowered
   wrongly.

   This file is the recursive walk over a verb's body: its expressions,
   the storage they read, and its blocks and statements. What it reads is
   beside it: [State], [Type_layout], [Literals], [Verbs], [Outcome] and
   [Build]. The rest of lowering is in modules outside the walk's
   recursion, each taking the walk as an argument ([State.walk]):
   [Lower_intrinsics] the runtime's and a list's intrinsics, operations and
   math functions; [Lower_data] primitives, arrays, structs and field
   constructors; [Lower_calls] subscripts, calls, their arguments and
   expansion; [Lower_match] `match`es, handlers and case reads;
   [Lower_spawn] spawned calls; and [Lower_lambda] lambdas. [Program]
   lowers a whole program with the walk. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes

open State
open Type_layout
open Literals
open Verbs
open Outcome
open Build

(* ---------------------------------------------------------------------- *)
(* Expressions                                                            *)
(* ---------------------------------------------------------------------- *)

let rec expr st ctx (e : T.Expr.t) : Expr.t =
  let span = e.T.Expr.span in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> { Expr.node = Expr.Local id; ty = ty st span l.T.Local.ty }
      | Pointer id -> deref id (ty st span l.T.Local.ty)
      | Node id -> deref id (node_ty st span l.T.Local.ty)
      | Future { settle; at } ->
          let t = ty st span l.T.Local.ty in
          let value =
            match at with Some p -> { Expr.node = Expr.Deref p; ty = t } | None -> unit_
          in
          joined st (settle ()) value
      | Literal _ | Code _ -> Diagnostic.bug ~span "lowering: a block or literal parameter read as a value")
  | T.Expr.Bool_lit b -> { Expr.node = Expr.Bool b; ty = Nodes.Ty.I1 }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } ->
      Lower_data.primitive walk st ctx span spelling args e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Intrinsic spelling; _ }; value } ->
      Lower_data.primitive walk st ctx span spelling [ T.Arg.Value value ] e.T.Expr.ty
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance; _ }; args; handler }
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } ->
      Lower_calls.call walk st ctx span (verb_of st id instance) args handler e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Declared id; instance; _ }; value } ->
      Lower_calls.call walk st ctx span (verb_of st id instance) [ T.Arg.Value value ] None
        e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None }
    when String.starts_with ~prefix:"@operators$" spelling ->
      Lower_intrinsics.operation walk st ctx span spelling args e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None }
    when String.starts_with ~prefix:"@math$" spelling ->
      Lower_intrinsics.math walk st ctx span spelling args e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; _ }
    when Lower_intrinsics.runs spelling ->
      Lower_intrinsics.call walk st ctx span e
  | T.Expr.Subscript _ -> (
      (* The element's own storage: for an `&` element, what it holds is the
         reference, so this reads it rather than asking [addr] for the
         reference, which would ask back here. *)
      match storage st ctx span e with
      | Some p -> loaded_ref ~slot:(ref_slot e.T.Expr.ty) { Expr.node = Expr.Deref p; ty = ty st span e.T.Expr.ty }
      | None -> Diagnostic.bug ~span "lowering: a subscript with no address")
  | T.Expr.Op { op; impl = { owner; instance; _ }; left; right; swapped; handler } -> (
      let t = ty st span e.T.Expr.ty in
      (* [left] and [right] are in written order, and run in it
         (operators.md §2.3). When the desugaring swapped them, they are passed
         the other way round: `a > b` calls `<` with `b` first. *)
      let operands l r apply =
        if swapped then in_order st t l r (fun l r -> apply r l)
        else
          let l = l () in
          apply l (r ())
      in
      match owner with
      | S.Intrinsic _ -> Diagnostic.bug ~span "lowering: an operator no package declared"
      | S.Declared id -> (
          match verb_of st id instance with
          | Some ({ params = [ pl; pr ]; _ } as v)
            when not
                   (Lower_calls.writes_out walk st ctx span v
                      (if swapped then [ T.Arg.Value right; T.Arg.Value left ]
                       else [ T.Arg.Value left; T.Arg.Value right ])) ->
              let for_left, for_right = if swapped then (pr, pl) else (pl, pr) in
              operands
                (fun () -> Lower_calls.argument walk st ctx span v for_left left)
                (fun () -> Lower_calls.argument walk st ctx span v for_right right)
                (fun l r -> Lower_calls.invoke walk st ctx span v [ l; r ] handler)
          (* An operator that takes a literal, or whose body is one
             expression, is expanded where it is called (L11). Its operands
             still run in written order: when the desugaring swapped them,
             the written left operand is held first. *)
          | Some ({ params = [ _; pr ]; _ } as v) ->
              let call args = Lower_calls.call walk st ctx span (Some v) args handler e.T.Expr.ty in
              if swapped then
                let lets, held = Lower_calls.held_argument walk st ctx span v pr (T.Arg.Value left) in
                Lower_calls.held_in st lets (call [ T.Arg.Value right; held ])
              else call [ T.Arg.Value left; T.Arg.Value right ]
          | _ -> Diagnostic.bug ~span "lowering: an operator with no verb to call"))
  | T.Expr.Flip { impl = { owner = S.Declared id; instance; _ }; value; handler } ->
      Lower_calls.call walk st ctx span (verb_of st id instance) [ T.Arg.Value value ] handler
        e.T.Expr.ty
  | T.Expr.Field _ when Option.is_some (node_place st ctx span e) ->
      if pooled st e.T.Expr.ty then refuse span "pooled variants: a subtree read as a value";
      { Expr.node = Expr.Deref (Option.get (node_place st ctx span e)); ty = ty st span e.T.Expr.ty }
  | T.Expr.Field { target; slot = member; _ } ->
      let t = ty st span e.T.Expr.ty in
      let owner = Tty.strip_mode target.T.Expr.ty in
      let index = member_index st owner member in
      let slot = ref_slot (field_type st span owner member) in
      if boxed st owner (field_type st span owner member) then
        (* A boxed member's payload is in its block. A fresh value is held
           in this scope first (storage), so its block is returned at the
           drain. *)
        match addr st ctx span e with
        | Some p -> { Expr.node = Expr.Deref p; ty = t }
        | None -> Diagnostic.bug ~span "lowering expected a boxed member to have a place"
      else if Tty.is_ref target.T.Expr.ty then
        (* Read through the reference, at the address of the owner it names
           (memory.md §4.1). *)
        let base = expr st ctx target in
        let within = ty st span owner in
        loaded_ref ~slot
          { Expr.node = Expr.Deref (ptr (Expr.Offset { base; within; path = [ index ] })); ty = t }
      else if collapsed st owner then loaded_ref ~slot { (borrow st ctx span target) with ty = t }
      else loaded_ref ~slot { Expr.node = Expr.Member { value = borrow st ctx span target; index }; ty = t }
  | T.Expr.Init fields -> Lower_data.record walk st ctx span e.T.Expr.ty fields
  | T.Expr.Construct_fields { ctor = { owner = S.Declared id; instance; _ }; fields; handler } ->
      Lower_data.construct_fields walk st ctx span (verb_of st id instance) fields handler
        e.T.Expr.ty
  | T.Expr.Case _ when pooled st e.T.Expr.ty -> pool_value st ctx span e
  | T.Expr.Case { case; payload } ->
      let index = case_index st span e.T.Expr.ty case in
      let t = payload_type st span e.T.Expr.ty case in
      let payload = Lower_data.member walk st ctx span e.T.Expr.ty t payload in
      case_of st span e.T.Expr.ty index payload
  | T.Expr.Enum_member case ->
      let index = case_index st span e.T.Expr.ty case in
      case_of st span e.T.Expr.ty index unit_
  | T.Expr.Match { scrutinees; arms; handler } ->
      Lower_match.match_ walk st ctx span scrutinees arms handler e.T.Expr.ty
  | T.Expr.Case_read { target; case; handler } ->
      Lower_match.case_read walk st ctx span target case handler e.T.Expr.ty
  | T.Expr.Map_read { target; map; _ } ->
      Lower_match.map_read walk st ctx span target map e.T.Expr.ty
  (* A spawned call read where it is written is waited for at once, which
     is the call itself (docs/design/lowering.md §9). *)
  | T.Expr.Spawn call -> expr st ctx call
  | T.Expr.Lambda l ->
      { Expr.node = Expr.Function (Lower_lambda.lambda st span e.T.Expr.ty l); ty = Nodes.Ty.Ptr }
  (* A lambda-variable declared at package scope is its lambda, and any
     other package constant is read where it was made. *)
  | T.Expr.Var (T.Name_ref.Global { decl; _ }) -> (
      match Hashtbl.find_opt st.constants decl with
      | Some { value = { T.Expr.node = T.Expr.Lambda _; _ } as value; _ } -> expr st ctx value
      | Some _ -> { Expr.node = Expr.Deref (constant st decl); ty = ty st span e.T.Expr.ty }
      | None -> Diagnostic.bug ~span "lowering found no package constant here")
  | T.Expr.Call_value { callee; args; handler } ->
      Lower_calls.call_value walk st ctx span callee args handler
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; _ }
    when String.starts_with ~prefix:"@controlflow$" spelling ->
      refuse span (Printf.sprintf "lowering does not handle `%s` used as a value yet" spelling)
  | _ -> Diagnostic.bug ~span "lowering: an expression of a form it has no case for"

(* Two operands stored in the order they are given, then combined. *)
and in_order st t first second combine =
  let store make =
    let (v : Expr.t) = make () in
    let id = fresh st in
    ({ Expr.node = Expr.Local id; ty = v.Expr.ty }, Stat.Let { id; value = v })
  in
  let a, let_a = store first in
  let b, let_b = store second in
  let label = fresh st in
  let result = fresh st in
  {
    Expr.node =
      Expr.Expand
        {
          label;
          body = [ let_a; let_b; Stat.assign result (combine a b) ];
          result = Some result;
        };
    ty = t;
  }

(* A spawned call's result, read once the call has returned (concurrency.md
   §3.2). *)
and joined st settle (value : Expr.t) =
  let label = fresh st in
  if value.Expr.ty = Nodes.Ty.Void then
    { Expr.node = Expr.Expand { label; body = settle; result = None }; ty = value.ty }
  else
    let result = fresh st in
    let body = settle @ [ Stat.assign result value ] in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }

(* ---------------------------------------------------------------------- *)
(* Storage, moves and borrows                                             *)
(* ---------------------------------------------------------------------- *)

(* A value read where its type's own storage is wanted: through a reference,
   the owner it names. *)
and value_of st ctx (e : T.Expr.t) =
  if Tty.is_ref e.T.Expr.ty then
    let t = ty st e.T.Expr.span (Tty.strip_mode e.T.Expr.ty) in
    { Expr.node = Expr.Deref (expr st ctx e); ty = t }
  else read st ctx e

(* A value read out of its place. One reached through an owner is read as a
   snapshot (concurrency.md §4.4), or read where it is when no spawned call
   can write back a value it holds or that holds it. *)
and read st ctx (e : T.Expr.t) =
  let span = e.T.Expr.span in
  if through_owner st e && not (reference st e.T.Expr.ty) then
    match addr st ctx span e with
    | Some p ->
        let node = if snapshots st e then Expr.Snapshot p else Expr.Deref p in
        { Expr.node; ty = ty st span e.T.Expr.ty }
    | None -> expr st ctx e
  else expr st ctx e

(* The address of the value a place holds (L10): through a reference, the
   owner it names (memory.md §4.1); otherwise the place's own storage. *)
and addr st ctx span (e : T.Expr.t) : Expr.t option =
  if Tty.is_ref e.T.Expr.ty then Some (expr st ctx e) else storage st ctx span e

(* The address of a place's own storage: a local's slot, a `mut` subject's
   or borrowed argument's pointer, and a member of what any place holds. *)
and storage st ctx span (e : T.Expr.t) : Expr.t option =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> Some (ptr (Expr.Address id))
      | Pointer id | Node id -> Some (ptr (Expr.Local id))
      | Future { settle; at = Some p } -> Some (joined st (settle ()) p)
      | _ -> None)
  | T.Expr.Field _ when Option.is_some (node_place st ctx span e) -> node_place st ctx span e
  | T.Expr.Field { target; slot; _ } ->
      let owner = Tty.strip_mode target.T.Expr.ty in
      let base =
        match addr st ctx span target with
        | Some base -> Some base
        | None when boxed st owner (field_type st span owner slot) -> Some (lend st ctx span target)
        | None -> None
      in
      Option.map
        (fun base ->
          if collapsed st owner then base
          else
            let within = ty st span owner in
            let at = ptr (Expr.Offset { base; within; path = [ member_index st owner slot ] }) in
            (* A boxed member's place is its payload, in its block. *)
            if boxed st owner (field_type st span owner slot) then box_block at else at)
        base
  | T.Expr.Var (T.Name_ref.Global { decl; _ }) -> (
      match Hashtbl.find_opt st.constants decl with
      | Some { value = { T.Expr.node = T.Expr.Lambda _; _ }; _ } | None -> None
      | Some _ -> Some (constant st decl))
  (* What the program has, such as `@program$console`, holds nothing a
     program reads (effects.md §6.6), so its place is a variable of the
     program's that holds nothing, whose address a reference to it holds. *)
  | T.Expr.Var (T.Name_ref.Intrinsic name) ->
      let symbol = "zane.value." ^ name in
      if not (List.exists (fun (g : Global.t) -> g.Global.symbol = symbol) st.globals) then
        st.globals <- { Global.symbol; linkage = Linkage.Local; ty = Nodes.Ty.I64; per_thread = false } :: st.globals;
      Some (ptr (Expr.Global symbol))
  | T.Expr.Subscript { target; impl; args } ->
      Some (Lower_calls.subscript walk st ctx span target impl args)
  | T.Expr.Case_read { target; case; handler } when held st span e.T.Expr.ty ->
      Some (Lower_match.case_place walk st ctx span target case handler e.T.Expr.ty)
  | _ -> None

(* A reference to a place, minted as the place's address, or an existing
   reference copied (memory.md §2.6, §4.1). The semantic pass let only a
   settled place mint one, and a settled owner never moves, so the address
   holds until the owner's scope drains. *)
and reference_to st ctx span (e : T.Expr.t) =
  if Tty.is_ref e.T.Expr.ty then expr st ctx e
  else
    match addr st ctx span e with
    | Some p -> p
    | None -> Diagnostic.bug ~span "lowering expected a reference source here"

(* A value on its way into storage of type [dst]: a reference there is
   minted or copied, and a reference-type owner read from a place moves,
   which spends the place (lifetimes.md §1.6). *)
and moved st ctx span dst (e : T.Expr.t) =
  if pooled st dst && Option.is_some (node_place st ctx span e) then begin
    (* A subtree leaves its pool as a copy in a pool of its own; one moved
       out leaves its nodes behind, unused (docs/experiments). *)
    let int k = { Expr.node = Expr.Int k; ty = Nodes.Ty.I64 } in
    let handle = ty st span dst in
    let out = fresh st and label = fresh st and result = fresh st in
    let size = fst (Nodes.Ty.size_align (node_shape st span dst)) in
    let args =
      [ ptr (Expr.Address out); Option.get (node_place st ctx span e); int (Int64.of_int size) ]
      @ List.map int (node_masks st span dst)
    in
    let body =
      [
        Stat.Let { id = out; value = { Expr.node = Expr.Runtime { fn = Runtime.List_new; args = [] }; ty = handle } };
        Stat.Eval { Expr.node = Expr.Runtime { fn = Runtime.Pool_copy; args }; ty = Nodes.Ty.Void };
        Stat.assign result { Expr.node = Expr.Local out; ty = handle };
      ]
    in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = handle }
  end
  else if Tty.is_ref dst then reference_to st ctx span e
  else if owned st dst && not (Tty.is_ref e.T.Expr.ty) then
    match e.T.Expr.node with
    | T.Expr.Var _ | T.Expr.Field _ -> (
        match addr st ctx span e with
        | Some address ->
            let l = layout st span dst in
            { Expr.node = Expr.Take { address; layout = l }; ty = ty st span dst }
        (* Semantics moves an owner only out of a roaming symbol or a field
           of one (moves.ml), which is a place. *)
        | None -> Diagnostic.bug ~span "lowering expected an owner to move out of a place")
    | _ -> expr st ctx e
  else if owns st span dst && is_place e then
    let value = value_of st ctx e in
    { Expr.node = Expr.Copy { value; layout = layout st span dst }; ty = value.Expr.ty }
  else read st ctx e

(* Whether an expression reads a value something else owns, rather than
   making a fresh one: a place, a member of any value, which a fresh value
   is borrowed for, an element, or what a case read gives. *)
and is_place (e : T.Expr.t) =
  Tty.is_ref e.T.Expr.ty
  ||
  match e.T.Expr.node with
  | T.Expr.Var _ | T.Expr.Field _ | T.Expr.Subscript _ | T.Expr.Case_read _ -> true
  | _ -> false

(* A value read where it is only looked at, as a value parameter or an
   operand: a place is read where it is, and a fresh owner, or a fresh value
   that owns a block, is held in this scope first, so the scope's drain ends
   it and returns its blocks. *)
and borrow st ctx span (e : T.Expr.t) =
  if held st span e.T.Expr.ty && not (is_place e) then begin
    let value = expr st ctx e in
    let id = fresh st in
    let label = fresh st in
    let result = fresh st in
    let body =
      [
        bind st ctx.scope span e.T.Expr.ty id value;
        Stat.assign result { Expr.node = Expr.Local id; ty = value.Expr.ty };
      ]
    in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }
  end
  else value_of st ctx e

(* The address a callee is lent (L6): the caller's place, or a fresh value
   stored here first, which this scope then holds. *)
and lend st ctx span (a : T.Expr.t) =
  match addr st ctx span a with
  | Some p -> p
  | None ->
      let value = expr st ctx a in
      let id = fresh st in
      let label = fresh st in
      let result = fresh st in
      let body =
        [ bind st ctx.scope span a.T.Expr.ty id value; Stat.assign result (ptr (Expr.Address id)) ]
      in
      ptr (Expr.Expand { label; body; result = Some result })

(* Experimental pooled variants (Type_layout.pooled). The address of the
   node, or of the payload inside one, that a place in a pool names: a
   [Node] local, or a member of one, a link followed to its node. [None]
   for a place outside every pool. *)
and node_place st ctx span (e : T.Expr.t) : Expr.t option =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with Node id -> Some (local_ptr id) | _ -> None)
  | T.Expr.Field { target; slot; _ } -> (
      match node_place st ctx span target with
      | None -> None
      | Some base ->
          let owner = Tty.strip_mode target.T.Expr.ty in
          let within = node_ty st span owner in
          let at = ptr (Expr.Offset { base; within; path = [ member_index st owner slot ] }) in
          if pooled st e.T.Expr.ty then Some (ptr (Expr.Runtime { fn = Runtime.Link; args = [ at ] }))
          else Some at)
  | _ -> None

(* The node a pooled variant's place or fresh root has at its top: a place
   in a pool is one, and a root's is found through its pool. *)
and view st ctx span (e : T.Expr.t) : Expr.t =
  match node_place st ctx span e with
  | Some p -> p
  | None ->
      let t = Tty.strip_mode e.T.Expr.ty in
      let size = fst (Nodes.Ty.size_align (node_shape st span t)) in
      let size = { Expr.node = Expr.Int (Int64.of_int size); ty = Nodes.Ty.I64 } in
      ptr (Expr.Runtime { fn = Runtime.Pool_root; args = [ lend st ctx span e; size ] })

(* A pooled variant built as a value: a pool of its own, made here, that
   [into] builds it in. *)
and pool_value st ctx span (e : T.Expr.t) =
  let handle = ty st span (Tty.strip_mode e.T.Expr.ty) in
  let h = fresh st and label = fresh st and result = fresh st in
  let address = ptr (Expr.Address h) in
  let body =
    [
      Stat.Let { id = h; value = { Expr.node = Expr.Runtime { fn = Runtime.List_new; args = [] }; ty = handle } };
      Stat.Eval { Expr.node = Expr.Runtime { fn = Runtime.Pool_new; args = [ address ] }; ty = Nodes.Ty.Void };
      Stat.Eval (into st ctx span address e);
      Stat.assign result { Expr.node = Expr.Local h; ty = handle };
    ]
  in
  { Expr.node = Expr.Expand { label; body; result = Some result }; ty = handle }

(* Experimental pooled variants: the pooled variant [e] built at the end of
   the pool at [dest], and where its top node is there. A case is built
   node by node, its subtrees first; a call to a function that pours its
   result (Lower_calls.pours) is given the pool; anything else is made as
   a value and its pool copied on. *)
and into st ctx span dest (e : T.Expr.t) : Expr.t =
  let t = Tty.strip_mode e.T.Expr.ty in
  let poured =
    match e.T.Expr.node with
    | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; handler = None; _ } -> (
        match verb_of st id instance with Some v when Lower_calls.pours st span v -> Some v | _ -> None)
    | _ -> None
  in
  match (e.T.Expr.node, poured) with
  | T.Expr.Case { case; payload }, _ -> pool_into st ctx span dest t case payload
  | T.Expr.Call { args; _ }, Some v ->
      let args = Lower_calls.arguments walk st ctx span v (Lower_calls.passed v args) in
      { Expr.node = Expr.Call { fn = symbol st v; args = args @ [ dest ] }; ty = Nodes.Ty.I64 }
  | _ ->
      let h = fresh st and label = fresh st and result = fresh st in
      let size = fst (Nodes.Ty.size_align (node_shape st span t)) in
      let value = moved st ctx span t e in
      let body =
        [
          Stat.Let { id = h; value };
          Stat.assign result
            {
              Expr.node =
                Expr.Runtime
                  {
                    fn = Runtime.Pool_append;
                    args = [ dest; ptr (Expr.Address h); { Expr.node = Expr.Int (Int64.of_int size); ty = Nodes.Ty.I64 } ];
                  };
              ty = Nodes.Ty.I64;
            };
        ]
      in
      { Expr.node = Expr.Expand { label; body; result = Some result }; ty = Nodes.Ty.I64 }

(* The values a cycle struct payload's members are made from, in the order
   they are evaluated, each with the member it fills: the fields of an
   `init`, or the arguments of a field constructor whose body returns its
   parameters as fields, one each. [None] for any other payload. *)
and payload_pieces st (payload : T.Expr.t) : (int * T.Expr.t) list option =
  (* The arguments, by parameter index, of a field constructor whose body
     returns its parameters as the fields of an `init`, one each. *)
  let through id instance (given : (int * T.Expr.t) list) =
    match verb_of st id instance with
    | Some v -> (
        match v.body.T.Block.stats with
        | [ { T.Stat.node = T.Stat.Return { T.Expr.node = T.Expr.Init fields; _ }; _ } ]
          when List.length fields = List.length v.params && List.length given = List.length v.params ->
            let slot_of (p : T.Local.t) =
              List.find_map
                (fun (f : T.Field_value.t) ->
                  match f.T.Field_value.value.T.Expr.node with
                  | T.Expr.Var (T.Name_ref.Local l) when l.T.Local.id = p.T.Local.id -> Some f.T.Field_value.slot
                  | _ -> None)
                fields
            in
            let pieces = List.map (fun (i, a) -> Option.map (fun slot -> (slot, a)) (slot_of (List.nth v.params i))) given in
            if List.for_all Option.is_some pieces then Some (List.map Option.get pieces) else None
        | _ -> None)
    | None -> None
  in
  let values args =
    let given = List.mapi (fun i a -> match a with T.Arg.Value a -> Some (i, a) | T.Arg.Block _ -> None) args in
    if List.for_all Option.is_some given then Some (List.map Option.get given) else None
  in
  match payload.T.Expr.node with
  | T.Expr.Init fields -> Some (List.map (fun (f : T.Field_value.t) -> (f.T.Field_value.slot, f.T.Field_value.value)) fields)
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler = None }
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance; _ }; args; handler = None } ->
      Option.bind (values args) (through id instance)
  | T.Expr.Construct_fields { ctor = { owner = S.Declared id; instance; _ }; fields; handler = None } ->
      through id instance (List.map (fun (f : T.Field_value.t) -> (f.T.Field_value.slot, f.T.Field_value.value)) fields)
  | _ -> None

(* A case of the pooled variant [t] built at the end of the pool at [dest]:
   the subtrees its links name first, then its node, whose links the
   runtime writes (runtime/list.c). Where its node is. *)
and pool_into st ctx span dest t case payload =
  let int k = { Expr.node = Expr.Int (Int64.of_int k); ty = Nodes.Ty.I64 } in
  let i64 id = { Expr.node = Expr.Local id; ty = Nodes.Ty.I64 } in
  let index = case_index st span t case in
  let c = payload_type st span t case in
  let node = node_shape st span t in
  let size = fst (Nodes.Ty.size_align node) in
  let zero = { Expr.node = Expr.Int 0L; ty = Nodes.Ty.I32 } in
  let link_at path = Nodes.Ty.payload_at node + path in
  let lets, children, inline =
    if pooled st c then
      let o = fresh st in
      ([ Stat.Let { id = o; value = into st ctx span dest payload } ], [ (i64 o, link_at 0) ], zero)
    else if cycle_struct st c then begin
      let outer = ty st span c and inner = node_ty st span c in
      let ms = Nodes.Ty.members inner in
      let offsets = Nodes.Ty.member_offsets inner in
      let members =
        match definition st (Tty.strip_mode c) with
        | Some (T.Decl.Struct ms, _) -> List.map snd ms
        | _ -> []
      in
      match payload_pieces st payload with
      | Some pieces ->
          let made = List.map (fun (slot, e) -> (member_index st c slot, e, fresh st)) pieces in
          let lets =
            List.map
              (fun (i, e, id) ->
                let m = List.nth members i in
                Stat.Let { id; value = (if pooled st m then into st ctx span dest e else moved st ctx span m e) })
              made
          in
          let local_of i = List.find_map (fun (j, _, id) -> if i = j then Some id else None) made in
          let children = ref [] in
          let record =
            List.mapi
              (fun i m ->
                let id = Option.get (local_of i) in
                if pooled st m then begin
                  children := (i64 id, link_at (List.nth offsets i)) :: !children;
                  (i, zero)
                end
                else (i, { Expr.node = Expr.Local id; ty = List.nth ms i }))
              members
          in
          (lets, List.rev !children, { Expr.node = Expr.Record record; ty = inner })
      | None ->
          let held = fresh st in
          let held_v = { Expr.node = Expr.Local held; ty = outer } in
          let lets = ref [ Stat.Let { id = held; value = moved st ctx span c payload } ] in
          let children = ref [] in
          let record =
            List.mapi
              (fun i m ->
                if pooled st m then begin
                  let o = fresh st in
                  let at = ptr (Expr.Offset { base = ptr (Expr.Address held); within = outer; path = [ i ] }) in
                  let msize = fst (Nodes.Ty.size_align (node_shape st span (Tty.strip_mode m))) in
                  lets :=
                    !lets
                    @ [
                        Stat.Let
                          {
                            id = o;
                            value =
                              { Expr.node = Expr.Runtime { fn = Runtime.Pool_append; args = [ dest; at; int msize ] }; ty = Nodes.Ty.I64 };
                          };
                      ];
                  children := (i64 o, link_at (List.nth offsets i)) :: !children;
                  (i, zero)
                end
                else (i, { Expr.node = Expr.Member { value = held_v; index = i }; ty = List.nth ms i }))
              members
          in
          (!lets, List.rev !children, { Expr.node = Expr.Record record; ty = inner })
    end
    else ([], [], moved st ctx span c payload)
  in
  if List.length children > 4 then refuse span "pooled variants: a node with more than four links";
  let made = fresh st and label = fresh st and result = fresh st in
  let pairs =
    List.concat_map (fun (o, l) -> [ o; int l ]) children
    @ List.concat (List.init (4 - List.length children) (fun _ -> [ int 0; int 0 ]))
  in
  let push =
    Expr.Runtime
      { fn = Runtime.Pool_push; args = [ dest; ptr (Expr.Address made); int size; int (List.length children) ] @ pairs }
  in
  let body =
    lets
    @ [
        Stat.Let { id = made; value = { Expr.node = Expr.Case { index; payload = inline }; ty = node } };
        Stat.assign result { Expr.node = push; ty = Nodes.Ty.I64 };
      ]
  in
  { Expr.node = Expr.Expand { label; body; result = Some result }; ty = Nodes.Ty.I64 }

(* ---------------------------------------------------------------------- *)
(* Blocks, statements and places                                          *)
(* ---------------------------------------------------------------------- *)

(* L8: a block that holds a reference-type local has an arena of its own.
   [enter] runs first, in the block's scope: a function's `^T` parameters
   are held there, so the body's drain ends any it did not move on. *)
and block ?(enter = fun _ -> []) st ctx (b : T.Block.t) =
  let scope = { arena = None; settles = []; wants = [] } in
  let entered = enter scope in
  let body = entered @ List.concat_map (stat st { ctx with scope }) b.T.Block.stats in
  (* A spawned call that can abort or exit, and that nothing has read,
     settles where the block ends. *)
  let body = body @ List.concat_map (fun settle -> settle ()) (List.rev scope.settles) in
  close st scope body

(* A block argument's code, where it was written. An exit ends this run of
   it (docs/spec-divergences.md §6). *)
and code st ctx span (arg : T.Arg.t) =
  let run ctx b =
    let label = fresh st in
    let left = ref false in
    let finish _ =
      left := true;
      [ Stat.Leave label ]
    in
    let body = block st { ctx with finish } b in
    if !left then
      [ Stat.Eval { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void } ]
    else body
  in
  match arg with
  | T.Arg.Block b -> run ctx b
  | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
      match lookup ctx span l with
      | Code c -> run c.ctx c.block
      | _ -> Diagnostic.bug ~span "lowering expected a block here")
  | T.Arg.Value _ -> Diagnostic.bug ~span "lowering expected a block here"

and stat st ctx (s : T.Stat.t) : Stat.t list =
  let span = s.T.Stat.span in
  match s.T.Stat.node with
  (* A local bound to a spawned call waits for it where it is read. *)
  (* A local's type may differ from the call's only as storage that holds
     it (Tty.held_as): a function type's `mut`, which changes nothing it
     holds. *)
  | T.Stat.Let { local; value = { T.Expr.node = T.Expr.Spawn call; _ } } ->
      if ty st span local.T.Local.ty <> ty st span call.T.Expr.ty then
        Diagnostic.bug ~span "lowering expected a spawned call bound to a local of the type it returns";
      let stats, future = Lower_spawn.spawn walk st ctx span call in
      Hashtbl.replace ctx.env local.T.Local.id future;
      stats
  | T.Stat.Spawn e ->
      fst (Lower_spawn.spawn walk st ctx span e)
  | T.Stat.Let { local; value } ->
      let value = moved st ctx span local.T.Local.ty value in
      let id = fresh st in
      Hashtbl.replace ctx.env local.T.Local.id (slot st local.T.Local.ty id);
      [ bind_local st ctx.scope local id value ]
  | T.Stat.Assign { target; value } when Lower_calls.subscripted target ->
      (* The destination's operands, then the value, and only then is the
         destination located (memory.md §2.12): a value that grows the list
         the destination is an element of has moved it by then. *)
      let pins, target = Lower_calls.pinned walk st ctx span target in
      let t = target.T.Expr.ty in
      let id = fresh st in
      let v = stored_ref ~slot:(ref_slot t) (moved st ctx span t value) in
      let read = { Expr.node = Expr.Local id; ty = v.Expr.ty } in
      let address =
        match storage st ctx span target with
        | Some a -> a
        | None -> refuse span "lowering does not store into this place yet"
      in
      pins
      @ [ Stat.Let { id; value = v } ]
      @
      if held st span t then [ Stat.Overwrite { address; value = read; layout = layout st span t } ]
      else [ Stat.Store { address; value = read } ]
  | T.Stat.Assign { target; value } -> (
      let t = target.T.Expr.ty in
      let address () =
        match storage st ctx span target with
        | Some a -> a
        | None -> refuse span "lowering does not store into this place yet"
      in
      if held st span t then
        (* An owner, or a value that owns blocks, is replaced in place
           (memory.md §2.2): at the same address, each boxed member's block
           kept, and the rest of what it replaces returning its blocks. *)
        let address = address () in
        let value = moved st ctx span t value in
        [ Stat.Overwrite { address; value; layout = layout st span t } ]
      else
        (* A reference stored in a member is in its 32-bit form (Ref32). *)
        let stored v =
          match target.T.Expr.node with T.Expr.Var _ -> v | _ -> stored_ref ~slot:(ref_slot t) v
        in
        match place st ctx span target with
        | Some place -> [ Stat.Assign { place; value = stored (moved st ctx span t value) } ]
        | None ->
            let address = address () in
            [ Stat.Store { address; value = stored (moved st ctx span t value) } ])
  | T.Stat.Expr
      {
        T.Expr.node =
          T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None };
        _;
      }
    when String.length spelling > 13 && String.sub spelling 0 13 = "@controlflow$" -> (
      match (spelling, args) with
      | "@controlflow$branch", [ T.Arg.Value cond; body ] ->
          let cond = expr st ctx cond in
          [ Stat.If { cond; body = code st ctx span body } ]
      | "@controlflow$repeat", [ T.Arg.Value count; body ] ->
          let count = expr st ctx count in
          [ Stat.Repeat { count; body = code st ctx span body } ]
      | "@controlflow$exitFromCall", [] -> ctx.exit_call span
      | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling))
  (* A fresh value nothing keeps is held here, so the drain ends it. One
     that owns no block has nothing to end, so nothing holds it: such as
     the element a discarded `swapRemove` moves out. *)
  | T.Stat.Expr e when owns st span e.T.Expr.ty && not (is_place e) ->
      [ bind st ctx.scope span e.T.Expr.ty (fresh st) (expr st ctx e) ]
  | T.Stat.Expr e -> [ Stat.Eval (expr st ctx e) ]
  | T.Stat.Return e -> (
      match ctx.exit with
      | Function when Option.is_some st.dest && pooled st (Tty.strip_mode st.ret) ->
          [ Stat.Return (st.returns (into st ctx span (local_ptr (Option.get st.dest)) e)) ]
      | Function ->
          [ Stat.Return (st.returns (escape st span st.ret None (moved st ctx span st.ret e))) ]
      | Leave { label; result; ret } ->
          leave label result (escape st span ret (Some label) (moved st ctx span ret e)))
  (* An abort hands its value to the caller's handler as a return hands it
     to the caller, at the declared abort type: an `&T` abort type takes a
     reference, whatever the expression's own type. *)
  | T.Stat.Abort e -> ctx.abort span (escape st span st.aborts None (moved st ctx span st.aborts e))
  | T.Stat.Resolve e -> (
      match ctx.resolve with
      | Some resolve -> resolve e.T.Expr.ty (moved st ctx span e.T.Expr.ty e)
      | None -> Diagnostic.bug ~span "lowering: a `resolve` outside a handler")

(* Where an assignment stores: a local, or the place a `mut` subject points
   at, and the members below it. A struct of one member adds no step. A
   place reached through a reference has no local to start from, and is
   stored through its address instead. *)
and place st ctx span (target : T.Expr.t) : Expr.place option =
  match target.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      let t = ty st span l.T.Local.ty in
      match lookup ctx span l with
      | Slot local -> Some { Expr.local; deref = false; ty = t; path = [] }
      | Pointer local -> Some { local; deref = true; ty = t; path = [] }
      | Node _ -> refuse span "pooled variants: a store into a node"
      (* A spawned call's result is stored through its address, once the
         call has returned. *)
      | Future _ -> None
      | _ -> Diagnostic.bug ~span "lowering expected a place here")
  | T.Expr.Field { target = inner; _ } when Tty.is_ref inner.T.Expr.ty -> None
  | T.Expr.Field { target = inner; slot; _ } ->
      Option.map
        (fun (p : Expr.place) ->
          if collapsed st inner.T.Expr.ty then p
          else { p with path = p.path @ [ member_index st inner.T.Expr.ty slot ] })
        (place st ctx span inner)
  | _ -> None

(* The walk, as the modules outside its recursion take it. *)
and walk =
  {
    expr;
    value_of;
    addr;
    borrow;
    lend;
    reference_to;
    moved;
    view;
    is_place;
    block;
    primitive = (fun st -> Lower_data.primitive walk st);
  }
