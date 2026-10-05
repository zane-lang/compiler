(* The text of every file a build read, by the path its spans carry: what a
   diagnostic's caret is drawn under, and what a span is read back out of. *)

type t = (string * string) list

let find (files : t) path = List.assoc_opt path files
