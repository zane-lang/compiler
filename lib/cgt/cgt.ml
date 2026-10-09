(* Stage 4's entry module (docs/design/lowering.md). *)

module Nodes = Nodes
module Runtime = Runtime

let lower = Program.program
let expr_parts = Regions.expr_parts
let stat_parts = Regions.stat_parts
let to_node = To_tree_graph.program
