module Assembly = Assembly
module Ty = Ty
module Signature = Signature
module Nodes = Nodes
module Decimal = Decimal
module Exits = Exits
module States = States
module Traverse = Traverse
module Intrinsics = Intrinsics
module Semantics = Semantics
module Uses = Uses
module Index = Index

let check ?interfaces ?uses packages = Semantics.check ?interfaces ?uses packages
let to_node = To_tree_graph.to_node

let to_span_text packages program =
  To_span_text.render ~source:(Semantics.source packages) program
