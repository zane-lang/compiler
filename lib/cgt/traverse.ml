(* Walking and rewriting the code-generation tree, for every pass over it:
   what each node is made of, a walk over every node, and a rewrite. A pass
   that only reads the tree uses [expr_parts], [stat_parts] or a walk; [map_*]
   rebuilds every node it visits, so it is for a pass that changes the tree. *)

open Nodes

(* What an expression or a statement is made of: the expressions directly
   in it, and the statement lists directly in it, each in the order it
   runs. *)
let expr_parts (e : Expr.t) : Expr.t list * Stat.t list list =
  match e.Expr.node with
  | Expr.Int _ | Expr.Float _ | Expr.Bool _ | Expr.Text _ | Expr.Unit | Expr.Local _
  | Expr.Address _ | Expr.Layout _ | Expr.Function _ | Expr.Global _ ->
      ([], [])
  | Expr.Deref x | Expr.Flip x | Expr.Convert x | Expr.Snapshot x -> ([ x ], [])
  | Expr.Call { args; _ } | Expr.Runtime { args; _ } | Expr.Math { args; _ } | Expr.Foreign_call { args; _ } ->
      (args, [])
  | Expr.Call_value { fn; args } -> (fn :: args, [])
  | Expr.Binary { left; right; _ } -> ([ left; right ], [])
  | Expr.Expand { body; _ } -> ([], [ body ])
  | Expr.Record ms -> (List.map snd ms, [])
  | Expr.Member { value; _ } | Expr.Payload { value; _ } | Expr.Case { payload = value; _ }
  | Expr.Copy { value; _ } | Expr.Box { value; _ } | Expr.Escape { value; _ } ->
      ([ value ], [])
  | Expr.Offset { base; _ } -> ([ base ], [])
  | Expr.Take { address; _ } -> ([ address ], [])

let stat_parts (s : Stat.t) : Expr.t list * Stat.t list list =
  match s with
  | Stat.Let { value; _ } | Stat.Hold { value; _ } | Stat.Assign { value; _ } -> ([ value ], [])
  | Stat.Eval e | Stat.Return e -> ([ e ], [])
  | Stat.Scope { body; _ } -> ([], [ body ])
  | Stat.If { cond; body } -> ([ cond ], [ body ])
  | Stat.Repeat { count; body } -> ([ count ], [ body ])
  | Stat.Switch { value; cases } -> ([ value ], List.map snd cases)
  | Stat.Store { address; value } | Stat.Overwrite { address; value; _ }
  | Stat.Place { address; value; _ } ->
      ([ address; value ], [])
  | Stat.Spawn { args; _ } -> (args, [])
  | Stat.Leave _ | Stat.Reserve _ | Stat.Join _ -> ([], [])

(* Every expression and statement, outermost first. *)
let rec walk_expr ve vs (e : Expr.t) =
  ve e;
  let es, bodies = expr_parts e in
  List.iter (walk_expr ve vs) es;
  List.iter (walk_stats ve vs) bodies

and walk_stats ve vs ss = List.iter (walk_stat ve vs) ss

and walk_stat ve vs (s : Stat.t) =
  vs s;
  let es, bodies = stat_parts s in
  List.iter (walk_expr ve vs) es;
  List.iter (walk_stats ve vs) bodies

let exists_in stats ~expr ~stat =
  let found = ref false in
  walk_stats (fun e -> if expr e then found := true) (fun s -> if stat s then found := true) stats;
  !found

(* A node with [me] applied to each expression directly in it and [ms] to
   each statement list directly in it, in the order [expr_parts] and
   [stat_parts] list them, which is the order they run. *)
let map_expr_parts me ms (e : Expr.t) : Expr.t =
  let node =
    match e.Expr.node with
    | ( Expr.Int _ | Expr.Float _ | Expr.Bool _ | Expr.Text _ | Expr.Unit | Expr.Local _
      | Expr.Address _ | Expr.Layout _ | Expr.Function _ | Expr.Global _ ) as n ->
        n
    | Expr.Deref x -> Expr.Deref (me x)
    | Expr.Flip x -> Expr.Flip (me x)
    | Expr.Convert x -> Expr.Convert (me x)
    | Expr.Snapshot x -> Expr.Snapshot (me x)
    | Expr.Call { fn; args } -> Expr.Call { fn; args = List.map me args }
    | Expr.Runtime { fn; args } -> Expr.Runtime { fn; args = List.map me args }
    | Expr.Foreign_call { thunk; args } -> Expr.Foreign_call { thunk; args = List.map me args }
    | Expr.Math { fn; args } -> Expr.Math { fn; args = List.map me args }
    | Expr.Call_value { fn; args } ->
        let fn = me fn in
        Expr.Call_value { fn; args = List.map me args }
    | Expr.Binary { op; left; right } ->
        let left = me left in
        Expr.Binary { op; left; right = me right }
    | Expr.Expand { label; body; result } -> Expr.Expand { label; body = ms body; result }
    | Expr.Record m -> Expr.Record (List.map (fun (i, x) -> (i, me x)) m)
    | Expr.Member { value; index } -> Expr.Member { value = me value; index }
    | Expr.Payload { value; index } -> Expr.Payload { value = me value; index }
    | Expr.Case { index; payload } -> Expr.Case { index; payload = me payload }
    | Expr.Copy { value; layout } -> Expr.Copy { value = me value; layout }
    | Expr.Box { value; layout } -> Expr.Box { value = me value; layout }
    | Expr.Escape { value; layout; exit } -> Expr.Escape { value = me value; layout; exit }
    | Expr.Offset { base; within; path } -> Expr.Offset { base = me base; within; path }
    | Expr.Take { address; layout } -> Expr.Take { address = me address; layout }
  in
  { e with Expr.node }

let map_stat_parts me ms (s : Stat.t) : Stat.t =
  match s with
  | Stat.Let { id; value } -> Stat.Let { id; value = me value }
  | Stat.Hold h -> Stat.Hold { h with value = me h.value }
  | Stat.Scope { id; body } -> Stat.Scope { id; body = ms body }
  | Stat.Assign { place; value } -> Stat.Assign { place; value = me value }
  | Stat.Eval e -> Stat.Eval (me e)
  | Stat.Return e -> Stat.Return (me e)
  | Stat.If { cond; body } ->
      let cond = me cond in
      Stat.If { cond; body = ms body }
  | Stat.Repeat { count; body } ->
      let count = me count in
      Stat.Repeat { count; body = ms body }
  | Stat.Switch { value; cases } ->
      let value = me value in
      Stat.Switch { value; cases = List.map (fun (i, b) -> (i, ms b)) cases }
  | (Stat.Leave _ | Stat.Reserve _ | Stat.Join _) as s -> s
  | Stat.Store { address; value } ->
      let address = me address in
      Stat.Store { address; value = me value }
  | Stat.Overwrite o ->
      let address = me o.address in
      Stat.Overwrite { o with address; value = me o.value }
  | Stat.Place p ->
      let address = me p.address in
      Stat.Place { p with address; value = me p.value }
  | Stat.Spawn sp -> Stat.Spawn { sp with args = List.map me sp.args }

(* A rewrite, outermost first: [fe] and [fs] replace a node whole, or give
   [None] to keep it and rewrite what is inside it. *)
let rec map_expr fe fs (e : Expr.t) : Expr.t =
  match fe e with Some e -> e | None -> map_expr_parts (map_expr fe fs) (map_stats fe fs) e

and map_stats fe fs ss = List.concat_map (map_stat fe fs) ss

and map_stat fe fs (s : Stat.t) : Stat.t list =
  match fs s with Some ss -> ss | None -> [ map_stat_parts (map_expr fe fs) (map_stats fe fs) s ]
