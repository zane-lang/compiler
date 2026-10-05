(* Stage 3 from end to end: the five passes of docs/design/semantics.md §3, run over
   packages [Assembly] has already put together. *)

type result = {
  program : Nodes.Program.t;
  (* Every problem the passes found, in source order (D4). *)
  diagnostics : Diagnostic.t list;
}

let check (packages : Assembly.package list) =
  Env.reset ();
  Collect.run packages;
  Type_decls.run ();
  Verb_signatures.run ();
  let program = Check.run () in
  (* The analyses over the finished tree (D1). *)
  Read_only.run program;
  Guests.run program;
  Moves.run program;
  Owners.run program;
  Exits.run program;
  Expansions.run program;
  Literal_ranges.run program;
  Spawns.run program;
  let diagnostics =
    List.sort_uniq
      (fun a b ->
        match compare (Diagnostic.position a) (Diagnostic.position b) with
        | 0 -> compare a.Diagnostic.message b.Diagnostic.message
        | c -> c)
      !Env.diagnostics
  in
  { program; diagnostics }

(* The text a build read from [path]: what a span is read back out of. *)
let source packages path = Source.Files.find (Assembly.sources packages) path

(* A diagnostic points into one of the build's files. *)
let render packages (d : Diagnostic.t) = Diagnostic.render_in (Assembly.sources packages) d
