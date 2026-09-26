(* The code-generation tree (docs/lowering.md): the one input codegen reads.

   What it holds is what the machine does. A call names one function, every
   type has a layout, and nothing in it needs a declaration or an overload to
   be understood. It grows with each step of docs/lowering.md §8; what is here
   is what lowering handles so far. *)

(* A CGT type is a machine layout (L5). [View] is `@primitives$String`, a
   string view: a pointer to the first byte and a length in bytes, with no
   terminator (types.md §2.7). [Void] is `Unit`, which has no storage.
   [Struct] is a value struct's members in declaration order, [Sum] a value
   variant's or enum's cases: a tag and room for the widest payload. [Ptr]
   is the address of a place, which is how a `mut` subject is passed (L6). *)
module Ty = struct
  type t = Void | I1 | I64 | F64 | View | Ptr | Struct of t list | Sum of t list

  let rec to_string = function
    | Void -> "void"
    | I1 -> "i1"
    | I64 -> "i64"
    | F64 -> "f64"
    | View -> "view"
    | Ptr -> "ptr"
    | Struct ts -> "{" ^ String.concat ", " (List.map to_string ts) ^ "}"
    | Sum ts -> "<" ^ String.concat " | " (List.map to_string ts) ^ ">"
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
    (* A call into the C runtime (L17), by the runtime's symbol. *)
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

  and binop = Add | Mul | Div | Eq | Less

  (* Where an assignment stores: a local's slot, or the place the address in
     it names, then a member path through the struct of type [ty]. *)
  and place = { local : int; deref : bool; ty : Ty.t; path : int list }

  (* A local is a slot the function owns (L3): [Let] fills a new one,
     [Assign] a place in an existing one, and [Expr.Local] reads it. [If] and
     [Repeat] are `@controlflow$branch` and `@controlflow$repeat`, [Switch]
     jumps on a sum's tag (L13), and [Leave] ends the [Expand] its label
     names. *)
  and stat =
    | Let of { id : int; value : t }
    | Assign of { place : place; value : t }
    | Eval of t
    | Return of t
    | If of { cond : t; body : stat list }
    | Repeat of { count : t; body : stat list }
    | Switch of { value : t; cases : (int * stat list) list }
    | Leave of int

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
    | Assign of { place : Expr.place; value : Expr.t }
    | Eval of Expr.t
    | Return of Expr.t
    | If of { cond : Expr.t; body : t list }
    | Repeat of { count : Expr.t; body : t list }
    | Switch of { value : Expr.t; cases : (int * t list) list }
    | Leave of int

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
