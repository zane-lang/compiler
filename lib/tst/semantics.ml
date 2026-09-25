(* Stage 3 from end to end: the five passes of docs/semantics.md §3, run over
   packages [Assembly] has already put together. *)

type result = {
  program : Nodes.Program.t;
  (* Every problem the passes found, in source order (D4). *)
  diagnostics : Diagnostic.t list;
}

let position (d : Diagnostic.t) =
  let p = d.Diagnostic.span.Source.Span.start_ in
  (p.Lexing.pos_fname, p.Lexing.pos_cnum)

let check (packages : Assembly.package list) =
  Env.reset ();
  Collect.run packages;
  Types.run ();
  Signatures.run ();
  let program = Check.run () in
  (* The analyses over the finished tree (D1). *)
  Read_only.run program;
  Guests.run program;
  let diagnostics =
    List.sort_uniq
      (fun a b ->
        match compare (position a) (position b) with
        | 0 -> compare a.Diagnostic.message b.Diagnostic.message
        | c -> c)
      !Env.diagnostics
  in
  { program; diagnostics }

(* The text a build read from [path]: what a diagnostic's caret is drawn
   under, and what a span is read back out of. *)
let source (packages : Assembly.package list) path =
  List.find_map
    (fun (p : Assembly.package) ->
      List.find_map
        (fun (f : Assembly.file) -> if String.equal f.path path then Some f.source else None)
        p.files)
    packages

(* A diagnostic points into one of the build's files. *)
let render packages (d : Diagnostic.t) =
  let path, _ = position d in
  Diagnostic.render ~source:(Option.value ~default:"" (source packages path)) d
