open Sedlexing
open Parser

(* Raised on a character that starts no valid token. Position is read from the
   lexbuf by the caller, the same way a [Parser.Error] is located. *)
exception Lexing_error

let digit      = [%sedlex.regexp? '0'..'9']
let digits     = [%sedlex.regexp? Plus digit]
(* The two numeric literals of lexical.md §7: an integer literal is digits,
   and a decimal literal is digits, a `.` and digits. The spelling alone picks
   which, so `3.0` is a decimal literal whatever its value, and neither `3.`
   nor `.5` is a literal at all. A `'` between digits before the `.`
   separates groups of them, which the spec does not have
   (docs/spec-divergences.md); the digits after it take none. *)
let int_lit    = [%sedlex.regexp? digits, Star ('\'', digits)]
let decimal_lit = [%sedlex.regexp? int_lit, '.', digits]
let str_char   = [%sedlex.regexp? Compl ('"' | '\\') | '\\', any]
let line_char  = [%sedlex.regexp? Compl ('\n' | '\r')]

(* Any character valid inside an identifier (after the first) *)
let ident_char = [%sedlex.regexp? alphabetic | '0'..'9' | '_']

(* Starts with a Unicode lowercase letter, or '_' then one *)
let lower_ident = [%sedlex.regexp? (lowercase | '_', lowercase), Star ident_char]
(* Starts with a Unicode uppercase letter, or '_' then one *)
let upper_ident = [%sedlex.regexp? (uppercase | '_', uppercase), Star ident_char]

let rec token buf =
  match%sedlex buf with
  | Plus (' ' | '\t' | '\r' | '\n') -> token buf
  | "///", Star line_char            -> token buf
  | "//", Star line_char             -> token buf
  | "=>"                        -> THICK_ARROW
  | "=="                        -> EQEQ
  | "~="                        -> NOTEQ
  | "<="                        -> LESSEQ
  | ">="                        -> MOREEQ
  | '<'                         -> LESS
  | '>'                         -> MORE
  | '='                         -> EQUAL
  | '('                         -> LPAREN
  | ')'                         -> RPAREN
  | '{'                         -> LCURLY
  | '}'                         -> RCURLY
  | '['                         -> LBRACKET
  | ']'                         -> RBRACKET
  | ','                         -> COMMA
  | '.'                         -> DOT
  | ':'                         -> COLON
  | ';'                         -> SEMICOLON
  | '!'                         -> EXCL
  | "??"                        -> QSTNQSTN
  | '?'                         -> QSTNMARK
  | '~'                         -> TILDE
  | '+'                         -> PLUS
  | '-'                         -> MINUS
  | '*'                         -> STAR
  | '/'                         -> SLASH
  | '$'                         -> DOLLAR
  | '#'                         -> HASH
  | '&'                         -> AMPERSAND
  | '@'                         -> AT

  (* The loose forms of operators.md §3.1. Each is a single token, so the `'`
     must touch its operator: `a ' * b` does not lex. The three spellings the
     spec calls illegal are illegal here for want of a token to spell them --
     there is no `''`, no `'~` and no `'|` -- so `a ''* b`, `'~a` and `a '| f()`
     all stop at the lexer rather than needing a rule of their own.

     A `'` between digits stays the separator of an integer literal: the
     separator wants digits on both sides, and none of these does. *)
  | "'=="                       -> LOOSE_EQEQ
  | "'~="                       -> LOOSE_NOTEQ
  | "'<="                       -> LOOSE_LESSEQ
  | "'>="                       -> LOOSE_MOREEQ
  | "'<"                        -> LOOSE_LESS
  | "'>"                        -> LOOSE_MORE
  | "'+"                        -> LOOSE_PLUS
  | "'-"                        -> LOOSE_MINUS
  | "'*"                        -> LOOSE_STAR
  | "'/"                        -> LOOSE_SLASH
  | decimal_lit                 -> DECIMAL (Utf8.lexeme buf)
  | int_lit                     -> INT (Utf8.lexeme buf)
  | '"', Star str_char, '"'     ->
      let s = Utf8.lexeme buf in
      STRING (String.sub s 1 (String.length s - 2))
  | "type"                      -> LTYPE
  | "alias"                     -> ALIAS
  | "Type"                      -> UTYPE
  | "struct"                    -> STRUCT
  | "variant"                   -> VARIANT
  | "enum"                      -> ENUM
  | "package"                   -> PACKAGE
  | "import"                    -> IMPORT
  | "as"                        -> AS
  | "implicit"                  -> IMPLICIT
  | "init"                      -> INIT
  | "match"                     -> MATCH
  | "spawn"                     -> SPAWN
  | "true"                      -> TRUE
  | "false"                     -> FALSE
  | "this"                      -> THIS
  | "mut"                       -> MUT
  | "abort"                     -> ABORT
  | "return"                    -> RETURN
  | "resolve"                   -> RESOLVE
  | lower_ident                  -> LIDENT (Utf8.lexeme buf)
  | upper_ident                  -> UIDENT (Utf8.lexeme buf)
  | eof                          -> EOF
  | _                            -> raise Lexing_error
