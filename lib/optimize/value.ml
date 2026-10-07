(* What the evaluator computes with (docs/design/optimization.md O5): the
   meaning of what a program holds, not where its bytes are.

   A [const] is a value that can be written back into the tree: it holds
   nothing that lives anywhere, so it is the same wherever it is used. A [v]
   is a value while the evaluator runs, which may point into its memory: a
   list's elements, a box, or a place an address names. Memory is a set of
   [cell]s, and a pointer is a cell and a path down to a part of what it
   holds, which is how every address in the tree is made. *)

open Cgt.Nodes

type const =
  | Int of int64
  | Float of float
  | Bool of bool
  | Unit
  | Text of string
  (* A struct's members or an array's elements, each at its index. *)
  | Record of const array
  | Case of int * const
  | Func of string
  (* A list's elements, made again by pushing each one [stride] bytes apart,
     moved in as [layout] says when they own blocks of their own. *)
  | List of { stride : int; element : Ty.t; layout : Layout.t option; items : const list }
  (* A boxed member's payload, in a block of its own. *)
  | Box of { ty : Ty.t; layout : Layout.t option; payload : const }

type v =
  | VInt of int64
  | VFloat of float
  | VBool of bool
  | VUnit
  | VText of string
  | VRecord of v array
  | VCase of int * v
  (* A list's handle: its elements, each a cell of its own. *)
  | VList of list_
  | VPtr of ptr
  (* What a zeroed slot holds where a handle or an address goes, and what a
     move leaves behind there. *)
  | VNull
  | VFunc of string
  | VLayout of Layout.t

and list_ = { mutable items : cell array; mutable count : int; mutable stride : int }

(* [ty] is the type of what the cell holds, which the layouts it is walked
   with are laid out over, and [layout] the layout it was placed with, when
   it was. [origin] says whose the cell is: one the evaluation made, a local
   of the function being folded, or a variable of the program. *)
and cell = { mutable value : v; mutable ty : Ty.t; mutable layout : Layout.t option; origin : origin }

and origin = Made | Outer of int | Global of string

(* [owned] when the address is a boxed member's, which owns the cell it
   names, rather than a reference or a place lent for a while. *)
and ptr = { cell : cell; path : step list; owned : bool }

(* A struct member or array element, or the payload of a sum's case. *)
and step = Member of int | Payload of int

(* Why an evaluation stopped. The fold leaves the code it was evaluating as it
   is. *)
exception Stop of string

let stop why = raise (Stop why)
let cell ?(origin = Made) ?layout ty value = { value; ty; layout; origin }

(* The address of a whole cell, lent, and a box's, which owns it. *)
let at c = VPtr { cell = c; path = []; owned = false }
let owner c = VPtr { cell = c; path = []; owned = true }
let empty () = VList { items = [||]; count = 0; stride = 0 }

(* What a slot holds before anything is stored in it: zeros, as the runtime
   gives a reserved slot. *)
let rec zero (t : Ty.t) =
  match t with
  | Ty.Void -> VUnit
  | Ty.I1 -> VBool false
  | Ty.I32 | Ty.I64 -> VInt 0L
  | Ty.F32 | Ty.F64 -> VFloat 0.
  | Ty.Handle | Ty.Ptr -> VNull
  | Ty.Struct ts -> VRecord (Array.of_list (List.map zero ts))
  | Ty.Array (t, n) -> VRecord (Array.init n (fun _ -> zero t))
  | Ty.Sum [] -> VCase (0, VUnit)
  | Ty.Sum (t :: _) -> VCase (0, zero t)

(* An integer as a type holds it: an [I32] wraps at 32 bits, sign
   extended. *)
let int (t : Ty.t) i = match t with Ty.I32 -> Int64.of_int32 (Int64.to_int32 i) | _ -> i

(* ---------------------------------------------------------------------- *)
(* Paths                                                                  *)
(* ---------------------------------------------------------------------- *)

let rec read_path v path =
  match (path, v) with
  | [], v -> v
  | Member i :: rest, VRecord a when i < Array.length a -> read_path a.(i) rest
  | Payload i :: rest, VCase (tag, p) when tag = i -> read_path p rest
  | Payload _ :: _, VCase _ -> stop "a payload read while another case is live"
  | _ -> stop "a path into something that does not hold it"

(* The type a path leads to. *)
let rec ty_at (t : Ty.t) path =
  match (path, t) with
  | [], t -> t
  | Member i :: rest, Ty.Struct ts when i < List.length ts -> ty_at (List.nth ts i) rest
  | Member _ :: rest, Ty.Array (e, _) -> ty_at e rest
  | Payload i :: rest, Ty.Sum ts when i < List.length ts -> ty_at (List.nth ts i) rest
  | _ -> stop "a path through a type that has no such part"

(* A value's own structs, arrays and cases, so that what holds it can be
   written in place without changing anything else that read it. Lists and
   boxes are not copied: they are where they are, as at run time. *)
let rec own = function
  | VRecord a -> VRecord (Array.map own a)
  | VCase (i, p) -> VCase (i, own p)
  | v -> v

(* [x] stored at [path] inside [v], which is changed in place where it can
   be: a large array written element by element costs no more per element
   than at run time. *)
let rec set_path v path x =
  match (path, v) with
  | [], _ -> x
  | Member i :: rest, VRecord a when i < Array.length a ->
      a.(i) <- set_path a.(i) rest x;
      v
  | Payload i :: rest, VCase (tag, p) when tag = i -> VCase (tag, set_path p rest x)
  | _ -> stop "a write into something that does not hold it"

(* Every cell owns what it holds: it is copied in and copied out. *)
let load (p : ptr) = own (read_path p.cell.value p.path)

let store (p : ptr) ty x =
  if p.path = [] then p.cell.ty <- ty;
  p.cell.value <- set_path p.cell.value p.path (own x)

(* ---------------------------------------------------------------------- *)
(* Layouts                                                                *)
(* ---------------------------------------------------------------------- *)

(* Where a layout's position is in a value of type [t]: the path down to the
   handle or box at its offset, or nothing when one of the sums it is inside
   holds another case than the position needs (zane_present). *)
let locate (t : Ty.t) (v : v) (p : Layout.position) =
  let rec go t v off base path =
    match t with
    | (Ty.Handle | Ty.Ptr) when off = 0 -> Some (List.rev path)
    | Ty.Struct ts ->
        let offsets = Ty.offsets ts in
        let rec find i ts offsets =
          match (ts, offsets) with
          | t :: ts, o :: offsets ->
              let size = fst (Ty.size_align t) in
              if off >= o && off < o + size then
                match v with
                | VRecord a -> go t a.(i) (off - o) (base + o) (Member i :: path)
                | _ -> stop "a struct that holds no members"
              else find (i + 1) ts offsets
          | _ -> stop "a layout position past a struct's members"
        in
        find 0 ts offsets
    | Ty.Array (e, _) -> (
        let size, align = Ty.size_align e in
        let stride = (size + align - 1) / align * align in
        (* An element of no size holds no handle or box. *)
        let i = if stride = 0 then -1 else off / stride in
        match v with
        | VRecord a when i >= 0 && i < Array.length a ->
            go e a.(i) (off - (i * stride)) (base + (i * stride)) (Member i :: path)
        | _ -> stop "an array that holds no such element")
    | Ty.Sum ts when off >= Ty.payload_offset -> (
        match v with
        | VCase (tag, payload) ->
            let wanted = List.assoc_opt base p.Layout.tags in
            if wanted <> None && wanted <> Some tag then None
            else
              go (List.nth ts tag) payload (off - Ty.payload_offset) (base + Ty.payload_offset)
                (Payload tag :: path)
        | _ -> stop "a sum that holds no case")
    | _ -> stop "a layout position at no handle or box"
  in
  go t v p.Layout.offset 0 []

(* Every position of [layout] present in [v], with the path to it. *)
let positions layouts layout t v =
  match Hashtbl.find_opt layouts layout with
  | None -> []
  | Some ps -> List.filter_map (fun p -> Option.map (fun at -> (p, at)) (locate t v p)) ps

(* A value copied whole (memory.md §2.3): every list and box it owns is
   copied too, so the copy shares nothing with the original. A string is
   never written in place, so its bytes are shared. *)
let rec copy layouts layout t v =
  List.fold_left
    (fun v ((p : Layout.position), at) ->
      match (p.Layout.kind, read_path v at) with
      | Layout.List { elements; _ }, VList l ->
          let item (c : cell) = cell ?layout:c.layout c.ty (copy layouts elements c.ty c.value) in
          let items = Array.map item (Array.sub l.items 0 l.count) in
          set_path v at (VList { items; count = l.count; stride = l.stride })
      | Layout.Box { payload; _ }, VPtr b ->
          let target = b.cell in
          let made = cell ~layout:payload target.ty (copy layouts payload target.ty (load b)) in
          set_path v at (owner made)
      | _ -> v)
    (own v)
    (positions layouts layout t v)

(* About how many bytes copying a value whole writes, which the step budget
   charges before the copy is made. *)
let rec weight = function
  | VRecord a -> Array.fold_left (fun n v -> n + weight v) 0 a
  | VCase (_, p) -> 8 + weight p
  | VList l ->
      let n = ref 24 in
      for i = 0 to l.count - 1 do
        n := !n + 24 + weight l.items.(i).value
      done;
      !n
  | VPtr { cell = c; owned = true; _ } -> 8 + weight c.value
  | VText _ -> 24
  | _ -> 8

(* What a move leaves in the place it moved out of (zane_vacate): no list,
   no string and no box. *)
let vacate layouts layout t v =
  List.fold_left
    (fun v ((p : Layout.position), at) ->
      match p.Layout.kind with
      | Layout.Text -> set_path v at (VText "")
      | Layout.List _ -> set_path v at (empty ())
      | Layout.Box _ -> set_path v at VNull)
    (own v)
    (positions layouts layout t v)

(* [incoming] replacing [old] in place (zane_overwrite): a box both hold
   keeps its cell, which the incoming payload is written into, recursively,
   so an address into it still names it. *)
let rec overwrite layouts layout t old incoming =
  let kept =
    List.filter_map
      (fun ((p : Layout.position), at) ->
        match (p.Layout.kind, read_path old at) with
        | Layout.Box { payload; _ }, (VPtr _ as b) -> (
            match List.assoc_opt p (positions layouts layout t incoming) with
            | Some at' when at' = at -> (
                match read_path incoming at with
                | VPtr _ as n -> Some (at, b, n, payload)
                | _ -> None)
            | _ -> None)
        | _ -> None)
      (positions layouts layout t old)
  in
  List.fold_left
    (fun v (at, b, n, payload) ->
      match (b, n) with
      | VPtr b, VPtr n ->
          let inner = overwrite layouts payload b.cell.ty (load b) (load n) in
          store b n.cell.ty inner;
          set_path v at (VPtr { b with owned = true })
      | _ -> v)
    (own incoming) kept

(* ---------------------------------------------------------------------- *)
(* Constants                                                              *)
(* ---------------------------------------------------------------------- *)

let rec import = function
  | Int i -> VInt i
  | Float f -> VFloat f
  | Bool b -> VBool b
  | Unit -> VUnit
  | Text s -> VText s
  | Record a -> VRecord (Array.map import a)
  | Case (i, p) -> VCase (i, import p)
  | Func s -> VFunc s
  | List { stride; element; layout; items } ->
      let items = Array.of_list (List.map (fun c -> cell ?layout element (import c)) items) in
      VList { items; count = Array.length items; stride }
  | Box { ty; layout; payload } -> owner (cell ?layout ty (import payload))

(* What a value is as a constant, when it holds nothing that lives
   somewhere else: a reference or a lent address does. A list or a box the
   value owns is part of it. *)
let rec export = function
  | VInt i -> Some (Int i)
  | VFloat f -> Some (Float f)
  | VBool b -> Some (Bool b)
  | VUnit -> Some Unit
  | VText s -> Some (Text s)
  | VRecord a ->
      let members = Array.map export a in
      if Array.for_all Option.is_some members then Some (Record (Array.map Option.get members))
      else None
  | VCase (i, p) -> Option.map (fun p -> Case (i, p)) (export p)
  | VFunc s -> Some (Func s)
  | VList l ->
      let items = List.map (fun (c : cell) -> export c.value) (Array.to_list (Array.sub l.items 0 l.count)) in
      if List.for_all Option.is_some items then
        let element, layout =
          match Array.to_list (Array.sub l.items 0 l.count) with
          | c :: _ -> (c.ty, c.layout)
          | [] -> (Ty.Void, None)
        in
        Some (List { stride = l.stride; element; layout; items = List.map Option.get items })
      else None
  | VPtr { cell = c; path = []; owned = true } ->
      Option.map (fun payload -> Box { ty = c.ty; layout = c.layout; payload }) (export c.value)
  | VPtr _ | VNull | VLayout _ -> None

(* Whether two constants are the same in every bit: [=] takes a zero for
   its negative, which a division tells apart. *)
let rec same a b =
  match (a, b) with
  | Float x, Float y -> Int64.equal (Int64.bits_of_float x) (Int64.bits_of_float y)
  | Record x, Record y -> Array.length x = Array.length y && Array.for_all2 same x y
  | Case (i, x), Case (j, y) -> i = j && same x y
  | List l, List m ->
      l.stride = m.stride && l.element = m.element && l.layout = m.layout
      && List.length l.items = List.length m.items
      && List.for_all2 same l.items m.items
  | Box x, Box y -> x.ty = y.ty && x.layout = y.layout && same x.payload y.payload
  | (Float _ | Record _ | Case _ | List _ | Box _), _ -> false
  | (Int _ | Bool _ | Unit | Text _ | Func _), _ -> a = b

(* Constants as keys, compared with [same]. Equal floats hash alike, so
   constants that are the same do too. *)
module Key = Hashtbl.Make (struct
  type t = string * const list

  let equal (f, a) (g, b) = String.equal f g && List.length a = List.length b && List.for_all2 same a b
  let hash = Hashtbl.hash
end)

(* How many bytes a constant takes where it is written, which the size cap
   (O6) counts. *)
let rec size = function
  | Int _ | Float _ | Bool _ | Func _ -> 8
  | Unit -> 0
  | Text s -> 24 + String.length s
  | Record a -> Array.fold_left (fun n c -> n + size c) 0 a
  | Case (_, p) -> 8 + size p
  | List { items; _ } -> List.fold_left (fun n c -> n + 24 + size c) 24 items
  | Box { payload; _ } -> 8 + size payload

(* Whether a constant owns a list or a box, which building costs a block. *)
let rec owns_block = function
  | List _ | Box _ -> true
  | Record a -> Array.exists owns_block a
  | Case (_, p) -> owns_block p
  | Int _ | Float _ | Bool _ | Unit | Text _ | Func _ -> false
