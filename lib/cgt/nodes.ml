(* The code-generation tree (docs/lowering.md): the one input codegen reads.

   What it holds is what the machine does. A call names one function, every
   type has a layout, and nothing in it needs a declaration or an overload to
   be understood. It grows with each step of docs/lowering.md §8; what is here
   is what lowering handles so far. *)

(* A CGT type is a machine layout (L5). [Text] is `@primitives$String`, the
   string view (types.md §2.7), a reference type whose instance is its
   backpointer and a handle (memory.md §3.6): a pointer to the first byte,
   the length in bytes, with no terminator, and the room of the block the
   bytes are in, which is 0 when it owns none: a literal's bytes are the
   module's own.
   [Void] is `Unit`, which has no storage.
   [Struct] is a value struct's members in declaration order, [Sum] a value
   variant's or enum's cases: a tag and room for the widest payload. [Ptr]
   is the address of a place, which is how a `mut` subject is passed (L6).
   [I32] is a reference-type instance's backpointer and a guest's tether,
   each an anchor's identity (memory.md §4.2). *)
module Ty = struct
  type t = Void | I1 | I32 | I64 | F64 | Text | Ptr | Struct of t list | Sum of t list

  (* Size and alignment in bytes on a 64-bit target, where a struct is laid
     out as C lays it out, and a sum is its tag and then its payload room at
     offset 8 (docs/lowering.md §9). *)
  let rec size_align = function
    | Void -> (0, 1)
    | I1 -> (1, 1)
    | I32 -> (4, 4)
    | I64 | F64 | Ptr -> (8, 8)
    | Text -> (32, 8)
    | Struct ts ->
        let size, align =
          List.fold_left
            (fun (size, align) t ->
              let s, a = size_align t in
              (((size + a - 1) / a * a) + s, max align a))
            (0, 1) ts
        in
        ((size + align - 1) / align * align, align)
    | Sum ts -> ( match words ts with 0 -> (4, 4) | n -> (8 + (8 * n), 8))

  (* A sum's payload room, in 8-byte words: enough for its widest case, and
     aligned for every one, since no layout here needs more than 8. *)
  and words ts = List.fold_left (fun n t -> max n ((fst (size_align t) + 7) / 8)) 0 ts

  (* Where each member of a struct of [ts] starts. *)
  let offsets ts =
    let _, offsets =
      List.fold_left
        (fun (at, acc) t ->
          let s, a = size_align t in
          let start = (at + a - 1) / a * a in
          (start + s, start :: acc))
        (0, []) ts
    in
    List.rev offsets

  (* A sum's payload starts after its tag. *)
  let payload_offset = 8

  let rec to_string = function
    | Void -> "void"
    | I1 -> "i1"
    | I32 -> "i32"
    | I64 -> "i64"
    | F64 -> "f64"
    | Text -> "text"
    | Ptr -> "ptr"
    | Struct ts -> "{" ^ String.concat ", " (List.map to_string ts) ^ "}"
    | Sum ts -> "<" ^ String.concat " | " (List.map to_string ts) ^ ">"
end

(* Where a type's hosts and owned blocks are (memory.md §3.6, §4.5): the
   instance itself when it is a reference type, every reference-type host
   inside it, outermost first, and every string, whose handle may own a
   dynamic block. A position inside a variant payload is there only while
   each of [tags] -- a tag's offset and the case it must hold -- is live. *)
module Layout = struct
  type kind = Host | Text
  type position = { kind : kind; offset : int; size : int; tags : (int * int) list }
  type t = position list
end

module Expr = struct
  type t = { node : node; ty : Ty.t }

  and node =
    | Int of int64
    | Float of float
    | Bool of bool
    (* A view over constant bytes: a string literal the program embeds. *)
    | Text of string
    | Unit
    | Local of int
    (* The address of a local's slot, and the value at an address. *)
    | Address of int
    | Deref of t
    (* A call to a function of the program, by its symbol (L6). *)
    | Call of { fn : string; args : t list }
    (* A call into the C runtime (L17), by the runtime's symbol. A string
       goes to it, and comes back from it, through the address of a copy. *)
    | Runtime of { fn : string; args : t list }
    (* A scalar primitive's operator, on two operands of one type: [I64] and
       [F64] add, multiply, divide, compare; [I1] adds as `or`, multiplies as
       `and` and compares (operators.md §2.4). *)
    | Binary of { op : binop; left : t; right : t }
    (* `~`: an [I64] or [F64] negated, an [I1] inverted. *)
    | Flip of t
    (* A verb expanded where it is called (L11): its body runs here, and a
       `return` in it stores [result] and leaves [label]. The expression's
       value is [result] once the body is left. *)
    | Expand of { label : int; body : stat list; result : int option }
    (* A struct built from its members, each given with its index and run in
       the order listed, which is the order they were written. *)
    | Record of (int * t) list
    | Member of { value : t; index : int }
    (* A sum with case [index] live, and the payload of case [index], read
       when that case is live. *)
    | Case of { index : int; payload : t }
    | Payload of { value : t; index : int }
    (* The address of a member inside the place an address names, down
       [path] through the struct type [within]. *)
    | Offset of { base : t; within : Ty.t; path : int list }
    (* A guest's tether minted from a host's address, the address a tether
       resolves to, and the identity it ends at (L9). *)
    | Mint of t
    | Resolve of t
    | Terminal of t
    (* A move out of the place an address names: its value, and the place
       is spent (memory.md §3.7). *)
    | Take of { address : t; layout : Layout.t }

  and binop = Add | Mul | Div | Eq | Less

  (* Where an assignment stores: a local's slot, or the place the address in
     it names, then a member path through the struct of type [ty]. *)
  and place = { local : int; deref : bool; ty : Ty.t; path : int list }

  (* A local is a slot the function owns (L3): [Let] fills a new one,
     [Assign] a place in an existing one, and [Expr.Local] reads it. [If] and
     [Repeat] are `@controlflow$branch` and `@controlflow$repeat`, [Switch]
     jumps on a sum's tag (L13), and [Leave] ends the [Expand] its label
     names. [Scope] is a block's arena (L8), entered before its body and
     drained on every way out of it, and [Host] fills a new local whose slot
     is in that arena. *)
  and stat =
    | Let of { id : int; value : t }
    | Host of { id : int; scope : int; value : t; layout : Layout.t }
    | Scope of { id : int; body : stat list }
    | Assign of { place : place; value : t }
    | Eval of t
    | Return of t
    | If of { cond : t; body : stat list }
    | Repeat of { count : t; body : stat list }
    | Switch of { value : t; cases : (int * stat list) list }
    | Leave of int
    (* A store through an address, and a reference-type host replaced
       there, its identities kept, merged or floated (memory.md §4.5). *)
    | Store of { address : t; value : t }
    | Overwrite of { address : t; value : t; layout : Layout.t }

  let binop_to_string = function
    | Add -> "+"
    | Mul -> "*"
    | Div -> "/"
    | Eq -> "=="
    | Less -> "<"
end

module Stat = struct
  type t = Expr.stat =
    | Let of { id : int; value : Expr.t }
    | Host of { id : int; scope : int; value : Expr.t; layout : Layout.t }
    | Scope of { id : int; body : t list }
    | Assign of { place : Expr.place; value : Expr.t }
    | Eval of Expr.t
    | Return of Expr.t
    | If of { cond : Expr.t; body : t list }
    | Repeat of { count : Expr.t; body : t list }
    | Switch of { value : Expr.t; cases : (int * t list) list }
    | Leave of int
    | Store of { address : Expr.t; value : Expr.t }
    | Overwrite of { address : Expr.t; value : Expr.t; layout : Layout.t }

  (* A store into a whole local. *)
  let assign id (value : Expr.t) =
    Assign { place = { local = id; deref = false; ty = value.Expr.ty; path = [] }; value }
end

module Func = struct
  type t = { symbol : string; params : (int * Ty.t) list; ret : Ty.t; body : Stat.t list }
end

(* One program is one module (L15). [entry] is the symbol of the root
   package's `main`, which the runtime's C `main` calls (L16). *)
module Program = struct
  type t = { funcs : Func.t list; entry : string }
end
