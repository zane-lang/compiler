(* The bounded concretization search: a plain `ambiguity search`, or the
   last step of a proof whose abstract candidate the recognizer could not
   settle. It reports the witnesses it found, or how it ended without one. *)

open Output
open Automaton
open Recognizer
open Prover
open Search
open Config

let run ~automaton ~engine ~temporary ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens ~timeout
    ~max_witnesses ~initial ~retirements ~confirmed =
  (* Only the concretization search runs workers, and only the code below
     reaches it: a proof that finished on its own never needs the
     worker-divided limits, and deriving them here keeps a proof-only
     verdict from depending on AMBIGUITY_JOBS at all - including through
     the error this derivation raises when the per-worker share is too
     small to hold a single queue entry. *)
  let memory_limits =
    derive_memory_limits ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens
  in
  printf
    "Memory budget: %d MiB total across %d worker(s); workers compact at %.0f MiB and stop admitting frontiers at %.0f MiB each (10%% reserved); per-worker limits are %d queued frontiers and %d retained dedup frontiers (ratio %g).\n"
    memory_mb jobs
    (memory_limits.soft_heap_bytes /. 1024. /. 1024.)
    (memory_limits.hard_heap_bytes /. 1024. /. 1024.)
    memory_limits.max_queue memory_limits.max_frontiers
    max_frontier_ratio;
  let conflicts = conflict_states automaton in
  let conflict_distance = reverse_distances automaton conflicts in
  let accept_targets =
    Array.map
      (fun state -> StringSet.mem "#" state.accepts)
      automaton.states
  in
  let accept_distance = reverse_distances automaton accept_targets in
  let outcome, conflict_seeds =
    parallel_unified_search engine initial ~jobs ~max_tokens
      ~min_tokens:!min_tokens ~nodes_per_depth:!nodes_per_depth ~timeout
      ~max_frontiers:memory_limits.max_frontiers
      ~max_queue:memory_limits.max_queue ~max_witnesses
      ~soft_heap_bytes:memory_limits.soft_heap_bytes
      ~hard_heap_bytes:memory_limits.hard_heap_bytes conflict_distance
      accept_distance temporary
  in
  (* Why the search ended decides what its silence is worth: a run that
     exhausted the space within the token bound has checked every sentence
     that short, while one that hit a limit has merely stopped looking.
     Both used to print "no ambiguity found", and only the second named a
     reason - so the conclusive case was the one identifiable by the
     absence of an explanation. Every run says how it ended now. *)
  let termination =
    match outcome.stopped with
    | Some reason -> reason
    | None -> "the search space within the token bound was exhausted"
  in
  match outcome.witnesses with
  | [] ->
      printf
        "Search ended at depth %d because %s; no complete ambiguity was found in %d explored frontiers (%d unique).\n"
        outcome.deepest termination outcome.explored outcome.unique;
      if !prove_level > 0 then begin
        (* A retiring run reaches here having closed the abstract phase
           everywhere it was still looking, so "the candidate could not be
           concretized" would describe a candidate it does not have. What
           is left open is exactly the retired list, and saying so is the
           difference between a verdict a reader can act on and one that
           sends them to raise --prove for no reason. *)
        (match !confirmed with
         | Some tokens ->
             (* The search did not reach it, but nothing about the finding
                depends on the search: the recognizer parsed this sentence
                twice. The bound is what is missing, so the verdict names
                it rather than the grammar. *)
             printf
               "AMBIGUOUS: the recognizer found two derivations of %s \
                (%s), which the bounded search did not reach within %d \
                tokens, so no witness family is rendered. Raise the token \
                bound to render it.\n"
               (String.concat " " tokens) (render automaton tokens)
               max_tokens;
             exit ambiguous_status
         | None -> ());
        (if !retirements <> [] then
           printf
             "NOT PROVEN: %d retired site(s) were stepped over rather \
              than answered, and the bounded search found no concrete \
              ambiguity at them; the grammar is unproven at those sites \
              and closed everywhere else. Raising --prove-refine, or \
              changing the grammar at those sites, is what would settle \
              them.\n"
             (List.length !retirements)
         else
           printf
             "NOT PROVEN: the abstract candidate could not be concretized \
              within the search bounds; the grammar is neither proven \
              unambiguous nor shown ambiguous. Raising --prove may remove \
              the spurious candidate.\n");
        exit not_proven_status
      end;
      printf "This is a bounded result, not a proof of unambiguity.\n";
      exit 0
  | witnesses ->
      printf "Found %d complete ambiguity %s.\n"
        (List.length witnesses)
        (if List.length witnesses = 1 then "family" else "families");
      List.iteri
        (fun index (profile, witness) ->
          printf "\n%d. Tokens (%d): %s\n   Source: %s\n"
            (index + 1) (List.length witness) (String.concat " " witness)
            (render automaton witness);
          printf "   Conflict origins: %s\n"
            (profile
            |> List.map (fun (state, token) ->
                   Printf.sprintf "state %d on %s" state token)
            |> String.concat ", "))
        witnesses;
      printf "\n";
      printf "Explored %d frontiers (%d unique); %d conflict seeds.\n"
        outcome.explored outcome.unique conflict_seeds;
      printf "Search ended at depth %d because %s.\n"
        outcome.deepest termination;
      (* Concretizing the abstract candidate settles the proof: the
         witnesses above are the ambiguity the level-K abstraction
         suspected. A plain search reports the same witnesses as a bounded
         finding, not as a verdict, so it keeps its own status. *)
      exit (if !prove_level > 0 then ambiguous_status else 0)
