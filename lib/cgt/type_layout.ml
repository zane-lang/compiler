(* How a TST type becomes a CGT layout (docs/design/lowering.md L5): a
   declared type's definition, its members and payloads, its machine layout,
   and where its hosts and owned blocks are. *)

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

(* `@primitives$String`, the string view, and `@primitives$List<T>`: the
   storage primitives that are reference types, each a handle. *)
let is_text = function
  | Tty.Intrinsic { namespace = "primitives"; name = "String"; args = [] } -> true
  | _ -> false

let element = function
  | Tty.Intrinsic { namespace = "primitives"; name = "List"; args = [ Tty.Type e ] } -> Some e
  | _ -> None

let is_list t = Option.is_some (element t)

(* `@primitives$Array<T, n>`, a value type: its element type and length. *)
let array_of = function
  | Tty.Intrinsic
      { namespace = "primitives"; name = "Array"; args = [ Tty.Type e; Tty.Number (Tty.Known n) ] }
    ->
      Some (e, n)
  | _ -> None

(* A reference type: a `#` type, whose instances are hosted (memory.md §2.1),
   or a string or a list, whose instance is a handle (§3.6). *)
let reference st t =
  is_text t || is_list t || match definition st t with Some (_, true) -> true | _ -> false

(* The types a type holds inline: its members and payloads, what it is
   distinct from, and an array's elements. A guest holds a tether, and a
   list's elements are in its block. *)
let inline st t =
  match (definition st t, array_of t) with
  | Some ((T.Decl.Struct ms | T.Decl.Variant ms), _), _ ->
      List.filter (fun m -> not (Tty.is_guest m)) (List.map snd ms)
  | Some (T.Decl.Distinct u, _), _ -> [ u ]
  | None, Some (e, _) when not (Tty.is_guest e) -> [ e ]
  | _ -> []

(* adt.md §4: a member is boxed when its type leads back to the type that
   holds it along owning edges, since no finite inline layout exists for it.
   A boxed member is a pointer to its payload's block. *)
let boxed st holder member =
  let rec reaches seen t =
    (not (Tty.is_guest t))
    && (Tty.equal t holder
       || (not (List.exists (Tty.equal t) seen)) && List.exists (reaches (t :: seen)) (inline st t))
  in
  reaches [] member

(* A value struct of one member is that member (L5), so reading or storing
   the member is reading or storing the struct. *)
let collapsed st t =
  match definition st t with
  | Some (T.Decl.Struct [ (_, m) ], false) -> not (boxed st t m)
  | _ -> false

(* A reference type's instance begins with its backpointer (L5), so its
   members start one index later. *)
let member_index st t slot = if reference st t then slot + 1 else slot

(* L5: a storage primitive has a machine layout, a string or a list is a
   handle, and an array is its elements inline. A value struct has its
   members' in declaration order, except that one of a single member has
   that member's (concepts-vs-primitives.md) and an empty one has none. A
   value variant is a sum of its payloads, and
   an enum a sum of cases with none. A reference type's instance is the same
   shape after a `u32` backpointer (memory.md §3.3), a guest is a `u32`
   tether (§4.2), and a boxed member a pointer (adt.md §4). A function value
   is the address of the function a lambda was lifted to (L14). *)
let rec ty st span (t : Tty.t) : Nodes.Ty.t =
  match t with
  | _ when is_text t || is_list t -> Nodes.Ty.Handle
  | Tty.Intrinsic { namespace = "primitives"; name; args = [] } -> (
      match name with
      | "Unit" -> Nodes.Ty.Void
      | "Bool" -> Nodes.Ty.I1
      | "Int" | "I64" -> Nodes.Ty.I64
      | "I32" -> Nodes.Ty.I32
      | "Float" -> Nodes.Ty.F64
      | _ -> unhandled span t)
  | Tty.Guest _ -> Nodes.Ty.I32
  | Tty.Verb _ -> Nodes.Ty.Ptr
  | Tty.Intrinsic
      { namespace = "primitives"; name = "Array"; args = [ Tty.Type e; Tty.Number (Tty.Known n) ] }
    ->
      Nodes.Ty.Array (ty st span e, n)
  | Tty.Named _ -> (
      let member m = if boxed st t m then Nodes.Ty.Ptr else ty st span m in
      let sum ts = Nodes.Ty.Sum ts in
      match definition st t with
      | Some (T.Decl.Struct [], false) -> Nodes.Ty.Void
      | Some (T.Decl.Struct [ (_, m) ], false) when collapsed st t -> member m
      | Some (T.Decl.Struct ms, false) -> Nodes.Ty.Struct (List.map (fun (_, m) -> member m) ms)
      | Some (T.Decl.Variant cs, false) -> sum (List.map (fun (_, c) -> member c) cs)
      | Some (T.Decl.Enum cs, false) -> sum (List.map (fun _ -> Nodes.Ty.Void) cs)
      | Some (T.Decl.Struct ms, true) ->
          Nodes.Ty.Struct (Nodes.Ty.I32 :: List.map (fun (_, m) -> member m) ms)
      | Some (T.Decl.Variant cs, true) ->
          Nodes.Ty.Struct [ Nodes.Ty.I32; sum (List.map (fun (_, c) -> member c) cs) ]
      | Some (T.Decl.Enum cs, true) ->
          Nodes.Ty.Struct [ Nodes.Ty.I32; sum (List.map (fun _ -> Nodes.Ty.Void) cs) ]
      | Some (T.Decl.Distinct u, _) -> member u
      | _ -> unhandled span t)
  | _ -> unhandled span t

(* A list's elements lie this many bytes apart. *)
let stride st span t =
  let size, align = Nodes.Ty.size_align (ty st span t) in
  max 1 ((size + align - 1) / align * align)

(* Where a type's hosts and owned blocks are (memory.md §3.6, §4.5): the
   instance, when it is a reference type, each reference-type member, each
   handle, and each boxed member, down through variant payloads under the
   tag that makes each live, and through each of an array's elements. A
   guest is a tether, and owns nothing. *)
let rec positions st span (t : Tty.t) base tags : Layout.position list =
  let at kind size = { Layout.kind; offset = base; size; tags } in
  let handle = fst (Nodes.Ty.size_align Nodes.Ty.Handle) in
  match (t, element t) with
  | Tty.Guest _, _ -> []
  | _, Some e ->
      let elements = layout st span e in
      [ at Layout.Host handle; at (Layout.List { stride = stride st span e; elements }) handle ]
  | _ when is_text t -> [ at Layout.Host handle; at Layout.Text handle ]
  | ( Tty.Intrinsic
        { namespace = "primitives"; name = "Array"; args = [ Tty.Type e; Tty.Number (Tty.Known n) ] },
      _ ) -> (
      match positions st span e base tags with
      | [] -> []
      | _ ->
          let s = stride st span e in
          List.concat (List.init n (fun i -> positions st span e (base + (i * s)) tags)))
  | _ -> (
      match definition st t with
      | Some (T.Decl.Distinct u, _) -> positions st span u base tags
      | Some (T.Decl.Struct [ (_, m) ], false) when collapsed st t -> positions st span m base tags
      | Some (definition, reference) -> (
          let lowered = ty st span t in
          let own =
            if reference then [ at Layout.Host (fst (Nodes.Ty.size_align lowered)) ] else []
          in
          let member m base tags =
            if boxed st t m then
              let size = fst (Nodes.Ty.size_align (ty st span m)) in
              let payload = layout st span m in
              [ { Layout.kind = Layout.Box { size; payload }; offset = base; size = 8; tags } ]
            else positions st span m base tags
          in
          (* Where the members or the sum start: after the backpointer, in a
             reference type's instance. *)
          let starts ts =
            if reference then List.tl (Nodes.Ty.offsets ts) else Nodes.Ty.offsets ts
          in
          let variant cs sum =
            List.concat
              (List.mapi
                 (fun i (_, c) -> member c (sum + Nodes.Ty.payload_offset) (tags @ [ (sum, i) ]))
                 cs)
          in
          match (definition, lowered) with
          | T.Decl.Struct ms, Nodes.Ty.Struct ts ->
              own
              @ List.concat (List.map2 (fun (_, m) at -> member m (base + at) tags) ms (starts ts))
          | T.Decl.Variant cs, Nodes.Ty.Struct ts when reference ->
              own @ variant cs (base + List.hd (starts ts))
          | T.Decl.Variant cs, Nodes.Ty.Sum _ -> variant cs base
          | _ -> own)
      | None -> [])

(* A type's layout, by the type's symbol (Symbol.ty), which is also the name
   of its table in the IR. A layout that names itself, through a box, finds
   its name taken before it is done. *)
and layout st span (t : Tty.t) : Layout.t =
  let name = Symbol.ty t in
  if not (Hashtbl.mem st.layouts name) then begin
    Hashtbl.replace st.layouts name [];
    Hashtbl.replace st.layouts name (positions st span t 0 []);
    st.named <- name :: st.named
  end;
  name

(* Whether a local of this type is a host: a reference type's instance lives
   in its scope's arena (memory.md §3.3). A guest is a tether, not a host. *)
let hosted st t = (not (Tty.is_guest t)) && reference st t

(* Whether a place is reached through a host: a member or a case of a
   reference-type instance, or of one a guest names, an element of a list,
   and an element of an array reached through a host. A spawned call may
   write back a value there while another thread reads it (concurrency.md
   §4.4). *)
let rec through_host st (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Field { target; _ } | T.Expr.Case_read { target; _ } ->
      Tty.is_guest target.T.Expr.ty || reference st (Tty.strip_guest target.T.Expr.ty) || through_host st target
  | T.Expr.Subscript { target; _ } when Option.is_some (array_of (Tty.strip_guest target.T.Expr.ty)) ->
      through_host st target
  | T.Expr.Subscript _ -> true
  | _ -> false

(* Whether a value of this type owns a dynamic block (memory.md §3.6), which
   it returns when it dies and copies when it is copied. *)
let owns st span t =
  (not (Tty.is_guest t))
  && List.exists (fun (p : Layout.position) -> p.kind <> Layout.Host) (positions st span t 0 [])

(* Whether a local of this type is held in its scope's arena: a host, or a
   value that owns a block, which the scope's drain returns (L8). *)
let held st span t = hosted st t || owns st span t

(* The sum inside a variant or enum: a reference one's comes after its
   backpointer. *)
let sum_of st span t (value : Expr.t) =
  if reference st t then
    match ty st span t with
    | Nodes.Ty.Struct [ _; s ] -> { Expr.node = Expr.Member { value; index = 1 }; ty = s }
    | _ -> value
  else value

(* A case of a variant or enum, built: a reference one is its backpointer,
   untethered, and then the case. *)
let case_of st span t index (payload : Expr.t) =
  let lowered = ty st span t in
  match lowered with
  | Nodes.Ty.Struct [ bp; s ] when reference st t ->
      let untethered = { Expr.node = Expr.Int 0L; ty = bp } in
      let case = { Expr.node = Expr.Case { index; payload }; ty = s } in
      { Expr.node = Expr.Record [ (0, untethered); (1, case) ]; ty = lowered }
  | _ -> { Expr.node = Expr.Case { index; payload }; ty = lowered }

(* The cases of a variant or enum, in declaration order. *)
let cases st span t =
  let t = Tty.strip_guest t in
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
  match definition st (Tty.strip_guest t) with
  | Some (T.Decl.Variant cs, _) -> (
      match List.assoc_opt case cs with Some c -> c | None -> unhandled span t)
  | _ -> unhandled span t

let field_type st span t slot =
  match definition st (Tty.strip_guest t) with
  | Some (T.Decl.Struct ms, _) when slot < List.length ms -> snd (List.nth ms slot)
  | _ -> unhandled span t
