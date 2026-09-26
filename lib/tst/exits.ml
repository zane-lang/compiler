(* Exits (control-flow.md §4.2, as docs/spec-divergences.md §11 reads it): an
   analysis over the finished TST (docs/semantics.md D1).

   A verb exits when `@controlflow$exitFromCall` is in its own frame: its
   body, or a block written there. A call to it ends the run of the block the
   call is written in. So such a call must be written in a block, and in one
   that yields nothing: a function body, or a block that yields a value,
   cannot end without the value it returns or yields. *)

module T = Nodes
module S = Signature

(* The parts of an expression, by the context each is in: the same as the
   expression's, a handler's body, a block argument, or a lambda's body. *)
type part = Same of T.Expr.t | Arm of T.Block.t | Handler of T.Block.t | Block of T.Block.t | Lambda

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
  | T.Expr.Ref v
  | T.Expr.Spawn v
  | T.Expr.Coerce { value = v; _ } ->
      [ Same v ]
  | T.Expr.Case_read { target; handler = h; _ } -> Same target :: handler (Some h)
  | T.Expr.Subscript { target; args = a; _ } -> same (target :: a)
  | T.Expr.Op { left; right; handler = h; _ } -> same [ left; right ] @ handler h
  | T.Expr.Flip { value; handler = h; _ } -> Same value :: handler h
  | T.Expr.Match { scrutinees; arms; handler = h } ->
      same scrutinees @ List.map (fun (a : T.Arm.t) -> Arm a.T.Arm.body) arms @ handler h
  | T.Expr.Lambda _ -> [ Lambda ]
  | T.Expr.Integer_lit _ | T.Expr.Decimal_lit _ | T.Expr.Text_lit _ | T.Expr.Bool_lit _
  | T.Expr.Var _ | T.Expr.Type_arg _ | T.Expr.Enum_member _ | T.Expr.Invalid ->
      []

let stat_exprs (s : T.Stat.t) =
  match s.T.Stat.node with
  | T.Stat.Expr e | T.Stat.Spawn e | T.Stat.Abort e | T.Stat.Return e | T.Stat.Resolve e -> [ e ]
  | T.Stat.Let { value; _ } -> [ value ]
  | T.Stat.Assign { target; value } -> [ target; value ]

(* Whether `@controlflow$exitFromCall` is in a block's own frame. *)
let rec block (b : T.Block.t) =
  List.exists (fun s -> List.exists expr (stat_exprs s)) b.T.Block.stats

and expr (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee = { owner = S.Intrinsic "@controlflow$exitFromCall"; _ }; _ } -> true
  | _ ->
      List.exists
        (function Same x -> expr x | Arm b | Handler b | Block b -> block b | Lambda -> false)
        (parts e)

(* Whether a block argument yields a value: whether it has a `resolve` of its
   own, one not in a handler or another block argument. *)
let rec yields (b : T.Block.t) =
  List.exists
    (fun (s : T.Stat.t) ->
      match s.T.Stat.node with
      | T.Stat.Resolve _ -> true
      | _ -> List.exists yields_in (stat_exprs s))
    b.T.Block.stats

and yields_in e =
  List.exists (function Same x -> yields_in x | Arm b -> yields b | _ -> false) (parts e)

(* The verb a call names, when it names a declared one. *)
let callee (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee = r; _ }
  | T.Expr.Construct { ctor = r; _ }
  | T.Expr.Construct_fields { ctor = r; _ }
  | T.Expr.Op { impl = r; _ }
  | T.Expr.Flip { impl = r; _ }
  | T.Expr.Coerce { ctor = r; _ }
  | T.Expr.Subscript { impl = r; _ } -> (
      match r.T.Verb_ref.owner with S.Declared id -> Some (id, r.T.Verb_ref.name) | _ -> None)
  | _ -> None

(* Where a call is written: in no block, in one that yields nothing, or in
   one that yields a value. *)
type where = Body | Plain | Yielding

let run (p : T.Program.t) =
  let exiting = Hashtbl.create 8 in
  let bodies =
    List.concat_map
      (fun (pkg : T.Package.t) ->
        List.filter_map
          (fun (d : T.Decl.t) ->
            match d.T.Decl.node with
            | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> Some (d.T.Decl.id, body)
            | _ -> None)
          pkg.T.Package.decls)
      p.T.Program.packages
    @ List.map
        (fun (i : T.Instance.t) -> (i.T.Instance.decl, i.T.Instance.body))
        p.T.Program.instances
  in
  List.iter (fun (id, b) -> if block b then Hashtbl.replace exiting id ()) bodies;
  let rec walk_block where (b : T.Block.t) =
    List.iter (fun s -> List.iter (walk where) (stat_exprs s)) b.T.Block.stats
  and walk where (e : T.Expr.t) =
    (match (callee e, where) with
    | Some (id, name), (Body | Yielding) when Hashtbl.mem exiting id ->
        Env.error e.T.Expr.span
          (Printf.sprintf
             "`%s` can exit, which ends the block its call is written in; %s" name
             (if where = Body then "this call is in no block"
              else "this block yields a value, so it cannot end without one"))
    | _ -> ());
    List.iter
      (function
        | Same x -> walk where x
        | Arm b | Handler b -> walk_block where b
        | Block b -> walk_block (if yields b then Yielding else Plain) b
        | Lambda -> ())
      (parts e)
  in
  List.iter (fun (_, b) -> walk_block Body b) bodies
