(** Where a node was written: the positions of its first byte and of the
    byte after its last. Positions are byte offsets, which is what indexing
    the source text needs. *)
type t = { start_ : Lexing.position; end_ : Lexing.position }

(** Menhir's [$loc], which is exactly this pair. *)
val of_loc : Lexing.position * Lexing.position -> t

(** The span covering both, for a node built from parts whose own production
    does not span all of them. *)
val join : t -> t -> t

(** A span standing in for one that was never written. *)
val none : t
