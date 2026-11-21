(* Stage 3 from end to end: the five passes of docs/design/semantics.md §3, run over
   packages [Assembly] has already put together. *)

type result = {
  program : Nodes.Program.t;
  (* Every problem the passes found, in source order (D4). *)
  diagnostics : Diagnostic.t list;
  (* The names the check resolved, when [record] asked it to record them
     (docs/design/language-server.md). *)
  index : Index.t Lazy.t;
}

(* Every pass, over this check's own tables. Each pass fills its group's
   tables and hands on a view of them, and the next pass runs on that view,
   so a pass runs only after the passes before it. *)
(* [interfaces] gives the declarations and definitions of each package's C
   code, by package identity (docs/design/ffi.md F6); a package missing from
   [interfaces] has no C. With [record], the check records each name it
   resolves, and what it finds at [placeholder], in a recorder of its own. *)
let check ?(interfaces = []) ?(record = false) ?placeholder (packages : Assembly.package list) =
  let env = Env.start ~uses:(Uses.create ?placeholder record) () in
  List.iter (fun (id, i) -> Hashtbl.replace env.Env.interfaces id i) interfaces;
  let env = { env with names = Collect.run env (Env.names ()) packages } in
  let env = { env with types = Type_decls.run env (Env.types ()) } in
  let env = { env with verbs = Verb_signatures.run env (Env.verbs ()) } in
  let program = Program.run env (Env.instances ()) in
  (* The analyses over the finished tree (D1). The blocks that run more than
     once are computed here, once, for the two analyses that need them. *)
  let multi = Repeats.compute env program in
  Read_only.run env ~multi program;
  References.run env program;
  Moves.run env program;
  Scopes.run env program;
  Exits.run env program;
  Expansions.run env program;
  Literal_ranges.run env program;
  Spawns.run env ~multi program;
  Pool_elements.run env program;
  Borrows.run env program;
  let diagnostics =
    List.sort_uniq
      (fun a b ->
        match compare (Diagnostic.position a) (Diagnostic.position b) with
        | 0 -> compare a.Diagnostic.message b.Diagnostic.message
        | c -> c)
      !(env.Env.diagnostics)
  in
  { program; diagnostics; index = lazy (Index.build env env.Env.uses) }

(* The text a build read from [path], which a span is read back out of. *)
let source packages path = Source.Files.find (Assembly.sources packages) path

