open Sedlexing
open Parser  (* use Parser.token instead of defining our own *)

let rec token buf =
  match%sedlex buf with
  | '+' -> PLUS
  | '-' -> MINUS
  | '*' -> MUL
  | '/' -> DIV
  | '(' -> LPAREN
  | ')' -> RPAREN
  | Plus ('0'..'9') -> INT (int_of_string (Utf8.lexeme buf))
  | Plus (' ' | '\t' | '\n' | '\r') -> token buf
  | eof -> EOF
  | _ -> failwith ("Unexpected character: " ^ Utf8.lexeme buf)
