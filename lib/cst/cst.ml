(* Re-exported so a caller that has a [Cst.Span.t] keeps working; the type
   itself lives in [Source], below every stage that points at source. *)
module Span = Source.Span
module Nodes = Nodes
module Parser = Parser
module Lexer = Lexer
module To_span_text = To_span_text
include To_tree_graph

(* Positions as byte offsets, which is what every consumer of one here needs.

   [Parse_error.format_parse_error] indexes [input] with [String.sub] and
   [String.length]. So does anything that reads the source a [Span.t] covers,
   which is now every node in the tree. [Sedlexing.lexing_positions] counts code
   points instead, which agrees with the byte offset only while the input is
   ASCII and drifts one position per extra byte after that -- and Zane
   identifiers are Unicode ([Lexer]'s [alphabetic], [lowercase] and [uppercase]
   classes), so non-ASCII input is ordinary rather than exotic. *)
let byte_positions lexbuf = Sedlexing.lexing_bytes_positions lexbuf

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
      (* Without this the lexbuf carries the empty filename sedlex starts it
         with, and every position Menhir derives from it -- so every [Span.t] in
         the tree -- names no file. The error path never noticed, because it is
         handed [filename] separately. *)
      Sedlexing.set_filename lexbuf filename;
      (* Not [Sedlexing.with_tokenizer]: it reports code-point positions, and
         the spans built from them are what the tree keeps. Same reason
         [byte_positions] exists for the error path, applied one layer earlier
         so the tree is right rather than only the message. *)
      let tokenizer () =
        let token = Lexer.token lexbuf in
        let pos_start, pos_end = byte_positions lexbuf in
        (token, pos_start, pos_end)
      in
      let located ?message () =
        let pos_start, pos_end = byte_positions lexbuf in
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
