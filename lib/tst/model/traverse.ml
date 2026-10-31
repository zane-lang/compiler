(* Walking the typed syntax tree, for every analysis over it: what each
   expression and statement is made of. An analysis keeps only what is its
   own, such as which parts it goes into and what it does at each node. *)

module T = Nodes

(* The parts of an expression, by the context each is in: the same as the
   expression's, a handler's body, a block argument, or a lambda's body. *)
type part =
  | Same of T.Expr.t
  | Arm of T.Block.t
  | Handler of T.Block.t
  | Block of T.Block.t
  | Lambda of T.Block.t

(* A string literal's interpolated values, in written order. *)
let interpolations pieces =
  List.filter_map (function T.Expr.Interpolation v -> Some v | T.Expr.Fragment _ -> None) pieces

let parts (e : T.Expr.t) =
  let same es = List.map (fun x -> Same x) es in
  let handler = function Some (h : T.Handler.t) -> [ Handler h.T.Handler.body ] | None -> [] in
  let args =
    List.map (function T.Arg.Value v -> Same v | T.Arg.Block b -> Block b)
  in
  let fields = List.map (fun (f : T.Field_value.t) -> Same f.T.Field_value.value) in
  match e.T.Expr.node with
  | T.Expr.Call { args = a; handler = h; _ } | T.Expr.Construct { args = a; handler = h; _ } ->
      args a @ handler h
  | T.Expr.Call_value { callee; args = a; handler = h } -> (Same callee :: args a) @ handler h
  | T.Expr.Construct_fields { fields = fs; handler = h; _ } -> fields fs @ handler h
  | T.Expr.Init fs -> fields fs
  | T.Expr.Array_lit es -> same es
  | T.Expr.Map_lit kvs -> List.concat_map (fun (k, v) -> same [ k; v ]) kvs
  | T.Expr.Case { payload = v; _ }
  | T.Expr.Field { target = v; _ }
  | T.Expr.Map_read { target = v; _ }
  | T.Expr.Spawn v
  | T.Expr.Coerce { value = v; _ } ->
      [ Same v ]
  | T.Expr.Case_read { target; handler = h; _ } -> Same target :: handler (Some h)
  | T.Expr.Subscript { target; args = a; _ } -> same (target :: a)
  | T.Expr.Op { left; right; handler = h; _ } -> same [ left; right ] @ handler h
  | T.Expr.Flip { value; handler = h; _ } -> Same value :: handler h
  | T.Expr.Match { scrutinees; arms; handler = h } ->
      same scrutinees @ List.map (fun (a : T.Arm.t) -> Arm a.T.Arm.body) arms @ handler h
  | T.Expr.Lambda { body; _ } -> [ Lambda body ]
  | T.Expr.Text_lit pieces -> same (interpolations pieces)
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Bool_lit _
  | T.Expr.Var _ | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Foreign_global _ | T.Expr.Invalid ->
      []

let stat_exprs (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e | T.Stat.Return e | T.Stat.Resolve e -> [ e ]
  | T.Stat.Let { value; _ } -> [ value ]
  | T.Stat.Assign { target; value } -> [ target; value ]
