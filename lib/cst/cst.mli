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

(** Whether the whole of a string is one lowercase identifier, as the lexer
    reads one (lexical.md §3): a name such as a package's, given anywhere but
    in source, is held to the rule the source is. A keyword is not one. *)
val is_lower_identifier : string -> bool
