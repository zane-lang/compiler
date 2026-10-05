module Nodes = Nodes
module Walk = Walk

let to_node = To_tree_graph.to_node
let to_span_text = To_span_text.render

(* The entry point: a parsed package, with every shorthand written out.

   Named [of_cst] rather than [lower] because the module already says which
   direction this goes. *)
let of_cst = Lower.package
