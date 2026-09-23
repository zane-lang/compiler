(* One thing a stage has to say about the source it was given.

   A span rather than a single position, because what is wrong usually covers
   some text -- a token, an alias, a whole argument -- and the renderer draws a
   caret under all of it. A report about a point, such as the place a statement
   should have ended, uses an empty span. *)

module Severity = struct
  (* Only refusal, today: nothing yet reports anything a program may go on
     with. *)
  type t = Error

  let label = function Error -> "Error"
end

type t = {
  severity : Severity.t;
  span : Source.Span.t;
  message : string;
}

let error span message = { severity = Severity.Error; span; message }
