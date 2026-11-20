(* One error or warning that a stage reports about the source it was given.

   A report has a span rather than a single position, because the faulty source
   usually covers some text -- a token, an alias, a whole argument -- and the
   renderer draws a caret under all of it. A report about a point, such as the
   place a statement should have ended, uses an empty span. *)

module Severity = struct
  (* An error refuses the input. A warning lets the build go on, such as a
     warning the C compiler gives about a package's own C code
     (docs/design/ffi.md F2). *)
  type t = Error | Warning

  let label = function Error -> "Error" | Warning -> "Warning"
end

(* The location a report is about. Most reports are about text, and have a span
   to put a caret under. A few are about a directory -- missing, unlistable,
   empty, or named the same as another -- or about a file that could not be
   read, and have no text to point into. *)
module Location = struct
  (* [Invocation] is the command the compiler was run with. A report about
     the command's flags uses it, since flags point into no file. *)
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
