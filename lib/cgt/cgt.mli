(** Stage 4: lowering, the TST to the code-generation tree
    (docs/design/lowering.md). *)

module Nodes = Nodes

(** The C runtime's functions that emitted code calls. *)
module Runtime = Runtime

(** The program, from the root package's `main`, or from every function of
    the root when it is a [library]. A construct lowering does not handle
    yet is refused with a diagnostic at it. *)
val lower : ?library:bool -> Tst.Nodes.Program.t -> (Nodes.Program.t, Diagnostic.t) result

(** The tree as `zanec --cgt` prints it. *)
val to_node : Nodes.Program.t -> Tree_graph.node
