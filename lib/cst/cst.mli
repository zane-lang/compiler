(** Stage 1: parsing, source text to the concrete syntax tree
    (docs/design/stages.md). *)

module Nodes = Nodes

(** [parse filename text] parses one source file. Every position, and so
    every diagnostic, names [filename] as its file. *)
val parse : string -> string -> (Nodes.Package.t, Diagnostic.t) result

(** [parse_recovering filename text] parses one source file and keeps going
    past a syntax error: every declaration that parses is in the package, and
    every failure is a diagnostic, in source order. The first is the one [parse]
    gives when the first failure is a syntax error. *)
val parse_recovering : string -> string -> Nodes.Package.t * Diagnostic.t list

(** The tree as `zanec --cst` prints it. *)
val to_node : Nodes.Package.t -> Tree_graph.node

(** Every node with the text its span covers in [source], as `span_dump
    --cst` prints it. *)
val to_span_text : source:string -> Nodes.Package.t -> string

(** Whether the whole of a string is one lowercase identifier, as the lexer
    reads one (lexical.md §3). A name given outside source, such as a
    package's name on the command line, follows the same rule as a name in
    source. A keyword is not a lowercase identifier. *)
val is_lower_identifier : string -> bool

(** Whether the whole of a string is one uppercase identifier, as the lexer
    reads one. *)
val is_upper_identifier : string -> bool

(** The reserved words, as the lexer reads them. *)
val keywords : string list

(** A string literal's structure (lexical.md §7.1), read from the text the
    lexer keeps between its quotes. *)
module Text_literal : sig
  type part =
    | Text of string  (** Literal text, with its escaped quotes and backslashes read. *)
    | Name of { text : string; offset : int }
        (** An interpolation site [\%name], and the byte offset of [name] in
            the written text. *)
    | Bad_name of { found : found; offset : int }
        (** A [\%] that no value identifier follows, and the offset of the
            [\%]. *)

  and found = Type_identifier of string | Keyword of string | Nothing

  val scan : string -> part list
end
