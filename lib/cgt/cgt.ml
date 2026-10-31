(* Stage 4's entry module (docs/design/lowering.md). *)

module Nodes = Nodes
module Runtime = Runtime
module Math = Math
module Traverse = Traverse
module Memo = Memo
module Ref32 = Ref32
module List_pure = List_pure

let lower = Program.program
let to_node = To_tree_graph.program
