(** Stage 4: lowering, the TST to the code-generation tree
    (docs/design/lowering.md). *)

module Nodes = Nodes

(** The C runtime's functions that emitted code calls. *)
module Runtime = Runtime

(** The math functions of `@math$`, and which of them are exact. *)
module Math = Math

(** What each node is made of, a walk over every node, and a rewrite, for
    every pass over the tree. *)
module Traverse = Traverse

(** The functions remembered while the program runs, with `--memoize`. *)
module Memo = Memo

(** Experimental: whether references are stored in 32 bits. *)
module Ref32 = Ref32

(** The program, from the root package's `main`, or from every function of
    the root when it is a [library]. A construct lowering does not handle
    yet is refused with a diagnostic at it, and so is a type no main
    context's range of frames of [fixed_region] bytes could hold
    ([Runtime.default_fixed_region] when absent). [import_bodies] retains
    reachable stamped dependencies' functions with linkage that lets LLVM
    inline them and defines nothing. *)
val lower :
  ?library:bool ->
  ?import_bodies:bool ->
  ?fixed_region:int ->
  Tst.Nodes.Program.t ->
  (Nodes.Program.t, Diagnostic.t) result

(** The tree as `zanec --cgt` prints it. *)
val to_node : Nodes.Program.t -> Tree_graph.node
