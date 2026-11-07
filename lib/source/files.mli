(** The text of every file a build read, by the path its spans carry: what a
    diagnostic's caret is drawn under, and what a span is read back out of. *)
type t = (string * string) list

val find : t -> string -> string option

(** [entry]'s path in [dir], joined with `/`, which Windows reads as it
    reads `\`, so a file's path is spelled the same on every system: in
    reports, spans and every view of the program. An empty [dir] is the
    current directory, as for [Filename.concat]: [entry] alone. *)
val in_directory : string -> string -> string
