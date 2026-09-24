module Assembly = Assembly
module Ty = Ty
module Signature = Signature
module Nodes = Nodes
module Semantics = Semantics

let check = Semantics.check
let render_diagnostic = Semantics.render
let to_node = To_tree_graph.to_node

let to_span_text packages program =
  To_span_text.render ~source:(Semantics.source packages) program
