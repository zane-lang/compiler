(* The parse driver: UTF-8 input to a checked [Nodes.package], through the
   lexer, the GLR parser and the statement check. [Cst.parse] is [package]. *)

module Span = Source.Span

(* Positions as byte offsets, which is what every consumer of one here needs.

   [Diagnostic.render] indexes the source with [String.sub] and
   [String.length]. So does anything that reads the source a [Span.t] covers,
   which is now every node in the tree. [Sedlexing.lexing_positions] counts code
   points instead, which agrees with the byte offset only while the input is
   ASCII and drifts one position per extra byte after that -- and Zane
   identifiers are Unicode ([Lexer]'s [alphabetic], [lowercase] and [uppercase]
   classes), so non-ASCII input is ordinary rather than exotic. *)
let byte_positions lexbuf = Sedlexing.lexing_bytes_positions lexbuf

(* The package, or the single diagnostic that refused it: the parse stops at
   the first failure. [package_recovering], below, goes on past it. The caller
   decides how to show the diagnostic; [Diagnostic.render] gives the text for a
   terminal. *)
let package filename input =
  (* [Sedlexing.Utf8.from_string] raises [Sedlexing.MalFormed] on invalid UTF-8,
     so it has to sit inside the handler too. Until it returns there is no
     lexbuf to take positions from, hence the separate match. *)
  match Sedlexing.Utf8.from_string input with
  | exception Sedlexing.MalFormed ->
      let position =
        { Lexing.pos_fname = filename; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 }
      in
      Error
        (Diagnostic.error
           (Span.of_loc (position, position))
           "Malformed UTF-8 input")
  | lexbuf -> (
      (* Without this the lexbuf carries the empty filename sedlex starts it
         with, and every position Menhir derives from it -- so every [Span.t] in
         the tree -- names no file. That includes the span of a diagnostic,
         whose rendering reads the file name off it. *)
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
      let located message =
        Error (Diagnostic.error (Span.of_loc (byte_positions lexbuf)) message)
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
        Result.map (fun () -> package) (Statement_check.check package)
      with
      | Parse_error.Rejected message -> located message
      | Parser.Error _ | Lexer.Lexing_error | Sedlexing.MalFormed ->
          located "Parse error")

(* Recovery from syntax errors, by restarting the parse.

   It happens around the parser, not in the grammar: Menhir's GLR back-end has
   neither the `error` token nor the incremental API that recovery inside a
   parse would need. Ranges of the token stream are parsed as whole packages,
   and a failed parse is never continued. Under GLR one branch dying is how an
   ambiguity resolves, so only a parse whose every branch died says the input
   is wrong, and what follows such a failure is decided between parses, where
   no action runs.

   Each range ends at an end of input rather than at the end of one
   declaration: a GLR parser stops as soon as one branch accepts, so a start
   symbol for a single declaration would drop the branches that read on.

   A boundary is where a package-scope declaration may start: just after a `;`
   or `}` written outside every brace (lexical.md §6.3). It is a guess, not a
   parse -- a braced declaration can continue past its `}` -- so a prefix cut at
   one is parsed again to confirm it, and a boundary whose prefix fails is
   given up for an earlier one. *)

type lexed =
  | Token of Parser.token
  | Bad  (** The lexer refused the text here; any parse reaching it fails. *)

type entry = { lexed : lexed; start_pos : Lexing.position; end_pos : Lexing.position }

exception Unlexable

let lex_all lexbuf =
  let rec go acc =
    match Lexer.token lexbuf with
    | Parser.EOF ->
        let start_pos, end_pos = byte_positions lexbuf in
        List.rev ({ lexed = Token Parser.EOF; start_pos; end_pos } :: acc)
    | token ->
        let start_pos, end_pos = byte_positions lexbuf in
        go ({ lexed = Token token; start_pos; end_pos } :: acc)
    | exception Lexer.Lexing_error -> (
        (* sedlex's [_] arm matches without consuming, so the offending code
           point is skipped here, and lexing resumes after it. The report
           points where [package]'s does: at the lexer's position when it
           refused. *)
        let start_pos, end_pos = byte_positions lexbuf in
        let bad = { lexed = Bad; start_pos; end_pos } :: acc in
        match Sedlexing.next lexbuf with
        | Some _ -> go bad
        | None -> List.rev ({ lexed = Token Parser.EOF; start_pos = end_pos; end_pos } :: bad)
        | exception Sedlexing.MalFormed ->
            List.rev ({ lexed = Token Parser.EOF; start_pos = end_pos; end_pos } :: bad))
    | exception Sedlexing.MalFormed ->
        (* Invalid UTF-8 is not a code point [_] can consume, so lexing cannot
           resume: the text ends here. *)
        let start_pos, end_pos = byte_positions lexbuf in
        List.rev
          ({ lexed = Token Parser.EOF; start_pos = end_pos; end_pos }
          :: { lexed = Bad; start_pos; end_pos } :: acc)
  in
  Array.of_list (go [])

(* [boundaries.(i)]: whether a declaration may start at token [i].

   Depth counts `{ }` alone; a `(` or `[` is counted per brace level and
   forgotten at the next `;` of that level. Entries inside parentheses and
   brackets are separated by `,` (lexical.md §6.2), so a `;` reached with a
   `(` or `[` still open at its level means that bracket was never closed.
   Without the reset, one missing `]` would hide every boundary after it. *)
let boundaries tokens =
  let n = Array.length tokens in
  let result = Array.make (n + 1) false in
  let braces = ref 0 and open_ = ref [ 0 ] in
  let top () = List.hd !open_ in
  let set_top k = open_ := k :: List.tl !open_ in
  Array.iteri
    (fun i { lexed; _ } ->
      match lexed with
      | Token (Parser.LPAREN | Parser.LBRACKET) -> set_top (top () + 1)
      | Token (Parser.RPAREN | Parser.RBRACKET) -> set_top (max 0 (top () - 1))
      | Token Parser.LCURLY ->
          incr braces;
          open_ := 0 :: !open_
      | Token Parser.RCURLY ->
          if !braces > 0 then (
            decr braces;
            open_ := List.tl !open_);
          if !braces = 0 && top () = 0 then result.(i + 1) <- true
      | Token Parser.SEMICOLON ->
          set_top 0;
          if !braces = 0 then result.(i + 1) <- true
      | _ -> ())
    tokens;
  result

type segment = Parsed of Nodes.Package.t | Failed of int * Diagnostic.t

(* Parse tokens [start, stop) as one package, with an end of input at [stop].
   On failure, the index of the token being read and its diagnostic. The
   diagnostic points where [package]'s does: at the last token read. *)
let parse_range tokens start stop =
  let last = ref (start - 1) in
  let eof_at = tokens.(stop).start_pos in
  let tokenizer () =
    incr last;
    if !last >= stop then (Parser.EOF, eof_at, eof_at)
    else
      let { lexed; start_pos; end_pos } = tokens.(!last) in
      match lexed with Token token -> (token, start_pos, end_pos) | Bad -> raise Unlexable
  in
  let located message =
    let i = min !last stop in
    let span =
      if i >= stop then (eof_at, eof_at) else (tokens.(i).start_pos, tokens.(i).end_pos)
    in
    Failed (i, Diagnostic.error (Span.of_loc span) message)
  in
  match MenhirLib.Convert.Simplified.traditional2revised Parser.package tokenizer with
  | package -> Parsed package
  | exception Parse_error.Rejected message -> located message
  | exception (Parser.Error _ | Unlexable) -> located "Parse error"

let package_recovering filename input =
  match Sedlexing.Utf8.from_string input with
  | exception Sedlexing.MalFormed -> (
      match package filename input with
      | Error diagnostic ->
          let position =
            { Lexing.pos_fname = filename; pos_lnum = 1; pos_bol = 0; pos_cnum = 0 }
          in
          ( { Nodes.Package.decls = []; defects = []; span = Span.of_loc (position, position) },
            [ diagnostic ] )
      | Ok package -> (package, []))
  | lexbuf ->
      Sedlexing.set_filename lexbuf filename;
      let tokens = lex_all lexbuf in
      let eof = Array.length tokens - 1 in
      let boundary = boundaries tokens in
      let decls = ref [] and defects = ref [] and diagnostics = ref [] in
      let take (p : Nodes.Package.t) =
        decls := List.rev_append p.decls !decls;
        defects := List.rev_append p.defects !defects;
        match Statement_check.check p with
        | Ok () -> ()
        | Error d -> diagnostics := d :: !diagnostics
      in
      (* Takes the longest prefix [start, b'), for a boundary b' <= [b], that
         parses. *)
      let rec salvage start b =
        if b <= start then ()
        else if not boundary.(b) then salvage start (b - 1)
        else
          match parse_range tokens start b with
          | Parsed p -> take p
          | Failed _ -> salvage start (b - 1)
      in
      let rec next_boundary i = if i >= eof || boundary.(i) then i else next_boundary (i + 1) in
      let rec go start =
        if start < eof then
          match parse_range tokens start eof with
          | Parsed p -> take p
          | Failed (e, d) ->
              diagnostics := d :: !diagnostics;
              salvage start (min e eof);
              go (next_boundary (e + 1))
      in
      go 0;
      let package =
        {
          Nodes.Package.decls = List.rev !decls;
          defects = List.rev !defects;
          span = Span.of_loc (tokens.(0).start_pos, tokens.(eof).end_pos);
        }
      in
      (* A salvaged prefix is checked after the failure that prompted it, so
         its diagnostics are recorded later than they are written. *)
      let by_position a b = compare (Diagnostic.position a) (Diagnostic.position b) in
      (package, List.stable_sort by_position (List.rev !diagnostics))
