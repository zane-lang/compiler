(* Stage 4's entry module (docs/lowering.md). *)

module Nodes = Nodes
module Lower = Lower

let lower = Lower.program
let to_node = To_tree_graph.program
