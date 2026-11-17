(* Stage 4's entry module (docs/design/lowering.md). *)

module Nodes = Nodes
module Runtime = Runtime
module Math = Math
module Traverse = Traverse
module Memo = Memo
module Ref32 = Ref32
module List_pure = List_pure

let lower = Program.program

type write_backs = State.named_written list

let write_backs = Program.write_backs
let read_write_backs = Write_backs.of_text
let to_node = To_tree_graph.program
