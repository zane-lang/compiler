module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
include To_string

let parse input =
    let lexbuf = Sedlexing.Utf8.from_string input in
    let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
    MenhirLib.Convert.Simplified.traditional2revised Parser.prog tokenizer
