module Nodes = Nodes
let to_node = To_tree_graph.to_node
let to_span_text = To_span_text.render

let parse = Parse.package
let parse_recovering = Parse.package_recovering
let is_lower_identifier = Lexer.is_lower_identifier

let is_upper_identifier text =
  match Lexer.token (Sedlexing.Utf8.from_string text) with
  | Parser.UIDENT lexeme -> String.equal lexeme text
  | _ -> false
  | exception (Lexer.Lexing_error | Sedlexing.MalFormed) -> false

let keywords = Lexer.words
module Text_literal = Text_literal
