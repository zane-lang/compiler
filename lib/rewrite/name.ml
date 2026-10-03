(* What the rewriter does to one symbol name (docs/design/separate-compilation.md
   C5, C9): every `!` becomes the stamp. No other `!` can stand in a symbol,
   since no operator is spelled with one and a mutating call's `!` is not
   part of the verb's name. *)

let placeholder ~stamp name =
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

let is_tag_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '-' -> true
  | _ -> false

(* What remapping does to one symbol name (C11, dependencies.md §15.6):
   every stamp [from] becomes [to_]. A stamp starts a package's name, so one
   counts only where no tag character comes before it, or after nothing but
   the `_` Mach-O puts before every name; `v1.0%...%` inside
   `xv1.0%...%` is part of another tag. *)
let remap ~from ~to_ name =
  let n = String.length name and k = String.length from in
  let buffer = Buffer.create (n + 16) in
  let changed = ref false in
  let rec go i =
    if i > n - k then Buffer.add_string buffer (String.sub name i (n - i))
    else if
      String.sub name i k = from
      && (i = 0 || (i = 1 && name.[0] = '_') || not (is_tag_char name.[i - 1]))
    then begin
      Buffer.add_string buffer to_;
      changed := true;
      go (i + k)
    end
    else begin
      Buffer.add_char buffer name.[i];
      go (i + 1)
    end
  in
  go 0;
  if !changed then Some (Buffer.contents buffer) else None

(* The identity hash a stamp carries, `%` and all. *)
let identity stamp = String.sub stamp (String.length stamp - 18) 18
