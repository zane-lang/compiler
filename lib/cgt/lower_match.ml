(* Lowering's `match`es, handlers and case reads (docs/design/lowering.md):
   what switches on a sum's case, and the handler that runs where an
   operation aborted. The walk in [Lower] is [w]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Build

(* A handler is a block of its own, so an abort value of a reference type
   is held in the handler's arena, which is innermost wherever the handler
   runs. *)
let handle w ?resolve ?dropped st ctx (h : T.Handler.t) label result span (value : Expr.t) =
  let scope = { arena = None; settles = []; wants = [] } in
  let bind =
    match (h.T.Handler.binder, dropped) with
    | Some l, _ ->
        let id = fresh st in
        Hashtbl.replace ctx.env l.T.Local.id (slot st l.T.Local.ty id);
        [ bind_local st scope l id value ]
    (* An abort value no binder names, of type [dropped], is still held
       here when it is an owner or owns a block, so the drain ends it. *)
    | None, Some t when held st span t -> [ bind st scope span t (fresh st) value ]
    | None, _ -> [ Stat.Eval value ]
  in
  let resolve =
    match resolve with
    | Some r -> r
    | None -> fun t value -> leave label result (escape st span t (Some label) value)
  in
  let inner = { ctx with resolve = Some resolve; scope } in
  let body = bind @ w.block st inner h.T.Handler.body in
  close st scope body

(* L13. The scrutinees are reached once, in order, and a switch on each one's
   tag nests inside the last; the semantic pass wrote one arm per
   combination of cases, so each arm is lowered once, where its combination
   is reached. A binder is the address of its case's payload, in the
   scrutinee's own storage when it is a place, so a write through it is a
   write to the payload. A `return` in an arm is the `match`'s value. *)
let match_ w st ctx span scrutinees (arms : T.Arm.t list) handler ret =
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  let stored =
    List.map
      (fun (e : T.Expr.t) ->
        let tsty = Tty.strip_mode e.T.Expr.ty in
        let within = if pooled st tsty then node_shape st span tsty else ty st span tsty in
        let lets, pointer =
          match (if pooled st tsty then Some (w.view st ctx span e) else w.addr st ctx span e) with
          | Some p ->
              let pointer = fresh st in
              ([ Stat.Let { id = pointer; value = p } ], pointer)
          | None ->
              let value = w.value_of st ctx e in
              let id = fresh st in
              let pointer = fresh st in
              (* A fresh instance is held here, like any other. *)
              let at = Stat.Let { id = pointer; value = ptr (Expr.Address id) } in
              ([ bind st ctx.scope span tsty id value; at ], pointer)
        in
        let whole = { Expr.node = Expr.Deref (local_ptr pointer); ty = within } in
        (pointer, sum_of st span tsty whole, tsty, lets))
      scrutinees
  in
  (* An arm's abort is the `match`'s (error-handling.md §3.5). *)
  let abort = match handler with Some h -> handle w st ctx h label result | None -> ctx.abort in
  let inner = { ctx with exit = Leave { label; result; ret }; abort } in
  let selects chosen (a : T.Arm.t) =
    List.map (fun (p : T.Pattern.t) -> p.T.Pattern.case) a.patterns = chosen
  in
  let arm chosen =
    match List.find_opt (selects chosen) arms with
    | None -> Diagnostic.bug ~span "lowering found no arm for a combination of cases"
    | Some a ->
        let binds =
          List.concat
            (List.map2
               (fun (p : T.Pattern.t) (pointer, _, tsty, _) ->
                 match p.T.Pattern.binder with
                 | None -> []
                 | Some l ->
                     let index = case_index st span tsty p.case in
                     let path = [ index ] in
                     let c = payload_type st span tsty p.case in
                     let bound = fresh st in
                     if pooled st tsty then begin
                       (* A pooled variant's payload is inline in its node,
                          and one of its own type is a link. *)
                       let within = node_shape st span tsty in
                       let at = ptr (Expr.Offset { base = local_ptr pointer; within; path }) in
                       let value =
                         if pooled st c then ptr (Expr.Runtime { fn = Runtime.Link; args = [ at ] }) else at
                       in
                       Hashtbl.replace ctx.env l.T.Local.id
                         (if pooled st c || cycle_struct st c then Node bound else Pointer bound);
                       [ Stat.Let { id = bound; value } ]
                     end
                     else
                     let within = ty st span tsty in
                     let at = ptr (Expr.Offset { base = local_ptr pointer; within; path }) in
                     (* A boxed payload is in its block. *)
                     let boxed = boxed st tsty c in
                     let value = if boxed then box_block at else at in
                     Hashtbl.replace ctx.env l.T.Local.id (Pointer bound);
                     [ Stat.Let { id = bound; value } ])
               a.patterns stored)
        in
        binds @ w.block st inner a.body
  in
  let rec dispatch chosen = function
    | [] -> arm (List.rev chosen)
    | (_, source, tsty, _) :: rest ->
        let cases =
          List.mapi (fun i c -> (i, dispatch (c :: chosen) rest)) (cases st span tsty)
        in
        [ Stat.Switch { value = source; cases } ]
  in
  let lets = List.concat_map (fun (_, _, _, l) -> l) stored in
  { Expr.node = Expr.Expand { label; body = lets @ dispatch [] stored; result }; ty = t }

(* An enum map read is a switch on the member, each case giving its entry. *)
let map_read w st ctx span target map ret =
  match Hashtbl.find_opt st.maps map with
  | None -> Diagnostic.bug ~span "lowering found no enum map here"
  | Some (enum, entries) ->
      let t = ty st span ret in
      let label = fresh st in
      let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
      let value = w.value_of st ctx target in
      let id = fresh st in
      let entry_ctx = { (constant_ctx ()) with expanding = ctx.expanding } in
      let cases =
        List.mapi
          (fun i member ->
            match List.assoc_opt member entries with
            | Some e -> (i, leave label result (w.expr st entry_ctx e))
            | None -> Diagnostic.bug ~span (Printf.sprintf "lowering: the enum map has no entry for `%s`" member))
          (cases st span enum)
      in
      {
        Expr.node =
          Expr.Expand
            {
              label;
              body =
                [
                  Stat.Let { id; value };
                  Stat.Switch
                    {
                      value = sum_of st span enum { Expr.node = Expr.Local id; ty = value.Expr.ty };
                      cases;
                    };
                ];
              result;
            };
        ty = t;
      }

(* A handler, run where its operation aborted: its binder holds the abort
   value, and a `resolve` gives the operation its value and goes past it. *)

(* A case read of an owner, or of a value that owns a block, as a place: the
   payload where the variant holds it when the case is live, or else a slot
   reserved in this scope before the read, which the handler's `resolve`
   fills. Either way what the read gives has one owner, and a copy of it
   owns blocks of its own. *)
let case_place w st ctx span (target : T.Expr.t) case handler ret =
  if pooled st (Tty.strip_mode target.T.Expr.ty) then refuse span "pooled variants: a case read";
  let t = ty st span ret in
  let tsty = Tty.strip_mode target.T.Expr.ty in
  let within = ty st span tsty in
  let label = fresh st in
  let result = fresh st in
  let base = fresh st in
  let spare = fresh st in
  let l = layout st span ret in
  let live = case_index st span tsty case in
  let whole = { Expr.node = Expr.Deref (local_ptr base); ty = within } in
  let payload =
    let path = [ live ] in
    let at = ptr (Expr.Offset { base = local_ptr base; within; path }) in
    if boxed st tsty ret then box_block at else at
  in
  let cases =
    List.mapi
      (fun i _ -> if i = live then (i, leave label (Some result) payload) else (i, []))
      (cases st span tsty)
  in
  let resolve _ value =
    [
      Stat.Place { address = ptr (Expr.Address spare); value; layout = l };
      Stat.assign result (ptr (Expr.Address spare));
      Stat.Leave label;
    ]
  in
  let otherwise = handle w ~resolve st ctx handler label (Some result) span unit_ in
  let body =
    [
      Stat.Reserve { id = spare; scope = arena st ctx.scope; ty = t; layout = l };
      Stat.Let { id = base; value = w.lend st ctx span target };
      Stat.Switch { value = sum_of st span tsty whole; cases };
    ]
    @ otherwise
  in
  ptr (Expr.Expand { label; body; result = Some result })

(* A case read is its payload when the case is live, and runs its handler
   when another is (adt.md §5.2). The other cases fall through to it. *)
let case_read w st ctx span (target : T.Expr.t) case handler ret =
  if pooled st (Tty.strip_mode target.T.Expr.ty) then refuse span "pooled variants: a case read";
  let t = ty st span ret in
  if held st span ret then
    { Expr.node = Expr.Deref (case_place w st ctx span target case handler ret); ty = t }
  else
    let label = fresh st in
    let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
    let value = w.borrow st ctx span target in
    let id = fresh st in
    let live = case_index st span target.T.Expr.ty case in
    let tsty = Tty.strip_mode target.T.Expr.ty in
    let source = sum_of st span tsty { Expr.node = Expr.Local id; ty = value.Expr.ty } in
    let payload i = { Expr.node = Expr.Payload { value = source; index = i }; ty = t } in
    let cases =
      List.mapi
        (fun i _ -> if i = live then (i, leave label result (payload i)) else (i, []))
        (cases st span target.T.Expr.ty)
    in
    let otherwise = handle w st ctx handler label result span unit_ in
    let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] @ otherwise in
    { Expr.node = Expr.Expand { label; body; result }; ty = t }
