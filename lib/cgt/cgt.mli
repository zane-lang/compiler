(** Stage 4: lowering, the TST to the code-generation tree
    (docs/design/lowering.md). *)

module Nodes = Nodes

(** The C runtime's functions that emitted code calls. *)
module Runtime = Runtime

(** The program, from the root package's `main`, or from every function of
    the root when it is a [library]. A construct lowering does not handle
    yet is refused with a diagnostic at it. [import_bodies] retains reachable
    stamped dependencies' functions with optimization-only linkage. *)
val lower :
  ?library:bool -> ?import_bodies:bool -> Tst.Nodes.Program.t -> (Nodes.Program.t, Diagnostic.t) result

(** What an expression or a statement is made of: the expressions directly
    in it, and the statement lists directly in it. *)
val expr_parts : Nodes.Expr.t -> Nodes.Expr.t list * Nodes.Stat.t list list

val stat_parts : Nodes.Stat.t -> Nodes.Expr.t list * Nodes.Stat.t list list

(** The tree as `zanec --cgt` prints it. *)
val to_node : Nodes.Program.t -> Tree_graph.node
