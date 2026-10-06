(* Spawn safety (concurrency.md §4.2–4.3): an analysis over the finished TST
   (docs/design/semantics.md D1).

   A spawned `mut` call writes its subject, so the subject must be a value
   (§4.2). Its borrow of the subject's location lasts until the block the
   spawn is written in drains, which waits for the call (§4.1). While it
   lasts, no other spawned call may borrow an overlapping location, and the
   block and the blocks inside it may not touch one (§4.3). A spawn in a block
   that runs more than once takes its subject from storage declared in that
   block, so each run borrows a location of its own.

   A spawn read where it is written is waited for at once, so its borrow ends
   where it began; only a spawn written as a statement, or bound by a `let`,
   keeps one.

   Such a spawn is also lent every owner it is passed, directly or through a
   reference, and may read it until the same drain. The spec leaves the lending
   block free to write what it lent; here it may not, directly, through a `!`
   call, by moving it, or through a reference that may name it
   (docs/spec-divergences.md §13). *)

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

(* The types a type holds by owning edges: its members, what it is distinct
   from, a list's or fixed array's elements. A reference member holds none. *)
let members env (t : Ty.t) =
  match t with
  | Ty.Named (tid, args) -> (
      match Type_decls.type_info_of_id env tid with
      | Some info -> (
          let sub = Ty.instantiate info.Env.params args in
          match info.Env.definition with
          | Some (Env.Struct fs | Env.Variant fs) -> List.map (fun (_, m) -> sub m) fs
          | Some (Env.Distinct u) -> [ sub u ]
          | _ -> [])
      | _ -> [])
  | Ty.Intrinsic { name = "List"; args = [ Ty.Type e ]; _ } -> [ e ]
  | Ty.Intrinsic { name = "ArrayRef"; args = Ty.Type e :: _; _ } -> [ e ]
  | _ -> []

(* Whether a value of type [outer] may hold one of type [inner]. *)
let rec contains env ?(seen = []) outer inner =
  Ty.equal outer inner
  || (not (List.exists (Ty.equal outer) seen))
     && List.exists
          (fun m ->
            (match m with Ty.Reference _ -> false | _ -> true)
            && contains env ~seen:(outer :: seen) m inner)
          (members env outer)

(* The types a place passes through, from the place itself to its root. *)
let rec chain (e : T.Expr.t) =
  Ty.strip_mode e.T.Expr.ty
  ::
  (match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Subscript { target; _ } | T.Expr.Case_read { target; _ }
    ->
      chain target
  | _ -> [])

(* An owner lent to a spawn: its place when the checker knows it, the type of
   the owner, and the argument it was lent through. *)
type lend = { at : place option; lent : Ty.t; through : T.Expr.t }

(* A place as written, where it is when the checker can follow it through
   references, and the type of what it holds. *)
type claim = { written : place; at : place option; ty : Ty.t }

(* A block being walked: the locals declared in it, whether it runs more than
   once, and the borrows spawns in it hold until it drains. *)
type frame = {
  declared : (int, unit) Hashtbl.t;
  often : bool;
  mutable borrows : claim list;
  mutable lends : lend list;
}

(* Two claims on storage overlap when their places do. Where a place is
   reached through a reference whose owner the checker cannot follow, they may
   overlap when either's type may hold the other's. *)
let clashes env a b =
  match (a.at, b.at) with
  | Some x, Some y -> overlap x y
  | _ -> contains env a.ty b.ty || contains env b.ty a.ty

let borrowed env frames c = List.find_map (fun f -> List.find_opt (clashes env c) f.borrows) frames

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

let walk_body env multi (body : T.Block.t) =
  (* Where each reference local points, when the checker knows: the place it was
     minted from, followed through other references. *)
  let origins : (int, place option) Hashtbl.t = Hashtbl.create 8 in
  let resolve p =
    match p.local.T.Local.ty with
    | Ty.Reference _ -> (
        match Hashtbl.find_opt origins p.local.T.Local.id with
        | Some (Some o) -> Some { o with path = o.path @ p.path }
        | _ -> None)
    | _ -> Some p
  in
  (* The owner a reference-typed expression names, when known. *)
  let origin (e : T.Expr.t) =
    match (e.T.Expr.ty, e.T.Expr.node) with
    | Ty.Reference _, T.Expr.Var (T.Name_ref.Local l) -> (
        match Hashtbl.find_opt origins l.T.Local.id with Some o -> o | None -> None)
    | Ty.Reference _, _ -> None
    | _ -> Option.bind (place_of e) resolve
  in
  (* A write to the place [e], or a move out of it, while a spawn may still
     read an owner it was lent. Where either place is unknown, what might
     overlap is decided by type. *)
  let write ?(verb = "writes") frames (e : T.Expr.t) =
    match place_of e with
    | None -> ()
    | Some p -> (
        let written = resolve p in
        let types = chain e in
        let clash (l : lend) =
          match (written, l.at) with
          | Some w, Some a -> overlap w a
          | _ ->
              contains env (Ty.strip_mode e.T.Expr.ty) l.lent || List.exists (fun c -> contains env l.lent c) types
        in
        match List.find_map (fun f -> List.find_opt clash f.lends) frames with
        | Some l ->
            let lent =
              match place_of l.through with
              | Some p -> describe p
              | None -> "`" ^ Ty.to_string l.through.T.Expr.ty ^ "`"
            in
            Env.error env e.T.Expr.span
              (Printf.sprintf
                 "this %s %s, which may be part of an owner lent through %s to a spawned call \
                  that may read it until its block drains"
                 verb (describe p) lent)
        | None -> ())
  in
  (* An owner read from a place into owning storage moves out of the place. *)
  let moved frames (e : T.Expr.t) =
    match e.T.Expr.ty with
    | Ty.Reference _ -> ()
    | t when Type_decls.is_reference env (Ty.strip_mode t) -> write ~verb:"moves" frames e
    | _ -> ()
  in
  let claim (e : T.Expr.t) p = { written = p; at = resolve p; ty = Ty.strip_mode e.T.Expr.ty } in
  let rec block frames often (b : T.Block.t) =
    let f = { declared = Hashtbl.create 8; often; borrows = []; lends = [] } in
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
        (match local.T.Local.ty with
        | Ty.Reference _ -> Hashtbl.replace origins local.T.Local.id (origin value)
        | _ when Ty.is_roaming local.T.Local.ty -> moved frames value
        | _ -> moved frames value);
        declare frames local
    | T.Stat.Assign { target; value } ->
        expr frames value;
        (match (target.T.Expr.ty, target.T.Expr.node) with
        | Ty.Reference _, T.Expr.Var (T.Name_ref.Local l) ->
            (* A reference bound again points where the value does, unless the
               binding is in a block inside its own, which may not run. *)
            let own =
              match frames with f :: _ -> Hashtbl.mem f.declared l.T.Local.id | [] -> false
            in
            Hashtbl.replace origins l.T.Local.id (if own then origin value else None)
        | Ty.Reference _, _ -> ()
        | _ ->
            write frames target;
            moved frames value);
        expr frames target
    | T.Stat.Return e ->
        expr frames e;
        moved frames e
    | _ -> List.iter (expr frames) (Exits.stat_exprs s)
  and declare frames (l : T.Local.t) =
    match frames with f :: _ -> Hashtbl.replace f.declared l.T.Local.id () | [] -> ()
  (* A place touched while a spawn holds an overlapping borrow. *)
  and touch frames (e : T.Expr.t) p =
    match borrowed env frames (claim e p) with
    | Some { written = b; _ } ->
        Env.error env e.T.Expr.span
          (Printf.sprintf
             "%s is borrowed by a spawned `mut` call on %s, which holds it until its block \
              drains"
             (describe p) (describe b))
    | None -> ()
  and expr frames (e : T.Expr.t) =
    (* A `!` call writes its subject, and an owner passed to a `^T`
       parameter moves; a bare reference-type parameter borrows it
       (memory.md §2.9). *)
    (match e.T.Expr.node with
    | T.Expr.Call { callee; args; _ } | T.Expr.Construct { ctor = callee; args; _ } -> (
        match Env.signature_of env callee with
        | Some sg ->
            (match args with
            | T.Arg.Value subject :: _ when sg.S.is_mut -> write frames subject
            | _ -> ());
            (match callee.T.Verb_ref.owner with
            | S.Declared _ when List.length sg.S.params = List.length args ->
                let filled =
                  List.map (fun ((q : Ty.param), a) -> (q.Ty.id, a)) callee.T.Verb_ref.instance
                in
                List.iter2
                  (fun (p : S.param) a ->
                    match a with
                    | T.Arg.Value v
                      when Ty.is_roaming p.S.ty
                           && Type_decls.is_reference env (Ty.strip_mode (Ty.subst filled p.S.ty)) ->
                        moved frames v
                    | _ -> ())
                  sg.S.params args
            | _ -> ())
        | None -> ())
    | _ -> ());
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
    match Repeats.call_parts env e with
    | Some (callee, args) ->
        let often =
          List.concat
            (List.mapi
               (fun i a ->
                 match a with
                 | T.Arg.Block b -> [ (b, Repeats.runs_often multi callee i) ]
                 | _ -> [])
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
      when (match Env.signature_of env callee with Some sg -> sg.S.is_mut | None -> false) ->
        let owner = match subject.T.Expr.ty with Ty.Reference t -> t | t -> t in
        let reference = Type_decls.is_reference env owner in
        if reference then
          Env.error env subject.T.Expr.span
            (Printf.sprintf
               "a spawned `mut` call writes its subject, and `%s` is a reference type: only a \
                value-typed subject may be written from spawned work"
               (Ty.to_string subject.T.Expr.ty));
        let p = place_of subject in
        (match p with
        | Some p -> (
            (* An index or a case read's handler in the subject is read here. *)
            List.iter (fun x -> part frames (Plain x)) (beside subject);
            match borrowed env frames (claim subject p) with
            | Some { written = b; _ } ->
                Env.error env subject.T.Expr.span
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
                Env.error env subject.T.Expr.span
                  (Printf.sprintf
                     "this block runs more than once, so a spawned `mut` call in it takes its \
                      subject from storage declared in it, and %s is declared outside"
                     (describe p))
          | _ -> ());
          match (p, frames) with
          | Some p, f :: _ -> f.borrows <- claim subject p :: f.borrows
          | _ -> ()
        end;
        if keeps then lend frames (List.filter_map value rest)
    | T.Expr.Call { args; _ } ->
        expr frames inner;
        if keeps then lend frames (List.filter_map value args)
    | _ -> expr frames inner
  and value = function T.Arg.Value v -> Some v | T.Arg.Block _ -> None
  (* The owners a lasting spawn is passed, directly or through a reference. *)
  and lend frames args =
    List.iter
      (fun (a : T.Expr.t) ->
        let lent = Ty.strip_mode a.T.Expr.ty in
        let lent =
          match a.T.Expr.ty with
          | Ty.Reference _ -> Some { at = origin a; lent; through = a }
          | t when Type_decls.is_reference env t && Option.is_some (place_of a) ->
              Some { at = origin a; lent; through = a }
          | _ -> None
        in
        match (lent, frames) with Some l, f :: _ -> f.lends <- l :: f.lends | _ -> ())
      args
  in
  block [] false body

let run env (p : T.Program.t) =
  let multi = Repeats.compute env p in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { body = T.Decl.Checked { body; _ }; _ } -> walk_body env multi body
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  List.iter
    (fun (i : T.Instance.t) ->
      Env.in_instance env i (fun () -> walk_body env multi i.T.Instance.body))
    p.T.Program.instances
