module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
include To_tree_graph

let parse filename input =
  let lexbuf = Sedlexing.Utf8.from_string input in
  let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
  try
    MenhirLib.Convert.Simplified.traditional2revised Parser.package tokenizer
  with Parser.Error tokenizer ->
    let (pos_start, pos_end) = Sedlexing.lexing_positions lexbuf in
    Parse_error.print_parse_error filename input pos_start pos_end
