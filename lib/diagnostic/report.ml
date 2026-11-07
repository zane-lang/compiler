(* One thing a stage has to say about the source it was given.

   A span rather than a single position, because what is wrong usually covers
   some text -- a token, an alias, a whole argument -- and the renderer draws a
   caret under all of it. A report about a point, such as the place a statement
   should have ended, uses an empty span. *)

module Severity = struct
  (* A refusal, or a warning a build goes on after: what the C compiler
     says of a package's own C code (docs/design/ffi.md F2). *)
  type t = Error | Warning

  let label = function Error -> "Error" | Warning -> "Warning"
end

(* What a report is about. Most are about text, and have a span to put a
   caret under. A few are about a directory -- missing, unlistable, empty, or
   named the same as another -- or about a file that could not be read, and
   have no text to point into. *)
module Location = struct
  (* [Invocation] is the command the compiler was run with: a report about
     its flags, which point into no file. *)
  type t = Span of Source.Span.t | File of string | Directory of string | Invocation

  (* The path, and the byte offset into it, that reports are sorted by. *)
  let position = function
    | Span s ->
        let p = s.Source.Span.start_ in
        (p.Lexing.pos_fname, p.Lexing.pos_cnum)
    | File path | Directory path -> (path, -1)
    | Invocation -> ("", -1)
end

type t = {
  severity : Severity.t;
  location : Location.t;
  message : string;
}

let error span message = { severity = Severity.Error; location = Location.Span span; message }
let in_file path message = { severity = Severity.Error; location = Location.File path; message }

(* [d] as a warning, which refuses nothing. *)
let as_warning d = { d with severity = Severity.Warning }

let in_directory dir message =
  { severity = Severity.Error; location = Location.Directory dir; message }

let about_invocation message =
  { severity = Severity.Error; location = Location.Invocation; message }

let position d = Location.position d.location
