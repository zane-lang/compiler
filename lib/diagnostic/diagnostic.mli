(** What a stage reports when it refuses its input, how it is rendered for a
    person, and the internal error a broken invariant raises. *)

include module type of struct
  include Report
end

(** A report as a person reads it at a terminal, against [source], the text
    of the file it points into. *)
val render : source:string -> t -> string

(** A report rendered against the files a build read. *)
val render_in : Source.Files.t -> t -> string

(** A broken invariant: something an earlier stage guarantees did not hold.
    The compiler's fault, never the program's. *)
exception Internal of { span : Source.Span.t option; message : string }

(** Raises [Internal]. *)
val bug : ?span:Source.Span.t -> string -> 'a

(** An internal error as a person reads it, with a request to report it. *)
val render_internal : ?span:Source.Span.t -> string -> string
