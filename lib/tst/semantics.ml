(* Stage 3 from end to end: the five passes of docs/design/semantics.md §3, run over
   packages [Assembly] has already put together. *)

type result = {
  program : Nodes.Program.t;
  (* Every problem the passes found, in source order (D4). *)
  diagnostics : Diagnostic.t list;
}

(* Every pass, over tables of this check's own. *)
let check (packages : Assembly.package list) =
  let env = Env.create () in
  Collect.run env packages;
  Type_decls.run env;
  Verb_signatures.run env;
  let program = Program.run env in
  (* The analyses over the finished tree (D1). *)
  Read_only.run env program;
  Guests.run env program;
  Moves.run env program;
  Owners.run env program;
  Exits.run env program;
  Expansions.run env program;
  Literal_ranges.run env program;
  Spawns.run env program;
  let diagnostics =
    List.sort_uniq
      (fun a b ->
        match compare (Diagnostic.position a) (Diagnostic.position b) with
        | 0 -> compare a.Diagnostic.message b.Diagnostic.message
        | c -> c)
      !(env.Env.diagnostics)
  in
  { program; diagnostics }

(* The text a build read from [path]: what a span is read back out of. *)
let source packages path = Source.Files.find (Assembly.sources packages) path

