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

(* The callee a want names when the call has no function Regions can see,
   a function value's or a verb expanded where it is called: no symbol is
   empty, so Regions finds no parameter of it kept, and the arena stays. *)
let dropping = ""

(* A step from an owner down to a value it holds inline: a member, a case's
   payload or an element. Any two cases are one step, since their payloads
   share one room, and so are any two elements, whose indices are not
   known. *)
type step = Member of string | Case | Elem

(* A place written back into: its value's type, and where it is, when it is
   known, as the type of the innermost owner it is reached through and the
   steps from there. *)
type written = { of_type : Tty.t; place : (Tty.t * step list) option }

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
  (* The lambdas whose type C can call, with the C types they cross as
     (docs/design/ffi.md F11), and [package], the root package's symbol
     prefix, which names the C entries of lambdas other objects lift too. *)
  mutable callbacks : Callback.t list;
  mutable package : string;
  (* Symbols already lowered or on their way, by verb key, and the verbs
     still to lower. *)
  symbols : (string, string) Hashtbl.t;
  pending : verb Queue.t;
  (* The next local or label of the function being lowered, and its locals
     that hold a value type (Func.values). *)
  mutable next : int;
  mutable values : int list;
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
  (* Whether this is a program none of whose code spawns, which runs on
     one thread. *)
  exclusive : bool;
  (* The places a spawned call may write a value back into, reached through
     an owner (concurrency.md §4.4), or [None] for a library's, which a
     program that spawns may write back any value into (Type_layout.snapshots). *)
  mutable written_back : written list option;
  exports : string -> bool;
  stamp : string -> string;
  stamped : string -> bool;
  (* The lambda-variables other objects link against, and those a stamped
     dependency's objects define, by verb key. *)
  exported : (string, unit) Hashtbl.t;
  imported : (string, unit) Hashtbl.t;
  (* The size of the main context's range of frames, which no value may
     outgrow (`--fixed-region`), and each layout whose size has been
     checked against it (Type_layout.ty). *)
  region : int;
  sized : (Nodes.Ty.t, unit) Hashtbl.t;
  (* Whether a member is boxed in the type that holds it, by holder and
     member (Type_layout.boxed). *)
  boxes : (Tty.t * Tty.t, bool) Hashtbl.t;
  (* Each expression verb's size with what it expands written out, by verb
     key, or [None] for a verb not expanded where it is called (L11,
     Verbs.inlines). *)
  sizes : (string, int option) Hashtbl.t;
  (* Each foreign verb's C function, by verb key, and each thunk the
     functions lowered so far call, latest first (docs/design/ffi.md F8). *)
  foreign_verbs : (string, T.Foreign.t) Hashtbl.t;
  mutable thunks : Foreign.t list;
  (* Each body's subjects, parameters and binders, which say whether a
     place overwritten is settled (Tst.States.of_program). *)
  mutable places : Tst.States.t option;
}

(* The walk over a verb's body, in [Lower], as the rest of lowering reaches
   it: the modules beside [Lower] are outside its recursion, so each of their
   functions takes this as its first argument. *)
type walk = {
  expr : state -> ctx -> T.Expr.t -> Expr.t;
  value_of : state -> ctx -> T.Expr.t -> Expr.t;
  addr : state -> ctx -> Source.Span.t -> T.Expr.t -> Expr.t option;
  borrow : state -> ctx -> Source.Span.t -> T.Expr.t -> Expr.t;
  lend : state -> ctx -> Source.Span.t -> T.Expr.t -> Expr.t;
  reference_to : state -> ctx -> Source.Span.t -> T.Expr.t -> Expr.t;
  moved : state -> ctx -> Source.Span.t -> Tty.t -> T.Expr.t -> Expr.t;
  is_place : T.Expr.t -> bool;
  block : ?enter:(scope -> Stat.t list) -> state -> ctx -> T.Block.t -> Stat.t list;
  primitive : state -> ctx -> Source.Span.t -> string -> T.Arg.t list -> Tty.t -> Expr.t;
}

(* A state that has reached nothing yet. *)
let create ~region ~import_bodies ~library ~exclusive ~exports ~stamp ~stamped =
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
    callbacks = [];
    package = "";
    layouts = Hashtbl.create 16;
    named = [];
    symbols = Hashtbl.create 64;
    pending = Queue.create ();
    next = 0;
    values = [];
    returns = Fun.id;
    ret = Tty.Error;
    aborts = Tty.Error;
    spawned = [];
    current = "";
    wants = Hashtbl.create 16;
    library;
    import_bodies;
    exclusive;
    written_back = (if library then None else Some []);
    exports;
    stamp;
    stamped;
    exported = Hashtbl.create 8;
    imported = Hashtbl.create 8;
    region;
    sized = Hashtbl.create 64;
    boxes = Hashtbl.create 64;
    sizes = Hashtbl.create 64;
    foreign_verbs = Hashtbl.create 8;
    thunks = [];
    places = None;
  }

let fresh st =
  st.next <- st.next + 1;
  st.next
