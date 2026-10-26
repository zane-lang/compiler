(* A string literal's structure (lexical.md §7.1). The lexer keeps a
   literal's text as it was written, between its quotes; this scans it once,
   left to right, for the three forms the language defines inside one: a
   backslash before a quote is the quote, a backslash before a backslash is
   that backslash, and `\%name` is an interpolation site. Any
   other backslash stays in the text with the character after it, for the
   literal's consumer to read (types.md §2.7). *)

open Sedlexing

type part =
  (* Literal text, with its escaped quotes and backslashes already read. *)
  | Text of string
  (* `\%name`: the name, and the byte offset of its first character in the
     written text. *)
  | Name of { text : string; offset : int }
  (* A `\%` that no value identifier follows, and where it starts: a type
     identifier or a keyword follows it, or neither does. *)
  | Bad_name of { found : found; offset : int }

and found = Type_identifier of string | Keyword of string | Nothing

(* The identifier at byte [start] of [s], as the lexer's LIDENT and UIDENT
   rules read one (lexical.md §4): the longest one, so `\%name.txt` names
   `name`, and `.txt` is text. The bytes are read from [s] where they are,
   as far as the identifier goes. *)
let identifier s start =
  let i = ref start in
  let next () =
    if !i < String.length s then begin
      let c = s.[!i] in
      incr i;
      Some c
    end
    else None
  in
  let buf = Utf8.from_gen next in
  match%sedlex buf with
  | (lowercase | ("_", lowercase)), Star (alphabetic | '0' .. '9') -> `Value (Utf8.lexeme buf)
  | (uppercase | ("_", uppercase)), Star (alphabetic | '0' .. '9') -> `Type (Utf8.lexeme buf)
  | _ -> `None

let identifier s start = try identifier s start with MalFormed -> `None

let scan written =
  let n = String.length written in
  let text = Buffer.create n in
  let parts = ref [] in
  let flush () =
    if Buffer.length text > 0 then begin
      parts := Text (Buffer.contents text) :: !parts;
      Buffer.clear text
    end
  in
  let rec go i =
    if i < n then
      if written.[i] = '\\' && i + 1 < n then
        match written.[i + 1] with
        | ('"' | '\\') as c ->
            Buffer.add_char text c;
            go (i + 2)
        | '%' -> (
            flush ();
            let start = i + 2 in
            match identifier written start with
            | `Value name when Lexer.is_lower_identifier name ->
                parts := Name { text = name; offset = start } :: !parts;
                go (start + String.length name)
            | `Value name ->
                parts := Bad_name { found = Keyword name; offset = i } :: !parts;
                go (start + String.length name)
            | `Type name ->
                parts := Bad_name { found = Type_identifier name; offset = i } :: !parts;
                go (start + String.length name)
            | `None ->
                parts := Bad_name { found = Nothing; offset = i } :: !parts;
                go start)
        | _ ->
            Buffer.add_char text '\\';
            go (i + 1)
      else begin
        Buffer.add_char text written.[i];
        go (i + 1)
      end
  in
  go 0;
  flush ();
  List.rev !parts
