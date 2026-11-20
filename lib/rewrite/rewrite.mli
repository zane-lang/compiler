(** The rewriter: an object file with its symbol names changed, without
    building it again (docs/design/separate-compilation.md C9, C11). *)

(** Whether a string is a stamp: a version tag, then `%`, sixteen lowercase
    hexadecimal digits and `%`. *)
val is_stamp : string -> bool

(** Whether two stamps are versions of one package, which holds when their
    identity hashes are equal. *)
val same_package : string -> string -> bool

(** The object with every `!` placeholder replaced by [stamp], and how many
    symbols were renamed. *)
val rewrite : stamp:string -> string -> (string * int, string) result

(** The object with every reference to the version stamped [from] moved to
    the version stamped [to_], and how many symbols were renamed. *)
val remap : from:string -> to_:string -> string -> (string * int, string) result

(** The object with each symbol renamed for which [rename] returns a new
    name, and how many symbols were renamed. This renames a package's C
    objects to the names its module's globals take (docs/design/ffi.md
    F9). *)
val rename : rename:(string -> string option) -> string -> (string * int, string) result

(** [symbol] with every occurrence of [from] spelled [into]. [from] is a
    package's name, which a symbol contains before the symbol's own name and
    in each of the package's types that the symbol names. An occurrence that
    ends a longer name, as [from] `lib$` ends `mylib$`, belongs to another
    package and is kept. *)
val respell : from:string -> into:string -> string -> string
