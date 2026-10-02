(* What the rewriter does to one symbol name (docs/design/separate-compilation.md
   C5, C9): every `!` becomes the stamp. No other `!` can stand in a symbol,
   since no operator is spelled with one and a mutating call's `!` is not
   part of the verb's name. *)

let rewrite ~stamp name =
  if String.contains name '!' then
    Some (String.concat stamp (String.split_on_char '!' name))
  else None

(* A stamp as fetching computes it (dependencies.md §6.1): the version tag,
   `%`, the identity hash's 16 lowercase hexadecimal digits, and `%`. The tag
   is path-safe (§7), so it holds no `%`, which keeps the boundary after it
   unambiguous, and no `@`, which a linker reads as a symbol version. The
   characters allowed here are the ones every tag scheme in use needs. *)
let is_stamp stamp =
  let n = String.length stamp in
  n > 18
  && stamp.[n - 1] = '%'
  && stamp.[n - 18] = '%'
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub stamp (n - 17) 16)
  && String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '-' -> true | _ -> false)
       (String.sub stamp 0 (n - 18))
