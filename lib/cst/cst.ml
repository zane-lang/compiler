module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
include To_tree_graph

let parse filename input =
  let lexbuf = Sedlexing.Utf8.from_string input in
  let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
  try
    Ok (MenhirLib.Convert.Simplified.traditional2revised Parser.package tokenizer)
  with Parser.Error _tokenizer | Lexer.Lexing_error ->
    let (pos_start, pos_end) = Sedlexing.lexing_positions lexbuf in
    Error (Parse_error.format_parse_error filename input pos_start pos_end)
