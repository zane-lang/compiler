(* Stage 3 from end to end: the five passes of docs/design/semantics.md §3, run over
   packages [Assembly] has already put together. *)

type result = {
  program : Nodes.Program.t;
  (* Every problem the passes found, in source order (D4). *)
  diagnostics : Diagnostic.t list;
}

(* Every pass, over tables of this check's own. Each pass fills its group's
   tables and hands on a view of them, and the next pass runs on that view:
   a pass runs only once the passes before it have. *)
let check (packages : Assembly.package list) =
  let env = Env.start () in
  let env = { env with names = Collect.run env (Env.names ()) packages } in
  let env = { env with types = Type_decls.run env (Env.types ()) } in
  let env = { env with verbs = Verb_signatures.run env (Env.verbs ()) } in
  let program = Program.run env (Env.instances ()) in
  (* The analyses over the finished tree (D1). Which blocks run more than
     once is computed here, once, for the two that ask. *)
  let multi = Repeats.compute env program in
  Read_only.run env ~multi program;
  References.run env program;
  Moves.run env program;
  Scopes.run env program;
  Exits.run env program;
  Expansions.run env program;
  Literal_ranges.run env program;
  Spawns.run env ~multi program;
  Borrows.run env program;
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

