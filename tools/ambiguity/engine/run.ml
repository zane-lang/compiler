(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol.

   This module runs one invocation: it parses the command line, loads the
   automaton, and hands the work to the phase asked for -- [Classes] for
   `--dump-classes`, the recognizer for `--check-tokens`, [Proof] for the
   abstract phase of `--prove`, and [Concretize] for the bounded search. *)

open Output
open Automaton
open Stack_pool
open Recognizer
open Search
open Config

let main () =
  Arg.parse options (fun value -> grammar := value)
    "ambiguity_search [options] GRAMMAR";
  if !grammar = "" then begin
    Arg.usage options "ambiguity_search [options] GRAMMAR";
    exit 2
  end;
  let { menhir; memory_mb; max_frontier_ratio; jobs; search_limits } =
    settings ()
  in
  let grammar_path = Unix.realpath !grammar in
  let temporary = temporary_directory () in
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
      try remove_tree temporary with Sys_error _ | Unix.Unix_error _ -> ()
    end
  in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
      let terminals, aliases = parse_tokens grammar_path in
      let automaton_path =
        prepare_automaton ~menhir ~grammar:grammar_path
          ~directory:temporary
      in
      let automaton = parse_automaton automaton_path terminals aliases in
      let stacks = Stack_pool.create () in
      let engine =
        { automaton; stacks; closure_cache = Hashtbl.create 16_384 }
      in
      if !dump_classes then Classes.dump automaton;
      if !check_tokens <> [] then begin
        let frontier =
          List.fold_left (shift engine)
            (IntMap.singleton engine.stacks.root.id 1)
            !check_tokens
        in
        let count = accepted_count engine frontier in
        printf "Accepting derivations: %d\n" count;
        exit 0
      end;
      let max_tokens, timeout, max_witnesses = Option.get search_limits in
      if !min_tokens > max_tokens then
        invalid_arg "--min-tokens must not exceed --max-tokens";
      let prefix_depth = List.length !prefix_tokens in
      if prefix_depth > max_tokens then
        invalid_arg
          "--prefix-tokens must not contain more tokens than --max-tokens";
      let initial_frontier =
        List.fold_left (shift engine)
          (IntMap.singleton engine.stacks.root.id 1)
          !prefix_tokens
      in
      if IntMap.is_empty initial_frontier then
        invalid_arg "--prefix-tokens is not a valid grammar prefix";
      let initial =
        {
          tokens_rev = List.rev !prefix_tokens;
          depth = prefix_depth;
          frontier = initial_frontier;
          branched = derivations initial_frontier >= 2;
        }
      in
      printf
        "Search constraints: %d..%d total tokens; %d-token prefix; %s.\n"
        !min_tokens max_tokens prefix_depth
        (match !nodes_per_depth with
        | None -> "breadth-first scheduling"
        | Some 1 -> "1 node per depth"
        | Some limit -> Printf.sprintf "%d nodes per depth" limit);
      if !prefix_tokens <> [] then
        printf "Prefix tokens: %s\n" (String.concat " " !prefix_tokens);
      (* Sites refinement stopped pursuing, and the evidence for stopping. It
         outlives the proof block because it changes what every verdict below
         means: a run that stepped over a site has not answered it, and both
         the report and the exit status have to keep saying so. *)
      let retirements = ref [] in
      (* A candidate the recognizer confirmed, kept for the verdict at the
         bottom. The abstract phase has no token bound and the concretization
         search does, so a confirmed sentence can be longer than the search is
         allowed to reach -- and then the search finds nothing, having been
         asked a question whose answer is already in hand. Losing the finding
         there would report "neither proven unambiguous nor shown ambiguous"
         about a grammar this run has two derivations of. *)
      let confirmed = ref None in
      if !prove_level > 0 then
        Proof.run ~automaton ~engine ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens ~timeout
          ~initial ~retirements ~confirmed;
      Concretize.run ~automaton ~engine ~temporary ~memory_mb ~max_frontier_ratio ~jobs
        ~max_tokens ~timeout ~max_witnesses ~initial ~retirements ~confirmed)

let entry () =
  try main ()
  with
  | Failure message | Invalid_argument message | Sys_error message
  | Unix.Unix_error (_, _, message) ->
      clear_progress ();
      prerr_endline ("error: " ^ message);
      exit 2
