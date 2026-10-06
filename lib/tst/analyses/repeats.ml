(* Which block arguments run more than once (docs/design/semantics.md §9):
   `@controlflow$repeat`'s body, and a block a verb runs more than once,
   found to a fixed point over every body. A block run at most once sees
   nothing an earlier run of it left behind, which the read-only and spawn
   analyses both rely on. *)

module T = Nodes
module S = Signature

(* The arguments a call passes, by position: a type written where a value
   goes, or a number given to an explicit number parameter, picks the
   instance and passes nothing (generics.md §5.3), so the rest line up with
   the instance's parameters. *)
let passed env callee args =
  let bound =
    match Env.signature_of env callee with
    | Some sg when List.length sg.S.params = List.length args ->
        List.map (fun (p : S.param) -> Option.is_some p.S.binds) sg.S.params
    | _ -> List.map (fun _ -> false) args
  in
  List.combine bound args
  |> List.filter_map (fun (bound, arg) ->
         match arg with
         | T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> None
         | _ -> if bound then None else Some arg)

(* Whether the argument at [i] of a call to [r] is run more than once:
   `@controlflow$repeat`'s body, or a block parameter a verb runs so. *)
let runs_often multi (r : T.Verb_ref.t) i =
  match r.T.Verb_ref.owner with
  | S.Intrinsic "@controlflow$repeat" -> i = 1
  | S.Declared id -> Hashtbl.mem multi (id, i)
  | S.Intrinsic _ -> false

let call_parts env (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } ->
      Some (callee, passed env callee args)
  | _ -> None

(* One pass of the fixed point: a verb runs a block parameter more than once
   when it passes it where it runs more than once, or passes it anywhere from
   inside a block that does. *)
let find_multi env multi bodies =
  let changed = ref false in
  let mark id i =
    if not (Hashtbl.mem multi (id, i)) then begin
      Hashtbl.replace multi (id, i) ();
      changed := true
    end
  in
  List.iter
    (fun (id, (params : T.Local.t list), (body : T.Block.t)) ->
      let param l =
        let rec find i = function
          | [] -> None
          | (p : T.Local.t) :: rest -> if p.T.Local.id = l then Some i else find (i + 1) rest
        in
        find 0 params
      in
      let rec block often (b : T.Block.t) =
        List.iter (fun s -> List.iter (expr often) (Exits.stat_exprs s)) b.T.Block.stats
      and expr often (e : T.Expr.t) =
        (* A function value is not seen into, so it may run a block it is
           given any number of times. *)
        (match e.T.Expr.node with
        | T.Expr.Call_value { args; _ } ->
            List.iter
              (function
                | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
                    match param l.T.Local.id with Some p -> mark id p | None -> ())
                | _ -> ())
              args
        | _ -> ());
        (match call_parts env e with
        | Some (callee, args) ->
            List.iteri
              (fun i a ->
                match a with
                | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
                    match param l.T.Local.id with
                    | Some p when often || runs_often multi callee i -> mark id p
                    | _ -> ())
                | _ -> ())
              args
        | None -> ());
        let blocks =
          match call_parts env e with
          | Some (callee, args) ->
              List.concat
                (List.mapi
                   (fun i a ->
                     match a with T.Arg.Block b -> [ (b, often || runs_often multi callee i) ] | _ -> [])
                   args)
          | None -> (
              match e.T.Expr.node with
              | T.Expr.Call_value { args; _ } ->
                  List.filter_map (function T.Arg.Block b -> Some (b, true) | _ -> None) args
              | _ -> [])
        in
        List.iter
          (function
            | Exits.Same x -> expr often x
            | Exits.Block b -> (
                match List.assq_opt b blocks with
                | Some o -> block o b
                | None -> block often b)
            | Exits.Arm b | Exits.Handler b -> block often b
            | Exits.Lambda _ -> ())
          (Exits.parts e)
      in
      block false body)
    bodies;
  !changed


(* Every verb body with its declaration and parameters, instances included. *)
let bodies (p : T.Program.t) =
  List.concat_map
    (fun (pkg : T.Package.t) ->
      List.filter_map
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { body = T.Decl.Checked { params; body }; _ } ->
              Some (d.T.Decl.id, params, body)
          | _ -> None)
        pkg.T.Package.decls)
    p.T.Program.packages
  @ List.map
      (fun (i : T.Instance.t) -> (i.T.Instance.decl, i.T.Instance.params, i.T.Instance.body))
      p.T.Program.instances

(* Each block parameter, by verb and index, that its verb runs more than
   once. *)
let compute env (p : T.Program.t) =
  let multi : (int * int, unit) Hashtbl.t = Hashtbl.create 16 in
  let bodies = bodies p in
  while find_multi env multi bodies do
    ()
  done;
  multi

(* For each of a call's arguments, whether it is a block run more than once.
   A call through a function value is not seen into, so its blocks are taken
   to be. *)
let often env multi (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } ->
      let kept = passed env callee args in
      List.map
        (fun a ->
          match a with
          | T.Arg.Block _ -> (
              let rec index i = function
                | [] -> None
                | x :: rest -> if x == a then Some i else index (i + 1) rest
              in
              match index 0 kept with Some i -> runs_often multi callee i | None -> false)
          | T.Arg.Value _ -> false)
        args
  | T.Expr.Call_value { args; _ } ->
      List.map (function T.Arg.Block _ -> true | T.Arg.Value _ -> false) args
  | _ -> []
