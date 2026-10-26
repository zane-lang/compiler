(* Exits (control-flow.md §4.2, as docs/spec-divergences.md §7 reads it): an
   analysis over the finished TST (docs/design/semantics.md D1).

   A verb exits when `@controlflow$exitFromCall` is in its own frame: its
   body, or a block written there. A call to it ends the run of the block the
   call is written in. So such a call must be written in a block: a body
   cannot end without the `return` it ends in. A lambda is called through a
   function value, whose type does not say that it exits, so a lambda's own
   frame holds no `@controlflow$exitFromCall` at all. *)

module T = Nodes
module S = Signature

open Traverse

(* Each call to `@controlflow$exitFromCall` in a block's own frame. *)
let rec exits (b : T.Block.t) =
  List.concat_map (fun s -> List.concat_map expr_exits (stat_exprs s)) b.T.Block.stats

and expr_exits (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee = { owner = S.Intrinsic "@controlflow$exitFromCall"; _ }; _ } -> [ e ]
  | _ ->
      List.concat_map
        (function Same x -> expr_exits x | Arm b | Handler b | Block b -> exits b | Lambda _ -> [])
        (parts e)

(* Whether `@controlflow$exitFromCall` is in a block's own frame. *)
let block b = exits b <> []

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


let run env (p : T.Program.t) =
  let exiting = Hashtbl.create 8 in
  let bodies =
    List.concat_map
      (fun (pkg : T.Package.t) ->
        List.filter_map
          (fun (d : T.Decl.t) ->
            match d.T.Decl.node with
            | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> Some (d.T.Decl.id, body)
            (* A constant's value, and an enum map's entries, are walked for
               the lambdas in them. *)
            | T.Decl.Constant { value; _ } ->
                let stat = { T.Stat.node = T.Stat.Expr value; span = value.T.Expr.span } in
                Some (d.T.Decl.id, { T.Block.stats = [ stat ]; span = value.T.Expr.span })
            | T.Decl.Enum_map { entries; _ } ->
                let stat (_, (e : T.Expr.t)) = { T.Stat.node = T.Stat.Expr e; span = e.T.Expr.span } in
                Some (d.T.Decl.id, { T.Block.stats = List.map stat entries; span = d.T.Decl.span })
            | _ -> None)
          pkg.T.Package.decls)
      p.T.Program.packages
    @ List.map
        (fun (i : T.Instance.t) -> (i.T.Instance.decl, i.T.Instance.body))
        p.T.Program.instances
  in
  List.iter (fun (id, b) -> if block b then Hashtbl.replace exiting id ()) bodies;
  (* [in_block]: whether the call is written in a block argument. *)
  let rec walk_block in_block (b : T.Block.t) =
    List.iter (fun s -> List.iter (walk in_block) (stat_exprs s)) b.T.Block.stats
  and walk in_block (e : T.Expr.t) =
    (match callee e with
    | Some (id, name) when Hashtbl.mem exiting id && not in_block ->
        Env.error env e.T.Expr.span
          (Printf.sprintf
             "`%s` can exit, which ends the block its call is written in, and this call is in \
              no block"
             name)
    | _ -> ());
    List.iter
      (function
        | Same x -> walk in_block x
        | Arm b | Handler b -> walk_block in_block b
        | Block b -> walk_block true b
        (* A lambda has a frame of its own, so its body is in no block. A call
           through a function value cannot say that it exits, so the body
           may not (control-flow.md §4.2). *)
        | Lambda b ->
            List.iter
              (fun (x : T.Expr.t) ->
                Env.error env x.T.Expr.span
                  "`@controlflow$exitFromCall` cannot be written in a lambda's body: a call \
                   through a function value cannot say that it exits (control-flow.md §4.2)")
              (exits b);
            walk_block false b)
      (parts e)
  in
  List.iter (fun (_, b) -> walk_block false b) bodies;
  (* The runtime calls the root's `main`, from no block (packages.md §6.2). *)
  match p.T.Program.packages with
  | root :: _ ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature = { S.kind = S.Function; name = "main"; _ }; _ }
            when Hashtbl.mem exiting d.T.Decl.id ->
              Env.error env d.T.Decl.span
                "`main` cannot exit: the runtime calls it from no block for the exit to end"
          | _ -> ())
        root.T.Package.decls
  | [] -> ()
