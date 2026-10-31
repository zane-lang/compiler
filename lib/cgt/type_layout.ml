(* How a TST type becomes a CGT layout (docs/design/lowering.md L5): a
   declared type's definition, its members and payloads, its machine layout,
   and where its owned blocks are. *)

module T = Tst.Nodes
module Tty = Tst.Ty
open Nodes
open State

let unhandled span t =
  Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` has no layout" (Tty.to_string t))

(* A declared type's definition, with its parameters replaced by the
   arguments it was given, and whether it is a reference type. *)
let definition st (t : Tty.t) =
  match t with
  | Tty.Named ({ package; name }, args) -> (
      match Hashtbl.find_opt st.types (package, name) with
      | Some (params, definition, reference) -> (
          let sub = Tty.instantiate params args in
          let members = List.map (fun (n, m) -> (n, sub m)) in
          match definition with
          | T.Decl.Struct ms -> Some (T.Decl.Struct (members ms), reference)
          | T.Decl.Variant cs -> Some (T.Decl.Variant (members cs), reference)
          | T.Decl.Enum cs -> Some (T.Decl.Enum cs, reference)
          | T.Decl.Distinct u -> Some (T.Decl.Distinct (sub u), reference))
      | _ -> None)
  | _ -> None

(* `@primitives$String`, a value type, and `@primitives$List<T>` and
   `@primitives$ListRef<T>`, a value and a reference type: the storage
   primitives that are each a handle. *)
let is_text = function
  | Tty.Intrinsic { namespace = "primitives"; name = "String"; args = [] } -> true
  | _ -> false

(* `@primitives$I32`, `I64`, `F32` or `F64`. *)
let scalar t =
  match Tty.strip_mode t with
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> List.mem name Tst.Intrinsics.scalars
  | _ -> false

let element = function
  | Tty.Intrinsic { namespace = "primitives"; name = "List" | "ListRef"; args = [ Tty.Type e ] } -> Some e
  | _ -> None

let is_list t = Option.is_some (element t)

let is_list_ref = function
  | Tty.Intrinsic { namespace = "primitives"; name = "ListRef"; _ } -> true
  | _ -> false

(* `@primitives$Array<T, n>`, a value type, and `@primitives$ArrayRef<T, n>`,
   a reference type with the same layout (generics.md §8.4): the element
   type and length. *)
let array_of = function
  | Tty.Intrinsic
      {
        namespace = "primitives";
        name = "Array" | "ArrayRef";
        args = [ Tty.Type e; Tty.Number (Tty.Known n) ];
      } ->
      Some (e, n)
  | _ -> None

let is_array_ref = function
  | Tty.Intrinsic { namespace = "primitives"; name = "ArrayRef"; _ } -> true
  | _ -> false

(* A reference type: a `#` type, a `ListRef` or an `ArrayRef`, whose
   instances are owned (memory.md §2.1). A roaming owner is one of its type. *)
let reference st t =
  let t = match t with Tty.Roaming t -> t | t -> t in
  is_list_ref t || is_array_ref t || match definition st t with Some (_, true) -> true | _ -> false

(* The types a type holds inline: its members and payloads, what it is
   distinct from, and an array's elements. A reference holds an address, and
   a list's elements are in its block. *)
let inline st t =
  match (definition st t, array_of t) with
  | Some ((T.Decl.Struct ms | T.Decl.Variant ms), _), _ ->
      List.filter (fun m -> not (Tty.is_ref m)) (List.map snd ms)
  | Some (T.Decl.Distinct u, _), _ -> [ u ]
  | None, Some (e, _) when not (Tty.is_ref e) -> [ e ]
  | _ -> []

(* A walk down a type's members, gone down to [t] (Tty.Growth). Semantics
   rejects a type that holds itself at a growing argument (generics.md §2.4),
   the only kind whose members lead to ever new types, so a walk that keeps
   growing is a type that check missed: an internal error, not a hang or a
   stack overflow. *)
let down ?span path t =
  match Tty.Growth.step path t with
  | Some path -> path
  | None ->
      Diagnostic.bug ?span
        (Printf.sprintf "lowering: the members of `%s` grow without end" (Tty.to_string t))

(* adt.md §4: a member is boxed when its type leads back to the type that
   holds it along owning edges, since no finite inline layout exists for it.
   A boxed member is a pointer to its payload's block. Each answer is kept,
   so a long chain of types is walked once per member, not once per use. *)
let boxed st holder member =
  match Hashtbl.find_opt st.boxes (holder, member) with
  | Some boxed -> boxed
  | None ->
      let seen = Hashtbl.create 16 in
      let rec reaches path t =
        (not (Tty.is_ref t))
        && (Tty.equal t holder
           || (not (Hashtbl.mem seen t))
              &&
              (Hashtbl.replace seen t ();
               List.exists (reaches (down path t)) (inline st t)))
      in
      let boxed = reaches Tty.Growth.start member in
      Hashtbl.replace st.boxes (holder, member) boxed;
      boxed

(* Experimental (docs/experiments/goose-comparison): with
   ZANE_POOLED_VARIANTS=1 in the environment, a variant whose payload leads
   back to it is pooled. Where it is owned it is a root, a list of bytes
   whose block holds the root node's offset and then every node of the
   value; inside its pool each node is the variant's sum with its payload
   inline, and each member of the variant's own type in it is a 32-bit link,
   the offset from the link to the node it names. *)
let pooling = Sys.getenv_opt "ZANE_POOLED_VARIANTS" = Some "1"

let unroamed = function Tty.Roaming t -> t | t -> t

let pooled st t =
  pooling
  &&
  let t = unroamed t in
  match definition st t with
  | Some (T.Decl.Variant cs, _) -> List.exists (fun (_, c) -> boxed st t c) cs
  | _ -> false

(* A struct a pooled variant's payload is, inline in its node: one with a
   member of a pooled variant that leads back to it. *)
let cycle_struct st t =
  pooling
  &&
  let t = unroamed t in
  match definition st t with
  | Some (T.Decl.Struct ms, _) -> List.exists (fun (_, m) -> pooled st m && boxed st t m) ms
  | _ -> false

(* A value struct of one member is that member (L5), so reading or storing
   the member is reading or storing the struct. *)
let collapsed st t =
  match definition st t with
  | Some (T.Decl.Struct [ (_, m) ], false) -> not (boxed st t m)
  | _ -> false

(* A member's index in its struct's layout: its place in declaration order
   (memory.md §3.3). *)
let member_index _st _t slot = slot

(* L5: a storage primitive has a machine layout, a string or a list is a
   handle, and an array is its elements inline. A value struct has its
   members' in declaration order, except that one of a single member has
   that member's (concepts-vs-primitives.md) and an empty one has none. A
   value variant is a sum of its payloads, and
   an enum a sum of cases with none. A reference type's instance has the
   same shape and nothing more (memory.md §3.3), a reference is the address
   of the owner it names (§4.1), and a boxed member a pointer (adt.md §4).
   A function value is the address of the function a lambda was lifted to
   (L14). *)
(* A boxed member's type: the address of its block, in 32 bits with Ref32
   (experimental). *)
let box_type () = if Ref32.on () then Nodes.Ty.Ref else Nodes.Ty.Ptr

let rec shape st span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | Tty.Roaming t -> shape st span t
  | _ when is_text t -> Nodes.Ty.Handle
  | _ when is_list t -> Nodes.Ty.list_handle ()
  | Tty.Named _ when pooled st t -> Nodes.Ty.list_handle ()
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> (
      match name with
      | "Unit" -> Nodes.Ty.Void
      | "Bool" -> Nodes.Ty.I1
      | "I64" -> Nodes.Ty.I64
      | "I32" -> Nodes.Ty.I32
      | "F64" -> Nodes.Ty.F64
      | "F32" -> Nodes.Ty.F32
      | _ -> unhandled span t)
  | Tty.Reference _ -> Nodes.Ty.Ptr
  | Tty.Verb _ -> Nodes.Ty.Ptr
  | Tty.Intrinsic _ when Option.is_some (array_of t) -> (
      match array_of t with
      | Some (e, n) -> Nodes.Ty.Array (shape st span e, n)
      | None -> unhandled span t)
  | Tty.Named _ -> (
      let member m =
        if boxed st t m then if pooled st m then Nodes.Ty.list_handle () else box_type () else shape st span m
      in
      let sum ts = Nodes.Ty.Sum ts in
      match definition st t with
      | Some (T.Decl.Struct [], false) -> Nodes.Ty.Void
      | Some (T.Decl.Struct [ (_, m) ], false) when collapsed st t -> member m
      | Some (T.Decl.Struct ms, false) -> Nodes.Ty.Struct (List.map (fun (_, m) -> member m) ms)
      | Some (T.Decl.Variant cs, false) -> sum (List.map (fun (_, c) -> member c) cs)
      | Some (T.Decl.Enum cs, false) -> sum (List.map (fun _ -> Nodes.Ty.Void) cs)
      | Some (T.Decl.Struct ms, true) -> Nodes.Ty.Struct (List.map (fun (_, m) -> member m) ms)
      | Some (T.Decl.Variant cs, true) -> sum (List.map (fun (_, c) -> member c) cs)
      | Some (T.Decl.Enum cs, true) -> sum (List.map (fun _ -> Nodes.Ty.Void) cs)
      | Some (T.Decl.Distinct u, _) -> member u
      | _ -> unhandled span t)
  | _ -> unhandled span t

(* A size in the unit that reads best: whole bytes, or KiB, MiB or GiB to a
   tenth. *)
let bytes n =
  let rec scaled = function
    | [] -> Printf.sprintf "%d bytes" n
    | (unit, size) :: rest ->
        if n < size then scaled rest
        else if n mod size = 0 then Printf.sprintf "%d %s" (n / size) unit
        else Printf.sprintf "%.1f %s" (float_of_int n /. float_of_int size) unit
  in
  scaled [ ("GiB", 1 lsl 30); ("MiB", 1 lsl 20); ("KiB", 1 lsl 10) ]

(* A type's layout, refused where it is named when its size is past the
   limit no value can reach (Nodes.Ty.limit), or past the main context's
   range of frames (`--fixed-region`), which could then never hold a value
   of it (docs/design/lowering.md §9). Each layout is checked once. *)
let ty st span (t : Tty.t) : Nodes.Ty.t =
  let lowered = shape st span t in
  if not (Hashtbl.mem st.sized lowered) then begin
    (match Nodes.Ty.size_align lowered with
    | size, _ when size > st.region ->
        refuse span
          (Printf.sprintf "`%s` takes %s, which the `--fixed-region` of %s cannot hold" (Tty.to_string t)
             (bytes size) (bytes st.region))
    | _ -> ()
    | exception Nodes.Ty.Too_large ->
        refuse span
          (Printf.sprintf "`%s` takes 2^48 bytes or more, past the limit on any value's size"
             (Tty.to_string t)));
    Hashtbl.replace st.sized lowered ()
  end;
  lowered

(* A list's elements lie this many bytes apart. *)
let stride st span t =
  let size, align = Nodes.Ty.size_align (ty st span t) in
  max 1 (Nodes.Ty.round_up size align)

(* Where a type's owned blocks are (memory.md §3.6): each handle and each
   boxed member, down through variant payloads under the tag that makes each
   live. An array whose elements own blocks is one position, which names
   its element's layout, so that its positions do not grow with its length
   (docs/design/lowering.md §9). A reference is an address, and owns
   nothing. *)
let rec positions ?(path = Tty.Growth.start) st span (t : Tty.t) base tags : Layout.position list =
  let path = down ~span path t in
  let positions = positions ~path and layout = layout ~path in
  let at kind size = { Layout.kind; offset = base; size; tags } in
  let handle = fst (Nodes.Ty.size_align Nodes.Ty.Handle) in
  let list_handle = fst (Nodes.Ty.size_align (Nodes.Ty.list_handle ())) in
  match (t, element t) with
  | Tty.Reference _, _ -> []
  | Tty.Roaming t, _ -> positions st span t base tags
  | _, Some e ->
      let elements = layout st span e in
      [ at (Layout.List { stride = stride st span e; elements }) list_handle ]
  | _ when is_text t -> [ at Layout.Text handle ]
  | _ when pooled st t -> [ at (Layout.List { stride = 1; elements = pool_bytes st }) list_handle ]
  | Tty.Intrinsic _, _ when Option.is_some (array_of t) -> (
      let e, n = Option.get (array_of t) in
      match positions st span e 0 [] with
      | [] -> []
      | ps ->
          (* The element's positions are its layout's, so they are kept as
             that layout rather than worked out again, which arrays nested
             in arrays would do once for each level above them. *)
          let elements = Symbol.ty e and s = stride st span e in
          if not (Hashtbl.mem st.layouts elements) then begin
            Hashtbl.replace st.layouts elements ps;
            st.named <- elements :: st.named
          end;
          [ at (Layout.Array { count = n; stride = s; elements }) (Nodes.Ty.times s n) ])
  | _ -> (
      match definition st t with
      | Some (T.Decl.Distinct u, _) -> positions st span u base tags
      | Some (T.Decl.Struct [ (_, m) ], false) when collapsed st t -> positions st span m base tags
      | Some (definition, _) -> (
          let lowered = ty st span t in
          let member m base tags =
            if boxed st t m && pooled st m then positions st span m base tags
            else if boxed st t m then
              let size = fst (Nodes.Ty.size_align (ty st span m)) in
              let payload = layout st span m in
              [ { Layout.kind = Layout.Box { size; payload }; offset = base; size = fst (Nodes.Ty.size_align (box_type ())); tags } ]
            else positions st span m base tags
          in
          let variant cs sum =
            List.concat
              (List.mapi
                 (fun i (_, c) -> member c (sum + Nodes.Ty.payload_at lowered) (tags @ [ (sum, i) ]))
                 cs)
          in
          match (definition, lowered) with
          | T.Decl.Struct ms, Nodes.Ty.Struct ts ->
              List.concat
                (List.map2 (fun (_, m) at -> member m (base + at) tags) ms (Nodes.Ty.offsets ts))
          | T.Decl.Variant cs, Nodes.Ty.Sum _ -> variant cs base
          | _ -> [])
      | None -> [])

(* The layout of a pool's bytes, which own nothing a walk follows. *)
and pool_bytes st =
  let name = "zane.pool" in
  if not (Hashtbl.mem st.layouts name) then begin
    Hashtbl.replace st.layouts name [];
    st.named <- name :: st.named
  end;
  name

(* A type's layout, by the type's symbol (Symbol.ty), which is also the name
   of its table in the IR. A layout that names itself, through a box, finds
   its name taken before it is done. *)
and layout ?path st span (t : Tty.t) : Layout.t =
  let name = Symbol.ty t in
  if not (Hashtbl.mem st.layouts name) then begin
    Hashtbl.replace st.layouts name [];
    Hashtbl.replace st.layouts name (positions ?path st span t 0 []);
    st.named <- name :: st.named
  end;
  name

(* Experimental packed nodes (`ZANE_PACKED_NODES=1`): a node's sum and the
   payload struct inside it with no padding, the tag one byte. *)
let packed_nodes () = Sys.getenv_opt "ZANE_PACKED_NODES" = Some "1"

let packing t = if packed_nodes () then Nodes.Ty.Packed t else t

(* A pooled variant [p]'s node: its sum, each payload inline, a member of
   [p]'s type a link. The prototype pools only a variant whose payloads are
   [p] itself, a struct whose members of a pooled type are [p], or a type
   that owns no block, so a node owns nothing outside its pool. *)
let node_shape st span p =
  let p = unroamed p in
  let plain m =
    if positions st span m 0 [] <> [] then
      refuse span
        (Printf.sprintf "pooled variants: `%s` holds `%s`, which owns a block" (Tty.to_string p) (Tty.to_string m));
    shape st span m
  in
  let link m =
    if not (Tty.equal (unroamed m) p) then
      refuse span (Printf.sprintf "pooled variants: `%s` links to another pooled type" (Tty.to_string p));
    Nodes.Ty.I32
  in
  let payload c =
    if pooled st c then link c
    else if cycle_struct st c then
      match definition st (unroamed c) with
      | Some (T.Decl.Struct ms, _) ->
          packing (Nodes.Ty.Struct (List.map (fun (_, m) -> if pooled st m then link m else plain m) ms))
      | _ -> unhandled span c
    else plain c
  in
  match definition st p with
  | Some (T.Decl.Variant cs, _) -> packing (Nodes.Ty.Sum (List.map (fun (_, c) -> payload c) cs))
  | _ -> unhandled span p

(* The node form of a payload or member type: a pooled variant's own node,
   a cycle struct's members with its links, or the type's own shape. *)
let node_ty st span t =
  if pooled st t then node_shape st span t
  else if cycle_struct st t then
    match definition st (unroamed t) with
    | Some (T.Decl.Struct ms, _) ->
        packing (Nodes.Ty.Struct (List.map (fun (_, m) -> if pooled st m then Nodes.Ty.I32 else shape st span m) ms))
    | _ -> unhandled span t
  else ty st span t

(* Where a pooled variant's nodes keep their links, for the runtime's
   copy of a subtree: for each of the first four cases, a mask with a bit
   set for each byte of the node a link starts at. *)
let node_masks st span p =
  let p = unroamed p in
  let node = node_shape st span p in
  let size = fst (Nodes.Ty.size_align node) in
  if size > 64 then refuse span "pooled variants: a node past 64 bytes";
  let word off = Int64.shift_left 1L (Nodes.Ty.payload_at node + off) in
  let mask c =
    if pooled st c then word 0
    else if cycle_struct st c then
      match (definition st (unroamed c), node_ty st span c) with
      | Some (T.Decl.Struct ms, _), inner ->
          List.fold_left2
            (fun acc (_, m) off -> if pooled st m then Int64.logor acc (word off) else acc)
            0L ms (Nodes.Ty.member_offsets inner)
      | _ -> 0L
    else 0L
  in
  match definition st p with
  | Some (T.Decl.Variant cs, _) ->
      let masks = List.map (fun (_, c) -> mask c) cs in
      List.iteri (fun i m -> if i >= 4 && m <> 0L then refuse span "pooled variants: links past the fourth case") masks;
      List.init 4 (fun i -> match List.nth_opt masks i with Some m -> m | None -> 0L)
  | _ -> unhandled span p

(* Whether a local of this type is an owner: a reference type's instance
   lives in its scope's arena (memory.md §3.3). A reference is an address,
   not an owner. *)
let owned st t = (not (Tty.is_ref t)) && reference st t

(* A slot for a local of this type, recorded in [Func.values] when the type
   is a value type. *)
let slot st t id =
  if not (Tty.is_ref t || reference st t) then st.values <- id :: st.values;
  Slot id

(* Whether a local of this type is a roaming owner: one the body may move
   on, or that dies with it (lifetimes.md §1.5). *)
let roaming st t = Tty.is_roaming t && reference st t

(* Whether a place is reached through an owner: a member or a case of a
   reference-type instance, or of one a reference names, an element of a
   `ListRef` or an `ArrayRef`, and an element of an array or a value list
   reached through one. A
   spawned call may write back a value there while another thread reads it
   (concurrency.md §4.4). *)
let rec through_owner st (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Case_read { target; _ } ->
      Tty.is_ref target.T.Expr.ty || reference st (Tty.strip_mode target.T.Expr.ty) || through_owner st target
  | T.Expr.Subscript { target; _ }
    when (let t = Tty.strip_mode target.T.Expr.ty in
          (Option.is_some (array_of t) || is_list t) && not (reference st t)) ->
      through_owner st target
  | T.Expr.Subscript _ -> true
  | _ -> false

(* Whether a value of type [outer] holds one of type [inner]: is it, or has
   it among the members it holds inline or boxed, however deep. *)
let holds st outer inner =
  let seen = Hashtbl.create 8 in
  let rec go t =
    Tty.equal t inner
    || (not (Hashtbl.mem seen t))
       &&
       (Hashtbl.replace seen t ();
        List.exists go (inline st t))
  in
  go (Tty.strip_mode outer)

(* A type an owner is of, with what it is distinct from looked through. *)
let rec owner_type st t =
  match definition st t with Some (T.Decl.Distinct u, _) -> owner_type st u | _ -> t

(* Where a place reached through an owner is: the type of the innermost
   owner, and the steps from it down to the place, or [None] when a
   declared subscript names it, whose body may name any place inside its
   target. A value holds no owner (memory.md §2.10), so every byte of a
   value inside an owner is reached from that owner alone, by one path. *)
let rec owned_place st (e : T.Expr.t) =
  let owner (target : T.Expr.t) =
    Tty.is_ref target.T.Expr.ty || reference st (Tty.strip_mode target.T.Expr.ty)
  in
  let down (target : T.Expr.t) step =
    if owner target then Some (owner_type st (Tty.strip_mode target.T.Expr.ty), [ step ])
    else Option.map (fun (o, steps) -> (o, steps @ [ step ])) (owned_place st target)
  in
  match e.T.Expr.node with
  | T.Expr.Field { target; field; _ } -> down target (Member field)
  | T.Expr.Case_read { target; _ } -> down target Case
  | T.Expr.Subscript { target; impl = { owner = Tst.Signature.Intrinsic "@primitives$[]"; _ }; _ } ->
      down target Elem
  | _ -> None

(* Two places overlap when they are in owners of one type and one's steps
   begin the other's. *)
let overlap (o, steps) (o', steps') =
  let rec prefix = function
    | [], _ | _, [] -> true
    | a :: rest, b :: rest' -> a = b && prefix (rest, rest')
  in
  Tty.equal o o' && prefix (steps, steps')

(* What a spawned call writes back into the place [e], when it is reached
   through an owner. *)
let written_into st (e : T.Expr.t) =
  { of_type = Tty.strip_mode e.T.Expr.ty; place = owned_place st e }

(* Whether a read of the place [e], reached through an owner, takes a
   snapshot: a spawned call may write back into a place that overlaps it
   while the read takes its bytes (concurrency.md §4.4). Where either
   place is not known, the read takes one when its type holds the written
   value's, or that holds its type. *)
let snapshots st (e : T.Expr.t) =
  match st.written_back with
  | None -> true
  | Some ws ->
      let t = Tty.strip_mode e.T.Expr.ty in
      let at = owned_place st e in
      List.exists
        (fun w ->
          match (at, w.place) with
          | Some a, Some b -> overlap a b
          | _ -> holds st t w.of_type || holds st w.of_type t)
        ws

(* Whether a value of this type owns a dynamic block (memory.md §3.6), which
   it returns when it dies and copies when it is copied. *)
let owns st span t = (not (Tty.is_ref t)) && positions st span t 0 [] <> []

(* Whether a local of this type is held in its scope's arena: an owner, or a
   value that owns a block, whose blocks go when the scope drains (L8). *)
let held st span t = owned st t || owns st span t

(* The sum inside a variant or enum. *)
let sum_of _st _span _t (value : Expr.t) = value

(* A case of a variant or enum, built. *)
let case_of st span t index (payload : Expr.t) =
  { Expr.node = Expr.Case { index; payload }; ty = ty st span t }

(* The cases of a variant or enum, in declaration order. *)
let cases st span t =
  let t = Tty.strip_mode t in
  match definition st t with
  | Some (T.Decl.Variant cs, _) -> List.map fst cs
  | Some (T.Decl.Enum cs, _) -> cs
  | _ -> unhandled span t

let case_index st span t case =
  let rec find i = function
    | [] -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` has no case `%s`" (Tty.to_string t) case)
    | c :: _ when c = case -> i
    | _ :: rest -> find (i + 1) rest
  in
  find 0 (cases st span t)

(* The type a variant case carries, and a struct field. *)
let payload_type st span t case =
  match definition st (Tty.strip_mode t) with
  | Some (T.Decl.Variant cs, _) -> (
      match List.assoc_opt case cs with Some c -> c | None -> unhandled span t)
  | _ -> unhandled span t

let field_type st span t slot =
  match definition st (Tty.strip_mode t) with
  | Some (T.Decl.Struct ms, _) when slot < List.length ms -> snd (List.nth ms slot)
  | _ -> unhandled span t
