(* Spawn safety (concurrency.md §4.2–4.3): an analysis over the finished TST
   (docs/semantics.md D1).

   A spawned `mut` call writes its subject, so the subject must be a value
   (§4.2). Its borrow of the subject's location lasts until the block the
   spawn is written in drains, which waits for the call (§4.1). While it
   lasts, no other spawned call may borrow an overlapping location, and the
   block and the blocks inside it may not touch one (§4.3). A spawn in a block
   that runs more than once takes its subject from storage declared in that
   block, so each run borrows a location of its own.

   A spawn read where it is written is waited for at once, so its borrow ends
   where it began; only a spawn written as a statement, or bound by a `let`,
   keeps one. *)

module T = Nodes
module S = Signature

(* A place: the local it is reached through, and the path from there. *)
type place = { local : T.Local.t; path : Read_only.step list }

(* Two places overlap when one's path is a prefix of the other's. An element
   is any element, so two subscripts of one list overlap. *)
let overlap a b =
  let rec prefix x y =
    match (x, y) with
    | [], _ | _, [] -> true
    | s :: xs, t :: ys -> s = t && prefix xs ys
  in
  a.local.T.Local.id = b.local.T.Local.id && prefix a.path b.path

let place_of e = Option.map (fun (local, path) -> { local; path }) (Read_only.place e)

let describe p =
  let step = function
    | Read_only.Field f -> "." ^ f
    | Read_only.Case c -> "." ^ c
    | Read_only.Elem -> "[]"
  in
  "`" ^ p.local.T.Local.name ^ String.concat "" (List.map step p.path) ^ "`"

(* The block parameters each verb runs more than once, by declaration and
   position. *)
let multi : (int * int, unit) Hashtbl.t = Hashtbl.create 16

(* The arguments a call passes, by position: a type written where a value
   goes passes nothing (generics.md §5.3). *)
let passed args =
  List.filter
    (function T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> false | _ -> true)
    args

(* Whether the argument at [i] of a call to [r] is run more than once:
   `@controlflow$repeat`'s body, or a block parameter a verb runs so. *)
let runs_often (r : T.Verb_ref.t) i =
  match r.T.Verb_ref.owner with
  | S.Intrinsic "@controlflow$repeat" -> i = 1
  | S.Declared id -> Hashtbl.mem multi (id, i)
  | S.Intrinsic _ -> false

let call_parts (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Call { callee; args; _ } -> Some (callee, passed args)
  | _ -> None

(* One pass of the fixed point: a verb runs a block parameter more than once
   when it passes it where it runs more than once, or passes it anywhere from
   inside a block that does. *)
let find_multi bodies =
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
        (match call_parts e with
        | Some (callee, args) ->
            List.iteri
              (fun i a ->
                match a with
                | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
                    match param l.T.Local.id with
                    | Some p when often || runs_often callee i -> mark id p
                    | _ -> ())
                | _ -> ())
              args
        | None -> ());
        let blocks =
          match call_parts e with
          | Some (callee, args) ->
              List.concat
                (List.mapi
                   (fun i a ->
                     match a with T.Arg.Block b -> [ (b, often || runs_often callee i) ] | _ -> [])
                   args)
          | None -> []
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

(* A block being walked: the locals declared in it, whether it runs more than
   once, and the borrows spawns in it hold until it drains. *)
type frame = {
  declared : (int, unit) Hashtbl.t;
  often : bool;
  mutable borrows : (place * Source.Span.t) list;
}

let borrowed frames p =
  List.find_map
    (fun f -> List.find_opt (fun (b, _) -> overlap b p) f.borrows)
    frames

let signature_of = Read_only.signature_of

(* The parts of a place other than the place it is reached through: a
   subscript's index, and a case read's handler. *)
let rec beside (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } -> beside target
  | T.Expr.Subscript { target; args; _ } ->
      List.map (fun a -> Exits.Same a) args @ beside target
  | T.Expr.Case_read { target; handler; _ } -> Exits.Handler handler.T.Handler.body :: beside target
  | _ -> []

(* A part of an expression to walk, with whether a block argument runs more
   than once. *)
type piece = Plain of Exits.part | Run of T.Block.t * bool

let walk_body (body : T.Block.t) =
  let rec block frames often (b : T.Block.t) =
    let f = { declared = Hashtbl.create 8; often; borrows = [] } in
    let frames = f :: frames in
    List.iter (stat frames) b.T.Block.stats
  and stat frames (s : T.Stat.t) =
    match s.T.Stat.node with
    | T.Stat.Spawn e -> spawn frames ~keeps:true e
    | T.Stat.Let { local; value = { T.Expr.node = T.Expr.Spawn _; _ } as e } ->
        spawn frames ~keeps:true e;
        declare frames local
    | T.Stat.Let { local; value } ->
        expr frames value;
        declare frames local
    | _ -> List.iter (expr frames) (Exits.stat_exprs s)
  and declare frames (l : T.Local.t) =
    match frames with f :: _ -> Hashtbl.replace f.declared l.T.Local.id () | [] -> ()
  (* A place touched while a spawn holds an overlapping borrow. *)
  and touch frames (e : T.Expr.t) p =
    match borrowed frames p with
    | Some (b, _) ->
        Env.error e.T.Expr.span
          (Printf.sprintf
             "%s is borrowed by a spawned `mut` call on %s, which holds it until its block \
              drains"
             (describe p) (describe b))
    | None -> ()
  and expr frames (e : T.Expr.t) =
    match e.T.Expr.node with
    | T.Expr.Spawn _ -> spawn frames ~keeps:false e
    | _ -> (
        match place_of e with
        | Some p ->
            touch frames e p;
            List.iter (fun x -> part frames (Plain x)) (beside e)
        | None -> List.iter (part frames) (parts e))
  and parts (e : T.Expr.t) =
    (* A block argument runs more than once when its callee runs it so. *)
    match call_parts e with
    | Some (callee, args) ->
        let often =
          List.concat
            (List.mapi
               (fun i a -> match a with T.Arg.Block b -> [ (b, runs_often callee i) ] | _ -> [])
               args)
        in
        List.map
          (function
            | Exits.Block b -> Run (b, Option.value ~default:false (List.assq_opt b often))
            | p -> Plain p)
          (Exits.parts e)
    | None -> List.map (fun p -> Plain p) (Exits.parts e)
  and part frames = function
    | Run (b, often) -> block frames often b
    | Plain (Exits.Same x) -> expr frames x
    | Plain (Exits.Block b | Exits.Arm b | Exits.Handler b) -> block frames false b
    (* A lambda has a frame of its own, and captures nothing. *)
    | Plain (Exits.Lambda b) -> block [] false b
  and spawn frames ~keeps (e : T.Expr.t) =
    let inner = match e.T.Expr.node with T.Expr.Spawn inner -> inner | _ -> e in
    match inner.T.Expr.node with
    | T.Expr.Call { callee; args = T.Arg.Value subject :: rest; handler }
      when (match signature_of callee with Some sg -> sg.S.is_mut | None -> false) ->
        let owner = match subject.T.Expr.ty with Ty.Guest t -> t | t -> t in
        let reference = Types.is_reference owner in
        if reference then
          Env.error subject.T.Expr.span
            (Printf.sprintf
               "a spawned `mut` call writes its subject, and `%s` is a reference type: only a \
                value-typed subject may be written from spawned work"
               (Ty.to_string subject.T.Expr.ty));
        let p = place_of subject in
        (match p with
        | Some p -> (
            match borrowed frames p with
            | Some (b, _) ->
                Env.error subject.T.Expr.span
                  (Printf.sprintf
                     "%s overlaps %s, which a spawned `mut` call in this block or around it \
                      already borrows"
                     (describe p) (describe b))
            | None -> ())
        | None -> expr frames subject);
        List.iter
          (function T.Arg.Value v -> expr frames v | T.Arg.Block b -> block frames false b)
          rest;
        Option.iter (fun (h : T.Handler.t) -> block frames false h.T.Handler.body) handler;
        if keeps && not reference then begin
          (* In a block that runs more than once, the subject is declared in
             it, or in a block inside it. *)
          (match (p, List.find_opt (fun f -> f.often) frames) with
          | Some p, Some _ ->
              let rec inside = function
                | [] -> false
                | f :: rest ->
                    Hashtbl.mem f.declared p.local.T.Local.id || ((not f.often) && inside rest)
              in
              if not (inside frames) then
                Env.error subject.T.Expr.span
                  (Printf.sprintf
                     "this block runs more than once, so a spawned `mut` call in it takes its \
                      subject from storage declared in it, and %s is declared outside"
                     (describe p))
          | _ -> ());
          match (p, frames) with
          | Some p, f :: _ -> f.borrows <- (p, subject.T.Expr.span) :: f.borrows
          | _ -> ()
        end
    | _ -> expr frames inner
  in
  block [] false body

let run (p : T.Program.t) =
  Hashtbl.reset multi;
  let bodies =
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
  in
  while find_multi bodies do
    ()
  done;
  List.iter (fun (_, _, b) -> walk_body b) bodies
