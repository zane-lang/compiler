(* A library's object file with its `!` placeholder turned into a version
   stamp, as fetching does to a release's objects
   (docs/design/separate-compilation.md C9, dependencies.md §6.1). ELF,
   Mach-O and COFF objects are read; each format's module says how its
   symbols name themselves. *)

let is_stamp = Name.is_stamp

(* Whether two stamps are of one package: whether their identity hashes are
   one. *)
let same_package a b = Name.identity a = Name.identity b

(* The object [input] with each symbol renamed by [rename], and how many
   symbols were renamed. *)
let apply ~rename input =
  let format =
    if Elf.is input then Some Elf.rewrite
    else if Macho.is input then Some Macho.rewrite
    else if Coff.is input then Some Coff.rewrite
    else None
  in
  match format with
  | None -> Error "the file is not an object file this compiler rewrites"
  | Some rewrite -> (
      match rewrite ~rename input with
      | result -> Ok result
      | exception Field.Malformed what -> Error ("the object file is malformed: " ^ what))

(* The object [input] with every placeholder in its symbol names replaced by
   [stamp], and how many symbols were renamed. *)
let rewrite ~stamp input =
  if not (Name.is_stamp stamp) then Error (Printf.sprintf "`%s` is not a stamp" stamp)
  else apply ~rename:(Name.placeholder ~stamp) input

(* The object [input] with every reference to the package version stamped
   [from] moved to the version stamped [to_], as remapping does
   (docs/design/separate-compilation.md C11, dependencies.md §15.6). Both
   are versions of one package, so the two stamps share their identity
   hash, and only the version tag changes. Remapping a stamp onto itself
   renames nothing, though the object is still read and checked. *)
let remap ~from ~to_ input =
  if not (Name.is_stamp from) then Error (Printf.sprintf "`%s` is not a stamp" from)
  else if not (Name.is_stamp to_) then Error (Printf.sprintf "`%s` is not a stamp" to_)
  else if not (same_package from to_) then
    Error
      (Printf.sprintf
         "`%s` and `%s` are versions of two packages, since their identity hashes differ; \
          remapping moves references between versions of one package"
         from to_)
  else if String.equal from to_ then apply ~rename:(fun _ -> None) input
  else apply ~rename:(Name.remap ~from ~to_) input
