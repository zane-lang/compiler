module Span = Span
module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
include To_tree_graph

(* [Parse_error.format_parse_error] indexes [input] with [String.sub] and
   [String.length], so it needs byte offsets. [Sedlexing.lexing_positions]
   counts code points, which drifts the caret on non-ASCII input; ask for the
   byte positions instead. *)
let error_positions lexbuf = Sedlexing.lexing_bytes_positions lexbuf

let parse filename input =
  (* [Sedlexing.Utf8.from_string] raises [Sedlexing.MalFormed] on invalid UTF-8,
     so it has to sit inside the handler too. Until it returns there is no
     lexbuf to take positions from, hence the separate match. *)
  match Sedlexing.Utf8.from_string input with
  | exception Sedlexing.MalFormed ->
      let position =
        { Lexing.pos_fname = filename; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 }
      in
      Error
        (Parse_error.format_parse_error ~message:"Malformed UTF-8 input"
           filename input position position)
  | lexbuf -> (
      let tokenizer = Sedlexing.with_tokenizer Lexer.token lexbuf in
      let located ?message () =
        let pos_start, pos_end = error_positions lexbuf in
        Error
          (Parse_error.format_parse_error ?message filename input pos_start
             pos_end)
      in
      try
        let package =
          MenhirLib.Convert.Simplified.traditional2revised Parser.package
            tokenizer
        in
        (* Statement shape is checked here rather than in the grammar's
           actions: under GLR an action runs on branches that are abandoned a
           token later, so rejecting from one ends the parse instead of the
           branch. See [Statement_check]. *)
        match Statement_check.check package with
        | Ok () -> Ok package
        | Error (message, position) ->
            Error
              (Parse_error.format_parse_error ~message filename input position
                 position)
      with
      | Parse_error.Rejected message -> located ~message ()
      | Parser.Error _ | Lexer.Lexing_error | Sedlexing.MalFormed -> located ())
