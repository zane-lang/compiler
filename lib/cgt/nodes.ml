(* The code-generation tree (docs/lowering.md): the one input codegen reads.

   What it holds is what the machine does. A call names one function, every
   type has a layout, and nothing in it needs a declaration or an overload to
   be understood. It grows with each step of docs/lowering.md §8; what is here
   is what lowering handles so far. *)

(* A CGT type is a machine layout (L5). [View] is `@primitives$String`, a
   string view: a pointer to the first byte and a length in bytes, with no
   terminator (types.md §2.7). [Void] is `Unit`, which has no storage. *)
module Ty = struct
  type t = Void | I1 | I64 | F64 | View

  let to_string = function
    | Void -> "void"
    | I1 -> "i1"
    | I64 -> "i64"
    | F64 -> "f64"
    | View -> "view"
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
    (* A call to a function of the program, by its symbol (L6). *)
    | Call of { fn : string; args : t list }
    (* A call into the C runtime (L17), by the runtime's symbol. *)
    | Runtime of { fn : string; args : t list }
end

module Stat = struct
  type t = Eval of Expr.t | Return of Expr.t
end

module Func = struct
  type t = { symbol : string; params : (int * Ty.t) list; ret : Ty.t; body : Stat.t list }
end

(* One program is one module (L15). [entry] is the symbol of the root
   package's `main`, which the runtime's C `main` calls (L16). *)
module Program = struct
  type t = { funcs : Func.t list; entry : string }
end
