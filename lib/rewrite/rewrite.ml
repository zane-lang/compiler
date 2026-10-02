(* A library's object file with its `!` placeholder turned into a version
   stamp, as fetching does to a release's objects
   (docs/design/separate-compilation.md C9, dependencies.md §6.1). ELF,
   Mach-O and COFF objects are read; each format's module says how its
   symbols name themselves. *)

let is_stamp = Name.is_stamp

(* The object [input] with every placeholder in its symbol names replaced by
   [stamp], and how many symbols were renamed. *)
let rewrite ~stamp input =
  let format =
    if Elf.is input then Some Elf.rewrite
    else if Macho.is input then Some Macho.rewrite
    else if Coff.is input then Some Coff.rewrite
    else None
  in
  if not (Name.is_stamp stamp) then Error (Printf.sprintf "`%s` is not a stamp" stamp)
  else
    match format with
    | None -> Error "the file is not an object file this compiler rewrites"
    | Some rewrite -> (
        match rewrite ~stamp input with
        | result -> Ok result
        | exception Field.Malformed what -> Error ("the object file is malformed: " ^ what))
