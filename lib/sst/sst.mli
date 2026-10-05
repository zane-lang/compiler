(** Stage 2: desugaring, the CST to the simplified syntax tree
    (docs/design/desugaring.md). *)

module Nodes = Nodes

(** The type expressions a tree holds, for the passes that look for them. *)
module Walk = Walk

(** A parsed package with every shorthand written out. *)
val of_cst : Cst.Nodes.Package.t -> Nodes.Package.t

(** The tree as `zanec --sst` prints it. *)
val to_node : Nodes.Package.t -> Tree_graph.node

(** Every node with the text its span covers in [source], the text the CST
    was parsed from, as `span_dump --sst` prints it. *)
val to_span_text : source:string -> Nodes.Package.t -> string
