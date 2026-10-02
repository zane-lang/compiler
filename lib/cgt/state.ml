(* Lowering's state (docs/design/lowering.md): the verbs and types a program
   has reached, what a TST local stands for where it is read, and the
   context a body is lowered in. How lowering refuses what it cannot handle
   yet is here too, since every part of it can. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes

type problem = Diagnostic of Diagnostic.t | Message of string

exception Refused of problem

let refuse span message = raise (Refused (Diagnostic (Diagnostic.error span message)))

(* A verb to lower: a declaration, or a generic one's instance, which [key]
   tells apart from its other instances by the arguments it was given. *)
type verb = {
  decl : int;
  key : string;
  instance : (Tty.param * Tty.arg) list;
  signature : S.t;
  params : T.Local.t list;
  body : T.Block.t;
}

(* What a TST local stands for where lowering reads it. A verb that is
   expanded (L11) binds its parameters to these: a slot of the function it is
   expanded into, a literal its concept parameter was given, or the code of a
   block argument. A `mut` subject is a [Pointer]: a slot holding the address
   of the caller's place (L6). A local bound to a spawned call's result is a
   [Future]: what waits for the call and settles how it ended, and the
   address of its result, which has none when it is `Unit`. *)
type binding =
  | Slot of int
  | Pointer of int
  | Literal of T.Expr.t
  | Code of closure
  | Future of { settle : unit -> Stat.t list; at : Expr.t option }

(* A block argument keeps the context it was written in, so its locals and
   its `return` mean what they meant there. *)
and closure = { block : T.Block.t; ctx : ctx }

and ctx = {
  env : (int, binding) Hashtbl.t;
  (* Where a `return` goes: out of the function, or out of the expansion
     that is being lowered, storing its result. *)
  exit : exit;
  (* The verbs being expanded around this point, so one that would expand
     into itself is refused rather than expanded forever. *)
  expanding : int list;
  (* Where an `abort` goes (L12): out of the function by its aborted
     outcome, or into the handler of the call or `match` it belongs to. *)
  abort : Source.Span.t -> Expr.t -> Stat.t list;
  (* Where a `resolve` goes: past the operation its handler handles. *)
  resolve : (Tty.t -> Expr.t -> Stat.t list) option;
  (* What ends this invocation with `Unit`: a return from the function, or
     leaving the expansion (control-flow.md §4.2). *)
  finish : Source.Span.t -> Stat.t list;
  (* What `@controlflow$exitFromCall` does here: end the invocation that
     called the verb whose body it is in. *)
  exit_call : Source.Span.t -> Stat.t list;
  (* The block being lowered, which hosts its reference-type locals (L8). *)
  scope : scope;
}

(* A block's arena, made the first time the block hosts something, and what
   settles each call spawned in it that can abort or exit, in case nothing
   reads it first. *)
and scope = { mutable arena : int option; mutable settles : (unit -> Stat.t list) list }

(* A `return` from an expansion stores into [result], which has the TST type
   [ret]: a value moves there, or a guest is minted, as into any storage. *)
and exit = Function | Leave of { label : int; result : int option; ret : Tty.t }

type state = {
  (* Each verb by its [key]: a declaration's id, and an instance's with its
     arguments. *)
  verbs : (string, verb) Hashtbl.t;
  (* Each declared type's parameters, definition, and whether it is a
     reference type. *)
  types : (string * string, Tty.param list * T.Decl.definition * bool) Hashtbl.t;
  (* Each layout the program names, by the type it describes (L9). *)
  layouts : (string, Layout.position list) Hashtbl.t;
  mutable named : string list;
  (* Each enum map: the enum it ranges over, and its entries. *)
  maps : (int, Tty.t * (string * T.Expr.t) list) Hashtbl.t;
  (* Each package constant's value, by declaration. *)
  constants : (int, T.Expr.t) Hashtbl.t;
  (* Each lambda's symbol (docs/design/symbols.md), by its body, which is the
     one thing that tells two lambdas apart: an instance's body has lambdas
     of its own. *)
  mutable lambdas : (T.Block.t * string) list;
  (* Symbols already lowered or on their way, by verb key, and the verbs
     still to lower. *)
  symbols : (string, string) Hashtbl.t;
  pending : verb Queue.t;
  (* The next local or label of the function being lowered. *)
  mutable next : int;
  (* What a `return` from the function being lowered returns its value as:
     itself, or the done case of its outcome (L12), and the verb's return
     type. *)
  mutable returns : Expr.t -> Expr.t;
  mutable ret : Tty.t;
  (* The function each spawned call runs through, latest first. *)
  mutable spawned : Func.t list;
  (* The root package when it is a library built into an object, whose
     symbols carry its placeholder and other objects link against
     (docs/design/separate-compilation.md C5), and what goes before each
     package's name in a symbol. *)
  library : string option;
  stamp : string -> string;
  (* The lambda-variables other objects link against, by verb key. *)
  exported : (string, unit) Hashtbl.t;
}

let fresh st =
  st.next <- st.next + 1;
  st.next
