(** Stage 1: parsing, source text to the concrete syntax tree
    (docs/design/stages.md). *)

module Nodes = Nodes

(** [parse filename text] parses one source file. [filename] is what every
    position, and so every diagnostic, names. *)
val parse : string -> string -> (Nodes.Package.t, Diagnostic.t) result

(** The tree as `zanec --cst` prints it. *)
val to_node : Nodes.Package.t -> Tree_graph.node

(** Every node with the text its span covers in [source], as `span_dump
    --cst` prints it. *)
val to_span_text : source:string -> Nodes.Package.t -> string
