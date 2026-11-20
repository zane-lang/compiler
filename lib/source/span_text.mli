(** Reading a span back out of the source it points at: the shared rendering
    that each stage's span dump uses to write its lines. *)

(** A printer: the text spans index into, and the lines written so far. *)
type t

val create : string -> t
val contents : t -> string

(** The same printer, reading spans out of another text: for a tree whose
    nodes come from more than one file. *)
val with_source : t -> string -> t

(** A line [depth] levels deep: the node's [kind], then the text its span
    covers, squeezed onto one line and elided in the middle when long, or
    `<INVALID SPAN>` when the span points outside the text. *)
val line : t -> int -> string -> Span.t -> unit

(** A line with no span, for a grouping that has no text in the source. *)
val heading : t -> int -> string -> unit
