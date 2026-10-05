(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol.

   This module runs one invocation: it parses the command line, loads the
   automaton, and hands the work to the phase asked for -- [Classes] for
   `--dump-terminal-classes`, the recognizer for `--check-tokens`, and
   [Concretize] for the bounded search. *)

let main () =
  let o = Config.parse_options () in
  let { Config.menhir; memory_mb; max_frontier_ratio; jobs; search_limits } =
    Config.settings o
  in
  let grammar_path = Unix.realpath o.Config.grammar in
  let temporary = Search.temporary_directory () in
  (* Most exits below go through [Stdlib.exit], which runs [at_exit] handlers
     but never a [Fun.protect ~finally], so the directory has to be released
     from an [at_exit] handler as well. Forked workers write their results into
     this same directory and exit through it too, hence the owner check: only
     the process that created the directory may remove it. Both entry points
     share one idempotent [cleanup]. *)
  let owner = Unix.getpid () in
  let cleaned = ref false in
  let cleanup () =
    if Unix.getpid () = owner && not !cleaned then begin
      cleaned := true;
      try Search.remove_tree temporary with Sys_error _ | Unix.Unix_error _ -> ()
    end
  in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
      let terminals, aliases = Automaton.parse_tokens grammar_path in
      let automaton_path =
        Automaton.prepare_automaton ~menhir ~grammar:grammar_path
          ~directory:temporary
      in
      let automaton = Automaton.parse_automaton automaton_path terminals aliases in
      let stacks = Stack_pool.create () in
      let engine =
        { Recognizer.automaton; stacks; closure_cache = Hashtbl.create 16_384 }
      in
      if o.Config.dump_classes then Classes.dump automaton;
      if o.Config.check_tokens <> [] then begin
        let frontier =
          List.fold_left (Recognizer.shift engine)
            (Automaton.IntMap.singleton engine.stacks.root.id 1)
            o.Config.check_tokens
        in
        let count = Recognizer.accepted_count engine frontier in
        Output.printf "Accepting derivations: %d\n" count;
        exit 0
      end;
      let max_tokens, timeout, max_witnesses = Option.get search_limits in
      if o.Config.min_tokens > max_tokens then
        invalid_arg "--min-tokens must not exceed --max-tokens";
      let prefix_depth = List.length o.Config.prefix_tokens in
      if prefix_depth > max_tokens then
        invalid_arg
          "--prefix-tokens must not contain more tokens than --max-tokens";
      let initial_frontier =
        List.fold_left (Recognizer.shift engine)
          (Automaton.IntMap.singleton engine.stacks.root.id 1)
          o.Config.prefix_tokens
      in
      if Automaton.IntMap.is_empty initial_frontier then
        invalid_arg "--prefix-tokens is not a valid grammar prefix";
      let initial =
        {
          Search.tokens_rev = List.rev o.Config.prefix_tokens;
          depth = prefix_depth;
          frontier = initial_frontier;
          branched = Recognizer.derivations initial_frontier >= 2;
        }
      in
      Output.printf
        "Search constraints: %d..%d total tokens; %d-token prefix; %s.\n"
        o.Config.min_tokens max_tokens prefix_depth
        (match o.Config.nodes_per_depth with
        | None -> "breadth-first scheduling"
        | Some 1 -> "1 node per depth"
        | Some limit -> Printf.sprintf "%d nodes per depth" limit);
      if o.Config.prefix_tokens <> [] then
        Output.printf "Prefix tokens: %s\n" (String.concat " " o.Config.prefix_tokens);
      Concretize.run ~min_tokens:o.Config.min_tokens
        ~nodes_per_depth:o.Config.nodes_per_depth ~automaton ~engine ~temporary ~memory_mb ~max_frontier_ratio ~jobs
        ~max_tokens ~timeout ~max_witnesses ~initial)

let entry () =
  try main ()
  with
  | Failure message | Invalid_argument message | Sys_error message
  | Unix.Unix_error (_, _, message) ->
      Output.clear_progress ();
      prerr_endline ("error: " ^ message);
      exit 2
