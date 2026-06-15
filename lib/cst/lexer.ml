open Sedlexing
open Parser

let digit      = [%sedlex.regexp? '0'..'9']
let digits     = [%sedlex.regexp? Plus digit]
let int_lit    = [%sedlex.regexp? digits, Star ('\'', digits)]
let float_lit  = [%sedlex.regexp? int_lit, '.', digits]
let str_char   = [%sedlex.regexp? Compl ('"' | '\\') | '\\', any]

(* Any character valid inside an identifier (after the first) *)
let ident_char = [%sedlex.regexp? alphabetic | '0'..'9' | '_']

(* Starts with a Unicode lowercase letter, or '_' then one *)
let lower_ident = [%sedlex.regexp? (lowercase | '_', lowercase), Star ident_char]
(* Starts with a Unicode uppercase letter, or '_' then one *)
let upper_ident = [%sedlex.regexp? (uppercase | '_', uppercase), Star ident_char]

let rec token buf =
  match%sedlex buf with
  | Plus (' ' | '\t' | '\r' | '\n') -> token buf
  | "=>"                        -> THICK_ARROW
  | "=="                        -> EQEQ
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
  | '@'                         -> AT
  | float_lit                   -> FLOAT (Utf8.lexeme buf)
  | int_lit                     -> INT (Utf8.lexeme buf)
  | '"', Star str_char, '"'     ->
      let s = Utf8.lexeme buf in
      STRING (String.sub s 1 (String.length s - 2))
  | "type"                      -> LTYPE
  | "alias"                     -> ALIAS
  | "Type"                      -> UTYPE
  | "Number"                    -> NUMBER
  | "class"                     -> CLASS
  | "struct"                    -> STRUCT
  | "variant"                   -> VARIANT
  | "tuple"                     -> TUPLE
  | "enum"                      -> ENUM
  | "if"                        -> IF
  | "elif"                      -> ELIF
  | "else"                      -> ELSE
  (* | "loop"                      -> LOOP *)
  | "true"                      -> TRUE
  | "false"                     -> FALSE
  | "this"                      -> THIS
  | "mut"                       -> MUT
  | "abort"                     -> ABORT
  | "return"                    -> RETURN
  | "resolve"                   -> RESOLVE
  | lower_ident                 -> LIDENT (Utf8.lexeme buf)
  | upper_ident                 -> UIDENT (Utf8.lexeme buf)
  | eof                         -> EOF
  | _                           -> ERROR
