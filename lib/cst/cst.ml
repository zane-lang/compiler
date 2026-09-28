(* Re-exported so a caller that has a [Cst.Span.t] keeps working; the type
   itself lives in [Source], below every stage that points at source. *)
module Span = Source.Span
module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
module To_span_text = To_span_text
include To_tree_graph

let parse = Parse.package
