include Report

let render ~source diagnostic = Render.render ~source diagnostic

(* A report rendered against the files a build read. *)
let render_in (files : Source.Files.t) diagnostic =
  let path, _ = position diagnostic in
  render ~source:(Option.value ~default:"" (Source.Files.find files path)) diagnostic

(* A broken invariant: something an earlier stage guarantees did not hold.
   It is the compiler's fault, never the program's, so it is raised rather
   than reported, and the binary that catches it says so (exit status 3). *)
exception Internal of { span : Source.Span.t option; message : string }

let bug ?span message = raise (Internal { span; message })

(* An internal error for a person: where it happened, when it is known, and
   that it is a bug to report. *)
let render_internal ?span message =
  let where =
    match span with
    | None -> ""
    | Some (s : Source.Span.t) ->
        let p = s.Source.Span.start_ in
        Printf.sprintf "File \"%s\", line %d, characters %d:\n" p.Lexing.pos_fname
          p.Lexing.pos_lnum
          (p.Lexing.pos_cnum - p.Lexing.pos_bol + 1)
  in
  Printf.sprintf
    "%sinternal compiler error: %s\n\
     This is a bug in the compiler, not in the program. Please report it at\n\
     https://github.com/zane-lang/compiler/issues\n"
    where message
