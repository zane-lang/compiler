(* The bounded witness search behind `ambiguity search`. It reports the
   witnesses it found, or how it ended without one. *)

let run ~min_tokens ~nodes_per_depth ~automaton ~engine ~temporary ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens ~timeout
    ~max_witnesses ~initial =
  let memory_limits =
    Config.derive_memory_limits ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens
  in
  Output.printf
    "Memory budget: %d MiB total across %d worker(s); workers compact at %.0f MiB and stop admitting frontiers at %.0f MiB each (10%% reserved); per-worker limits are %d queued frontiers and %d retained dedup frontiers (ratio %g).\n"
    memory_mb jobs
    (memory_limits.soft_heap_bytes /. 1024. /. 1024.)
    (memory_limits.hard_heap_bytes /. 1024. /. 1024.)
    memory_limits.max_queue memory_limits.max_frontiers
    max_frontier_ratio;
  let conflicts = Recognizer.conflict_states automaton in
  let conflict_distance = Recognizer.reverse_distances automaton conflicts in
  let accept_targets =
    Array.map
      (fun state -> Automaton.StringSet.mem "#" state.Automaton.accepts)
      automaton.states
  in
  let accept_distance = Recognizer.reverse_distances automaton accept_targets in
  let outcome, conflict_seeds =
    Search.parallel_unified_search engine initial ~jobs ~max_tokens
      ~min_tokens ~nodes_per_depth ~timeout
      ~max_frontiers:memory_limits.max_frontiers
      ~max_queue:memory_limits.max_queue ~max_witnesses
      ~soft_heap_bytes:memory_limits.soft_heap_bytes
      ~hard_heap_bytes:memory_limits.hard_heap_bytes conflict_distance
      accept_distance temporary
  in
  (* Why the search ended decides what its silence is worth: a run that
     exhausted the space within the token bound has checked every sentence
     that short, while one that hit a limit has merely stopped looking, so
     every run says how it ended. *)
  let termination =
    match outcome.stopped with
    | Some reason -> reason
    | None -> "the search space within the token bound was exhausted"
  in
  match outcome.witnesses with
  | [] ->
      Output.printf
        "Search ended at depth %d because %s; no complete ambiguity was found in %d explored frontiers (%d unique).\n"
        outcome.deepest termination outcome.explored outcome.unique;
      Output.printf "This is a bounded result, not a proof of unambiguity.\n";
      exit 0
  | witnesses ->
      Output.printf "Found %d complete ambiguity %s.\n"
        (List.length witnesses)
        (if List.length witnesses = 1 then "family" else "families");
      List.iteri
        (fun index (profile, witness) ->
          Output.printf "\n%d. Tokens (%d): %s\n   Source: %s\n"
            (index + 1) (List.length witness) (String.concat " " witness)
            (Search.render automaton witness);
          Output.printf "   Conflict origins: %s\n"
            (profile
            |> List.map (fun (state, token) ->
                   Printf.sprintf "state %d on %s" state token)
            |> String.concat ", "))
        witnesses;
      Output.printf "\n";
      Output.printf "Explored %d frontiers (%d unique); %d conflict seeds.\n"
        outcome.explored outcome.unique conflict_seeds;
      Output.printf "Search ended at depth %d because %s.\n"
        outcome.deepest termination;
      exit 0
