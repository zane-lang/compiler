(* Lowering's state (docs/design/lowering.md): the verbs and types a program
   has reached, what a TST local stands for where it is read, and the
   context a body is lowered in. How lowering refuses what it cannot handle
   yet is here too, since every part of it can. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes

exception Refused of Diagnostic.t

let refuse span message = raise (Refused (Diagnostic.error span message))

(* A verb to lower: a declaration, or a generic one's instance, which [key]
   tells apart from its other instances by the arguments it was given.
   [literals] binds parameters the function does not take to the literals a
   spawned call gave them (docs/design/lowering.md §9). *)
type verb = {
  decl : int;
  key : string;
  instance : (Tty.param * Tty.arg) list;
  signature : S.t;
  params : T.Local.t list;
  body : T.Block.t;
  literals : (int * T.Expr.t) list;
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
  (* The block being lowered, which holds its reference-type locals (L8). *)
  scope : scope;
}

(* A block's arena, made the first time the block holds something, and what
   settles each call spawned in it that can abort or exit, in case nothing
   reads it first. [wants] is each callee and `^T` parameter this block
   moves a fresh owner into: the block keeps an arena for them only if one
   of those callees can drop what it is given (Regions). *)
and scope = {
  mutable arena : int option;
  mutable settles : (unit -> Stat.t list) list;
  mutable wants : (string * int) list;
}

(* A `return` from an expansion stores into [result], which has the TST type
   [ret]: a value moves there, or a reference is minted, as into any storage. *)
and exit = Function | Leave of { label : int; result : int option; ret : Tty.t }

(* A package constant: its symbol, its package, its declared type and its
   value. *)
type constant = { symbol : string; package : string; ty : Tty.t; value : T.Expr.t }

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
  (* Each package constant, by declaration, and those whose making is still
     to lower. *)
  constants : (int, constant) Hashtbl.t;
  made : int Queue.t;
  (* The program's variables, latest first. *)
  mutable globals : Global.t list;
  (* How many functions the compiler has made for spawned calls to verbs
     expanded where they are called, and to intrinsics. *)
  expanded : int ref;
  intrinsics : int ref;
  (* Each field constructor's defaults, by entry slot, by verb key. *)
  defaults : (string, (int * T.Expr.t) list) Hashtbl.t;
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
  (* The verb's abort type, which an `abort` hands its value on as. *)
  mutable aborts : Tty.t;
  (* The function each spawned call runs through, latest first. *)
  mutable spawned : Func.t list;
  (* The symbol of the function being lowered, and each arena that is kept
     only if a callee can drop a fresh owner moved into it: by function and
     arena, the callees and `^T` parameters it is for (Regions). *)
  mutable current : string;
  wants : (string * int, (string * int) list) Hashtbl.t;
  (* Whether the build is a library's object, whether a package's verbs are
     exported from it for other objects to link against
     (docs/design/separate-compilation.md C5), what goes before each
     package's name in a symbol, and whether a package is a stamped
     dependency, which arrives as objects of its own (C1, C6). *)
  library : bool;
  (* Retain reachable stamped dependency bodies for optimization. They are
     never emitted as ordinary definitions in this object's code. *)
  import_bodies : bool;
  exports : string -> bool;
  stamp : string -> string;
  stamped : string -> bool;
  (* The lambda-variables other objects link against, and those a stamped
     dependency's objects define, by verb key. *)
  exported : (string, unit) Hashtbl.t;
  imported : (string, unit) Hashtbl.t;
}

(* A state that has reached nothing yet. *)
let create ~import_bodies ~library ~exports ~stamp ~stamped =
  {
    verbs = Hashtbl.create 64;
    types = Hashtbl.create 64;
    maps = Hashtbl.create 16;
    constants = Hashtbl.create 16;
    made = Queue.create ();
    expanded = ref 0;
    intrinsics = ref 0;
    globals = [];
    defaults = Hashtbl.create 8;
    lambdas = [];
    layouts = Hashtbl.create 16;
    named = [];
    symbols = Hashtbl.create 64;
    pending = Queue.create ();
    next = 0;
    returns = Fun.id;
    ret = Tty.Error;
    aborts = Tty.Error;
    spawned = [];
    current = "";
    wants = Hashtbl.create 16;
    library;
    import_bodies;
    exports;
    stamp;
    stamped;
    exported = Hashtbl.create 8;
    imported = Hashtbl.create 8;
  }

let fresh st =
  st.next <- st.next + 1;
  st.next
