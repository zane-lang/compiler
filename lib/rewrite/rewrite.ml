(* A library's object file with its `!` placeholder turned into a version
   stamp, as fetching does to a release's objects
   (docs/design/separate-compilation.md C9, dependencies.md §6.1). *)

let is_stamp = Name.is_stamp

(* The object [input] with every placeholder in its symbol names replaced by
   [stamp], and how many symbols were renamed. *)
let rewrite ~stamp input =
  if not (Name.is_stamp stamp) then
    Error (Printf.sprintf "`%s` is not a stamp: a version tag, `%%`, 16 hexadecimal digits and `%%`" stamp)
  else if Elf.is (Bytes.unsafe_of_string input) then
    match Elf.rewrite ~stamp input with
    | result -> Ok result
    | exception Elf.Malformed what -> Error ("the object file is malformed: " ^ what)
  else Error "the file is not an object file this compiler rewrites"
