(** Stage 3: semantics, packages of SSTs to the typed syntax tree
    (docs/design/semantics.md). *)

(** The packages of a build, read from their directories. *)
module Assembly = Assembly

module Ty = Ty
module Signature = Signature
module Nodes = Nodes

(** A decimal literal's single, which lowering embeds as checked here. *)
module Decimal = Decimal

(** Which verbs can exit, which lowering asks of a verb's body. *)
module Exits = Exits

(** The intrinsic namespaces' verbs, which lowering looks a method up in. *)
module Intrinsics = Intrinsics

(** The passes, run in order, and what a check gives back. *)
module Semantics = Semantics

(** Every pass over the assembled packages: the program, and every problem
    found, in source order. *)
val check : Assembly.package list -> Semantics.result

(** The program as `zanec --decls` (without [bodies]) and `--tst` print it. *)
val to_node : bodies:bool -> Nodes.Program.t -> Tree_graph.node

(** Every node with the text its span covers, as `span_dump --tst` prints
    it. *)
val to_span_text : Assembly.package list -> Nodes.Program.t -> string
