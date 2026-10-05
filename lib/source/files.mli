(** The text of every file a build read, by the path its spans carry: what a
    diagnostic's caret is drawn under, and what a span is read back out of. *)
type t = (string * string) list

val find : t -> string -> string option
