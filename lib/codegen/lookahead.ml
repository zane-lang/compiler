(* Experimental (docs/experiments/prefetch-reorder): the element a counted
   loop will read some iterations on, when its address can be worked out
   now. A loop that reads a list at an index loaded from another list, as
   `recs[idx[i]]` does, waits on a miss each time round that the processor
   cannot see coming; with the address of the read [distance] iterations
   on known at the top of this one, a prefetch can start it early. Each
   read is the CGT's; reading the tree only, this module decides what to
   fetch, and Emit emits it ([Emit.prefetch]).

   An address qualifies when it is made, through the body's own [let]s and
   expression verbs' results, of constants, the loop's counter, locals the
   body neither binds nor assigns, integer arithmetic and bit operations
   that cannot fail, and element reads of lists whose handle can be read at
   the top of the loop ([Loop_shapes.invariant_lists]' addresses). At least
   one element read and the counter must be in it: an address the counter
   alone moves is one the hardware's own prefetcher follows, and one the
   counter does not move is the same each time round.

   Nothing about the program changes. A prefetch never faults and its
   address is only a hint, so it need not be the one the read will use: a
   local the body [let]s and then assigns is taken at its [let]'s value,
   when the body assigns it only in a loop inside it, whose first time
   round reads that value, as a probe's first slot is, and not from an
   element read, which would make the loop a walk along a chain. The element reads inside the address do run early, so each is made
   only when its index is inside its list as the list stands at the top of
   the loop, and the prefetch is skipped otherwise: no early read reaches
   past a list's end, and none stops the program. The reads the body makes
   itself, and their checks, stay where they are. *)

open Cgt.Nodes

(* How far ahead a loop fetches, in iterations: the model's best for
   `heavy` and `hash` at 32 MiB and 2 GiB (README, rounds 1 and 2). *)
let distance = 32

(* A value the prefetch works out, read or computed at the top of the loop. *)
type value =
  | Const of int64 * Ty.t
  (* A local the body leaves alone, or the counter, read where the prefetch
     is made. *)
  | Read of int * Ty.t
  | Add of value * value
  | Mul of value * value
  | Neg of value
  | Math of Cgt.Math.fn * Ty.t * value list
  (* A scalar converted between [I32] and [I64]: widened by its sign or
     wrapped to its low bits, as [Expr.Convert] converts one. *)
  | Convert of value * Ty.t
  (* The scalar [offset] bytes into the element at [index] of the list at
     [list], counted from 1, read only when [index] is inside the list. *)
  | Load of { list : Expr.t; index : value; stride : int; offset : int; ty : Ty.t }

(* A prefetch: the element at [index] of the list at [list], [stride] bytes
   to an element. *)
type target = { list : Expr.t; index : value; stride : int }

let rec mentions_load = function
  | Load _ -> true
  | Const _ | Read _ -> false
  | Add (a, b) | Mul (a, b) -> mentions_load a || mentions_load b
  | Neg a | Convert (a, _) -> mentions_load a
  | Math (_, _, vs) -> List.exists mentions_load vs

let rec mentions_read x = function
  | Read (y, _) -> x = y
  | Const _ -> false
  | Add (a, b) | Mul (a, b) -> mentions_read x a || mentions_read x b
  | Neg a | Convert (a, _) -> mentions_read x a
  | Math (_, _, vs) -> List.exists (mentions_read x) vs
  | Load { index; _ } -> mentions_read x index

(* The math functions on integers that give a value for every operand: a
   shift's count is taken modulo the width (Emit.math), and none of these
   divides. *)
let exact = function
  | Cgt.Math.Bit_and | Bit_or | Bit_xor | Bit_not | Shift_left | Shift_right | Shift_right_logical
  | Rotate_left | Rotate_right | Pop_count | Leading_zeros | Trailing_zeros | Min | Max ->
      true
  | _ -> false

let integer = function Ty.I32 | Ty.I64 -> true | _ -> false

(* Where the member [path] starts in a value of [ty], in bytes. *)
let rec member_offset (ty : Ty.t) path =
  match path with
  | [] -> Some 0
  | i :: rest -> (
      let members = Ty.members ty and offsets = Ty.member_offsets ty in
      match (List.nth_opt members i, List.nth_opt offsets i) with
      | Some m, Some at -> Option.map (( + ) at) (member_offset m rest)
      | _ -> None)

(* Whether [e], a value assigned to [y], reads an element of a list,
   itself or through the [let]s of the locals other than [y] it names. *)
let reads_element (f : Loop_shapes.facts) y e =
  let seen = Hashtbl.create 8 in
  Hashtbl.replace seen y ();
  let rec reads e =
    Cgt.Traverse.exists_in [ Stat.Eval e ] ~stat:(fun _ -> false) ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; _ } -> true
      | Expr.Local y when not (Hashtbl.mem seen y) ->
          Hashtbl.replace seen y ();
          List.exists reads (Hashtbl.find_all f.lets y)
      | _ -> false)
  in
  reads e

(* The locals assigned in [body] outside any loop inside it. *)
let assigned_outside_loops body =
  let found = Hashtbl.create 16 in
  let rec stats ss = List.iter stat ss
  and stat (s : Stat.t) =
    (match s with Stat.Assign { place; _ } -> Hashtbl.replace found place.Expr.local () | _ -> ());
    match s with
    | Stat.Repeat _ -> ()
    | _ ->
        let es, bodies = Cgt.Traverse.stat_parts s in
        List.iter expr es;
        List.iter stats bodies
  and expr e =
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.iter expr es;
    List.iter stats bodies
  in
  stats body;
  found

(* Whether [v], counted as the tree [Emit.prefetch] emits it, has at most
   [largest] nodes. Resolving shares a local's value between its uses, so
   `j1 = j0 + j0`, `j2 = j1 + j1`, ... is small as resolved and doubles
   with each `let` as emitted; the count stops as soon as it is over. *)
let largest = 64

let small v =
  let left = ref largest in
  let rec go v =
    decr left;
    !left >= 0
    &&
    match v with
    | Const _ | Read _ -> true
    | Add (a, b) | Mul (a, b) -> go a && go b
    | Neg a | Convert (a, _) -> go a
    | Math (_, _, vs) -> List.for_all go vs
    | Load { index; _ } -> go index
  in
  go v

(* [e] as a [value] the top of the loop can work out, [counter]'s local
   [x] moved on by [ahead]. [list] gives the address of the list an
   element read reads, when its handle can be read at the top of the
   loop. [outside] holds the locals the body assigns outside its own
   loops ([assigned_outside_loops]). *)
let resolve (f : Loop_shapes.facts) ~outside ~list (x, ahead) (e : Expr.t) =
  (* Locals already being resolved, so a local whose [let] names itself
     through another ends the search rather than looping. *)
  let seen = Hashtbl.create 8 and resolved = Hashtbl.create 8 in
  let rec go (e : Expr.t) =
    match e.Expr.node with
    | Expr.Int k when integer e.Expr.ty -> Some (Const (k, e.Expr.ty))
    | Expr.Local y when y = x -> Some (Add (Read (y, e.Expr.ty), Const (Int64.of_int ahead, e.Expr.ty)))
    | Expr.Local y -> local y e.Expr.ty
    | Expr.Expand { result = Some r; _ } -> (
        match Hashtbl.find_opt f.Loop_shapes.results r with Some v -> through r v | None -> None)
    | Expr.Binary { op = Expr.Add; left; right } when integer e.Expr.ty -> both (fun a b -> Add (a, b)) left right
    | Expr.Binary { op = Expr.Mul; left; right } when integer e.Expr.ty -> both (fun a b -> Mul (a, b)) left right
    | Expr.Flip v when integer e.Expr.ty -> Option.map (fun a -> Neg a) (go v)
    | Expr.Math { fn; args } when exact fn && integer e.Expr.ty ->
        let vs = List.map go args in
        if List.for_all Option.is_some vs then Some (Math (fn, e.Expr.ty, List.map Option.get vs)) else None
    | Expr.Convert v when integer e.Expr.ty && integer v.Expr.ty -> Option.map (fun a -> Convert (a, e.Expr.ty)) (go v)
    | Expr.Deref p when integer e.Expr.ty -> element p e.Expr.ty
    | _ -> None
  and both make l r = match (go l, go r) with Some a, Some b -> Some (make a b) | _ -> None
  and through y v =
    if Hashtbl.mem seen y then None
    else begin
      Hashtbl.replace seen y ();
      let r = go v in
      Hashtbl.remove seen y;
      r
    end
  (* A local the body binds once is its [let]'s value, when the body
     assigns it only in a loop inside it, whose first time round reads that
     value, as a probe's first slot is, and not from an element it reads:
     such a loop walks a chain, whose head is the least of its misses (the
     model's `chains`, `ahead`, README round 2). One the body neither binds nor
     assigns is read as it is; an expansion's result is the value its body
     gives it first. *)
  (* Each local is resolved once, its value shared by every use. *)
  and local y ty =
    match Hashtbl.find_opt resolved y with
    | Some v -> v
    | None ->
        let v = resolve_local y ty in
        if not (Hashtbl.mem seen y) then Hashtbl.replace resolved y v;
        v
  and resolve_local y ty =
    match (Hashtbl.find_all f.Loop_shapes.lets y, Hashtbl.find_all f.assigns y) with
    | [ v ], assigns when not (Hashtbl.mem outside y || List.exists (fun (_, a) -> reads_element f y a) assigns) ->
        through y v
    | [], [] when not (Hashtbl.mem f.defined y) -> Some (Read (y, ty))
    | [], [ _ ] when Hashtbl.mem f.results y -> through y (Hashtbl.find f.results y)
    | _ -> None
  and element (p : Expr.t) ty =
    let read base offset =
      match base.Expr.node with
      | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ l; index; { Expr.node = Expr.Int stride; _ } ] } -> (
          match (list l, go index) with
          | Some l, Some index -> Some (Load { list = l; index; stride = Int64.to_int stride; offset; ty })
          | _ -> None)
      | _ -> None
    in
    match p.Expr.node with
    | Expr.Offset { base; within; path } -> Option.bind (member_offset within path) (read base)
    | _ -> read p 0
  in
  go e

(* Whether a loop's [body] does enough with what it reads for a prefetch to
   pay: it branches, switches or loops. A body of a few loads and adds, as
   `s += a[idx[i]]` is, has many misses in flight already, and the model
   found nothing to gain there with 4 KiB pages (README, round 2). *)
let heavy body =
  Cgt.Traverse.exists_in body ~expr:(fun _ -> false) ~stat:(function
    | Stat.If _ | Stat.Switch _ | Stat.Repeat _ -> true
    | _ -> false)

(* Whether the top of a loop with [body] may read a list's handle that the
   body does not hand it: nothing in the body runs on another thread
   alongside it, nor moves a value out of a place, which could leave the
   handle a list's that no longer owns its block. Anything else the body
   does to a list leaves a list in its place, whose handle the next time
   round reads afresh. *)
let readable body =
  not
    (Cgt.Traverse.exists_in body
       ~expr:(fun e -> match e.Expr.node with Expr.Take _ | Expr.Escape _ -> true | _ -> false)
       ~stat:(function Stat.Spawn _ | Stat.Join _ -> true | _ -> false))

(* The locals [body] binds or assigns. *)
let bound_in body =
  let bound = Hashtbl.create 16 in
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace bound id ()
      | Stat.Assign { place; _ } -> Hashtbl.replace bound place.Expr.local ()
      | _ -> ())
    body;
  bound

(* Whether every step of an address goes into a struct's member. A step
   into a variant's case reaches a payload that is there only while that
   case is the one held, which the top of the loop does not know: another
   case's bytes may read as a list with a count and no block. *)
let rec members_only (a : Expr.t) =
  match a.Expr.node with
  | Expr.Offset { base; within; path } -> Option.is_some (member_offset within path) && members_only base
  | _ -> true

(* The address of a list's handle, when it is made of slots bound before
   the loop, none of [bound] or a local [names] gives the address of, and
   reaches no variant's payload. *)
let list_address bound names (l : Expr.t) =
  let rec address (l : Expr.t) =
    let unbound y = if Hashtbl.mem bound y then None else Some l in
    match l.Expr.node with
    | Expr.Address y -> unbound y
    | Expr.Local y -> ( match Hashtbl.find_opt names y with Some a -> Some a | None -> unbound y)
    | Expr.Offset ({ base; _ } as o) ->
        Option.map (fun base -> { l with Expr.node = Expr.Offset { o with base } }) (address base)
    | _ -> None
  in
  Option.bind (address l) (fun a -> if members_only a then Some a else None)

(* Unless ZANE_PREFETCH=0, what a counted loop with [body] fetches
   [distance] iterations ahead at the top of each time round: each element
   read whose address qualifies, once for each list and index. [names] is
   how a local of the body names a list's address
   ([Loop_shapes.invariant_lists]). *)
let targets body names =
  let f = Loop_shapes.facts body in
  match Loop_shapes.counter f body with
  | _ when Sys.getenv_opt "ZANE_PREFETCH" = Some "0" || (not (heavy body)) || not (readable body) -> []
  | None -> []
  | Some (x, step) ->
      let list = list_address (bound_in body) names in
      let outside = assigned_outside_loops body in
      let found = ref [] in
      (* The element read at [index] in [l], when its address qualifies. *)
      let target l index stride =
        match (list l, resolve f ~outside ~list (x, step * distance) index) with
        | Some l, Some index when small index && mentions_load index && mentions_read x index ->
            let t = { list = l; index; stride = Int64.to_int stride } in
            if not (List.mem t !found) then found := t :: !found
        | _ -> ()
      in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ l; index; { Expr.node = Expr.Int stride; _ } ] } ->
              target l index stride
          | _ -> ())
        ignore body;
      List.rev !found
