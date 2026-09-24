module Span = Source.Span
module Nodes = Nodes
module Lower = Lower
module To_span_text = To_span_text
module Walk = Walk
include To_tree_graph

(* The entry point: a parsed package, with every shorthand written out.

   Named [of_cst] rather than [lower] because the module already says which
   direction this goes, and because the pass itself is [Lower] for anyone who
   wants its parts. *)
let of_cst = Lower.package
