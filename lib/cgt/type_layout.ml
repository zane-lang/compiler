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

(* `@primitives$String`, a value type, and `@primitives$List<T>`, a
   reference type: the storage primitives that are each a handle. *)
let is_text = function
  | Tty.Intrinsic { namespace = "primitives"; name = "String"; args = [] } -> true
  | _ -> false

(* `@primitives$I32`, `I64`, `F32` or `F64`. *)
let scalar t =
  match Tty.strip_mode t with
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> List.mem name Tst.Intrinsics.scalars
  | _ -> false

let element = function
  | Tty.Intrinsic { namespace = "primitives"; name = "List"; args = [ Tty.Type e ] } -> Some e
  | _ -> None

let is_list t = Option.is_some (element t)

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

(* A reference type: a `#` type, a list or an `ArrayRef`, whose instances are
   owned (memory.md §2.1). A roaming owner is one of its type. *)
let reference st t =
  let t = match t with Tty.Roaming t -> t | t -> t in
  is_list t || is_array_ref t || match definition st t with Some (_, true) -> true | _ -> false

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
let rec shape st span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | Tty.Roaming t -> shape st span t
  | _ when is_text t || is_list t -> Nodes.Ty.Handle
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
      let member m = if boxed st t m then Nodes.Ty.Ptr else shape st span m in
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
  match (t, element t) with
  | Tty.Reference _, _ -> []
  | Tty.Roaming t, _ -> positions st span t base tags
  | _, Some e ->
      let elements = layout st span e in
      [ at (Layout.List { stride = stride st span e; elements }) handle ]
  | _ when is_text t -> [ at Layout.Text handle ]
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
            if boxed st t m then
              let size = fst (Nodes.Ty.size_align (ty st span m)) in
              let payload = layout st span m in
              [ { Layout.kind = Layout.Box { size; payload }; offset = base; size = 8; tags } ]
            else positions st span m base tags
          in
          let variant cs sum =
            List.concat
              (List.mapi
                 (fun i (_, c) -> member c (sum + Nodes.Ty.payload_offset) (tags @ [ (sum, i) ]))
                 cs)
          in
          match (definition, lowered) with
          | T.Decl.Struct ms, Nodes.Ty.Struct ts ->
              List.concat
                (List.map2 (fun (_, m) at -> member m (base + at) tags) ms (Nodes.Ty.offsets ts))
          | T.Decl.Variant cs, Nodes.Ty.Sum _ -> variant cs base
          | _ -> [])
      | None -> [])

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

(* Whether a local of this type is an owner: a reference type's instance
   lives in its scope's arena (memory.md §3.3). A reference is an address,
   not an owner. *)
let owned st t = (not (Tty.is_ref t)) && reference st t

(* Whether a local of this type is a roaming owner: one the body may move
   on, or that dies with it (lifetimes.md §1.5). *)
let roaming st t = Tty.is_roaming t && reference st t

(* Whether a place is reached through an owner: a member or a case of a
   reference-type instance, or of one a reference names, an element of a
   list or an `ArrayRef`, and an element of an array reached through one. A
   spawned call may write back a value there while another thread reads it
   (concurrency.md §4.4). *)
let rec through_owner st (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Case_read { target; _ } ->
      Tty.is_ref target.T.Expr.ty || reference st (Tty.strip_mode target.T.Expr.ty) || through_owner st target
  | T.Expr.Subscript { target; _ }
    when Option.is_some (array_of (Tty.strip_mode target.T.Expr.ty))
         && not (is_array_ref (Tty.strip_mode target.T.Expr.ty)) ->
      through_owner st target
  | T.Expr.Subscript _ -> true
  | _ -> false

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
