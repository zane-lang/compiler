module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
include To_string

let parse input =
  let lexbuf = Sedlexing.Utf8.from_string input in
  let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
  try
    MenhirLib.Convert.Simplified.traditional2revised Parser.package tokenizer
  with Parser.Error ->
    let (pos, _) = Sedlexing.lexing_positions lexbuf in
    Printf.printf "Parse error at line %d, column %d\n"
    pos.Lexing.pos_lnum
    (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
  raise Parser.Error
