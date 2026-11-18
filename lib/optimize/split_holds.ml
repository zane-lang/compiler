(* A struct held in a scope's arena, split into a local for each member.

   A struct that owns a block, such as one with a list among its members,
   is held (Build.bind): its slot is in the scope's frame, so the drain ends
   what it owns. A scalar member is then a word of the frame, which LLVM
   sees through the frame's address only: a loop that counts in it loads
   and stores the frame on every pass, where the same count in a local of
   its own stays in a register. When every use of the struct names one of
   its members, a member's address ([Offset] below it) or an assignment to
   a member ([place] with a path), the struct is made of its members alone:
   each becomes a local of its own, a member that owns a block held in the
   same scope with the part of the struct's layout it covers, and any other
   a [Let], which LLVM promotes to a register.

   A struct read, moved, copied or lent whole, read as a snapshot, a
   spawned call's result, or holding a foreign handle, whose address its
   setter keeps (docs/design/ffi.md F12), stays whole. *)

open Cgt.Nodes
open Cgt.Traverse

(* The struct a hold may be split into: a plain one, of more than one
   member. *)
let members (t : Ty.t) = match t with Ty.Struct (_ :: _ :: _ as ms) -> Some ms | _ -> None

(* The holds whose every use names a member. *)
let candidates (f : Func.t) =
  let held = Hashtbl.create 8 in
  walk_stats ignore
    (function
      | Stat.Hold { id; value; _ } when Option.is_some (members value.Expr.ty) ->
          Hashtbl.replace held id value.Expr.ty
      | _ -> ())
    f.Func.body;
  let whole = Hashtbl.create 8 in
  let bar i = Hashtbl.replace whole i () in
  (* Each [Address h] is a use; one that is the base of a member's address
     is counted off. *)
  let addressed = Hashtbl.create 8 and named = Hashtbl.create 8 in
  let count t i = Hashtbl.replace t i (1 + Option.value ~default:0 (Hashtbl.find_opt t i)) in
  let rec under_snapshot (e : Expr.t) =
    walk_expr (fun e -> match e.Expr.node with Expr.Address i | Expr.Local i -> bar i | _ -> ()) ignore e
  and see (e : Expr.t) =
    match e.Expr.node with
    | Expr.Address i -> count addressed i
    | Expr.Local i -> bar i
    | Expr.Offset { base = { Expr.node = Expr.Address i; _ }; within; path = _ :: _ }
      when Hashtbl.find_opt held i = Some within ->
        count named i
    | Expr.Snapshot x -> under_snapshot x
    | _ -> ()
  in
  walk_stats see
    (function
      | Stat.Assign { place; _ } when place.Expr.path = [] || place.Expr.deref -> bar place.Expr.local
      | Stat.Spawn { dest = Some d; task; _ } ->
          bar d;
          bar task
      | _ -> ())
    f.Func.body;
  List.iter (fun (i, _) -> bar i) f.Func.params;
  List.iter (fun (i, _) -> bar i) f.Func.places;
  Hashtbl.fold
    (fun i ms acc ->
      let a = Option.value ~default:0 (Hashtbl.find_opt addressed i)
      and n = Option.value ~default:0 (Hashtbl.find_opt named i) in
      if Hashtbl.mem whole i || a <> n then acc else (i, ms) :: acc)
    held []

(* The positions of [positions] within a member [at] bytes in and [size]
   long, from the member's start. *)
let within (positions : Layout.position list) at size =
  List.filter_map
    (fun (p : Layout.position) ->
      if p.Layout.offset >= at && p.Layout.offset < at + size then Some { p with Layout.offset = p.Layout.offset - at }
      else None)
    positions

let foreign (positions : Layout.position list) =
  List.exists (fun (p : Layout.position) -> match p.Layout.kind with Layout.Foreign _ -> true | _ -> false) positions

(* The layouts the program names, and those the split adds: a member that
   owns a block is held with a layout of its own, the positions of its
   struct's layout it covers, named after the struct's and the member. *)
type layouts = { known : (Layout.t, Layout.position list) Hashtbl.t; mutable added : (Layout.t * Layout.position list) list }

let member_layout ls layout k at size =
  match within (Option.value ~default:[] (Hashtbl.find_opt ls.known layout)) at size with
  | [] -> `Plain
  | ps when foreign ps -> `Foreign
  | ps ->
      let name = Printf.sprintf "%s#%d" layout k in
      if not (Hashtbl.mem ls.known name) then begin
        Hashtbl.replace ls.known name ps;
        ls.added <- (name, ps) :: ls.added
      end;
      `Held name

let local i ty = { Expr.node = Expr.Local i; ty }

(* Each member of a split hold: its local, its type, and the layout it is
   held with, if it is. *)
type member = { id : int; ty : Ty.t; held : Layout.t option }

(* The members of hold [id], of type [t] and laid out as [layout], or none
   where one holds a foreign handle. *)
let plan ls fresh t layout =
  match members t with
  | None -> None
  | Some ms ->
      let parts =
        List.mapi (fun k (m, at) -> (m, member_layout ls layout k at (fst (Ty.size_align m)))) (List.combine ms (Ty.offsets ms))
      in
      if List.exists (fun (_, l) -> l = `Foreign) parts then None
      else
        Some
          (Array.of_list
             (List.map
                (fun (m, l) -> { id = fresh (); ty = m; held = (match l with `Held n -> Some n | _ -> None) })
                parts))

(* The statements a split hold becomes: the struct's value made once into
   a local, and each member taken from it, in order. *)
let parts scope whole (value : Expr.t) (members : member array) =
  Stat.Let { id = whole; value }
  :: Array.to_list
       (Array.mapi
          (fun k m ->
            let v = { Expr.node = Expr.Member { value = local whole value.Expr.ty; index = k }; ty = m.ty } in
            match m.held with
            | Some layout -> Stat.Hold { id = m.id; scope; value = v; layout }
            | None -> Stat.Let { id = m.id; value = v })
          members)

let func ls (f : Func.t) : Func.t =
  match candidates f with
  | [] -> f
  | cands ->
      let next = ref (Peel.largest f) in
      let fresh () =
        incr next;
        !next
      in
      let splits = Hashtbl.create 8 and lets = Hashtbl.create 8 in
      let member h k = Option.map (fun ms -> ms.(k)) (Hashtbl.find_opt splits h) in
      let rec fe (e : Expr.t) =
        match e.Expr.node with
        | Expr.Offset { base = { Expr.node = Expr.Address h; _ }; path = k :: rest; _ } -> (
            match member h k with
            | None -> None
            | Some m ->
                let address = { Expr.node = Expr.Address m.id; ty = Ty.Ptr } in
                Some
                  (if rest = [] then address
                   else { e with Expr.node = Expr.Offset { base = address; within = m.ty; path = rest } }))
        | Expr.Deref p -> (
            match map_expr fe fs p with
            (* A member's value read from its own local. *)
            | { Expr.node = Expr.Address m; _ } when Hashtbl.mem lets m -> Some (local m e.Expr.ty)
            | p -> Some { e with Expr.node = Expr.Deref p })
        | _ -> None
      and fs (s : Stat.t) =
        match s with
        | Stat.Hold { id; scope; value; layout } when List.mem_assoc id cands -> (
            match plan ls fresh value.Expr.ty layout with
            | None -> None
            | Some ms ->
                Hashtbl.replace splits id ms;
                Array.iter (fun m -> if m.held = None then Hashtbl.replace lets m.id ()) ms;
                Some (parts scope (fresh ()) (map_expr fe fs value) ms))
        | Stat.Assign { place = { Expr.deref = false; path = k :: rest; local = h; _ } as place; value } -> (
            match member h k with
            | Some m ->
                Some [ Stat.Assign { place = { place with Expr.local = m.id; ty = m.ty; path = rest }; value = map_expr fe fs value } ]
            | None -> None)
        | _ -> None
      in
      let body = map_stats fe fs f.Func.body in
      let added =
        Hashtbl.fold
          (fun h ms acc -> if List.mem h f.Func.values then Array.fold_left (fun acc m -> m.id :: acc) acc ms else acc)
          splits []
      in
      { f with Func.body; values = f.Func.values @ added }

let program (p : Program.t) =
  let known = Hashtbl.create 64 in
  List.iter (fun (n, ps) -> Hashtbl.replace known n ps) p.Program.layouts;
  let ls = { known; added = [] } in
  let funcs = List.map (func ls) p.Program.funcs in
  { p with Program.funcs; layouts = p.Program.layouts @ List.rev ls.added }
