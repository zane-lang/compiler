open Sedlexing
open Parser

let digit      = [%sedlex.regexp? '0'..'9']
let digits     = [%sedlex.regexp? Plus digit]
let int_lit    = [%sedlex.regexp? digits, Star ('\'', digits)]
let float_lit  = [%sedlex.regexp? int_lit, '.', digits]
let nonascii   = [%sedlex.regexp? 192 .. 214 | 216 .. 246 | 248 .. 255]
let ident_char = [%sedlex.regexp? 'a'..'z' | 'A'..'Z' | '_' | nonascii]
let str_char   = [%sedlex.regexp? Compl ('"' | '\\') | '\\', any]

let strip_sep s = String.concat "" (String.split_on_char '\'' s)

let rec token buf =
  match%sedlex buf with
  | Plus (' ' | '\t' | '\r' | '\n') -> token buf
  | "->"                        -> THIN_ARROW
  | "=>"                        -> THICK_ARROW
  | '='                         -> EQUAL
  | '('                         -> LPAREN
  | ')'                         -> RPAREN
  | '{'                         -> LCURLY
  | '}'                         -> RCURLY
  | '['                         -> LBRACKET
  | ']'                         -> RBRACKET
  | ','                         -> COMMA
  | ':'                         -> COLON
  | '!'                         -> EXCL
  | "??"                        -> QSTNQSTN
  | '?'                         -> QSTNMARK
  | '~'                         -> TILDE
  | '+'                         -> PLUS
  | '-'                         -> MINUS
  | '*'                         -> STAR
  | '/'                         -> SLASH
  | '$'                         -> DOLLAR
  | '@'                         -> AT
  | float_lit                   -> FLOAT (Utf8.lexeme buf)
  | int_lit                     -> INT (Utf8.lexeme buf)
  | '"', Star str_char, '"'     ->
      let s = Utf8.lexeme buf in
      STRING (String.sub s 1 (String.length s - 2))
  | "true"                      -> TRUE
  | "false"                     -> FALSE
  | "this"                      -> THIS
  | "abort"                     -> ABORT
  | "return"                    -> RETURN
  | "resolve"                   -> RESOLVE
  | Plus ident_char             -> IDENT (Utf8.lexeme buf)
  | eof                         -> EOF
  | _                           -> ERROR
