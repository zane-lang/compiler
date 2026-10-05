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

(* What a report is about. Most are about text, and have a span to put a
   caret under. A few are about a directory -- missing, unlistable, empty, or
   named the same as another -- or about a file that could not be read, and
   have no text to point into. *)
module Location = struct
  type t = Span of Source.Span.t | File of string | Directory of string

  (* The path, and the byte offset into it, that reports are sorted by. *)
  let position = function
    | Span s ->
        let p = s.Source.Span.start_ in
        (p.Lexing.pos_fname, p.Lexing.pos_cnum)
    | File path | Directory path -> (path, -1)
end

type t = {
  severity : Severity.t;
  location : Location.t;
  message : string;
}

let error span message = { severity = Severity.Error; location = Location.Span span; message }
let in_file path message = { severity = Severity.Error; location = Location.File path; message }

let in_directory dir message =
  { severity = Severity.Error; location = Location.Directory dir; message }

let position d = Location.position d.location
