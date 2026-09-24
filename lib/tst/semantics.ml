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
  let diagnostics =
    List.sort_uniq
      (fun a b ->
        match compare (position a) (position b) with
        | 0 -> compare a.Diagnostic.message b.Diagnostic.message
        | c -> c)
      !Env.diagnostics
  in
  { program; diagnostics }

(* A diagnostic points into one of the build's files; this finds the text it
   points into, which is what the renderer draws the caret under. *)
let render (packages : Assembly.package list) (d : Diagnostic.t) =
  let path, _ = position d in
  let source =
    List.find_map
      (fun (p : Assembly.package) ->
        List.find_map
          (fun (f : Assembly.file) -> if String.equal f.path path then Some f.source else None)
          p.files)
      packages
  in
  Diagnostic.render ~source:(Option.value ~default:"" source) d
