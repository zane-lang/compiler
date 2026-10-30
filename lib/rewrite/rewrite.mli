(** The rewriter: an object file with its symbol names changed, without
    building it again (docs/design/separate-compilation.md C9, C11). *)

(** Whether a string is a stamp: a version tag, then `%`, sixteen lowercase
    hexadecimal digits and `%`. *)
val is_stamp : string -> bool

(** Whether two stamps are versions of one package: their identity hashes
    agree. *)
val same_package : string -> string -> bool

(** The object with every `!` placeholder replaced by [stamp], and how many
    symbols were renamed. *)
val rewrite : stamp:string -> string -> (string * int, string) result

(** The object with every reference to the version stamped [from] moved to
    the one stamped [to_], and how many symbols were renamed. *)
val remap : from:string -> to_:string -> string -> (string * int, string) result

(** The object with each symbol [rename] gives a new name renamed, and how
    many were: a package's C objects renamed with the names its module's
    globals take (docs/design/ffi.md F9). *)
val rename : rename:(string -> string option) -> string -> (string * int, string) result

(** [symbol] with every occurrence of [from] spelled [into]: a package's
    name, which a symbol holds before its own name and in each of the
    package's types it names. An occurrence that ends a longer name, as
    [from] `lib$` ends `mylib$`, is another package's, and is kept. *)
val respell : from:string -> into:string -> string -> string
