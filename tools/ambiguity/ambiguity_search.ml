(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol.

   This file is the entry point: it parses the command line, loads the
   automaton, and hands the work to the modules beside it -- [Automaton] for
   what is being proved, [Recognizer] for what the grammar accepts, [Prover]
   for the abstract verdict, [Search] for a concrete witness, and [Output] for
   everything a caller sees. *)

open Output
open Automaton
open Stack_pool
open Recognizer
open Abstraction
open Prover
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
      if !dump_classes then begin
        let members = Hashtbl.create 64 in
        Hashtbl.iter
          (fun token id ->
            Hashtbl.replace members id
              (token :: Option.value (Hashtbl.find_opt members id) ~default:[]))
          automaton.terminal_class;
        let classes =
          Hashtbl.fold (fun _ tokens result -> List.sort compare tokens :: result)
            members []
          |> List.sort compare
        in
        let singletons = List.filter (fun tokens -> List.length tokens = 1) classes in
        let merged = List.filter (fun tokens -> List.length tokens > 1) classes in
        printf "%d terminals in %d classes (%d merged, %d singleton).\n"
          (StringSet.cardinal automaton.terminals)
          (List.length classes) (List.length merged) (List.length singletons);
        List.iter
          (fun tokens -> printf "  { %s }\n" (String.concat " " tokens))
          merged;
        if singletons <> [] then
          printf "  singletons: %s\n"
            (String.concat " " (List.concat singletons));
        exit 0
      end;
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
      if !prove_level > 0 then begin
        (* The abstract phase is one sequential search, not a pool of workers,
           so dividing the budget by AMBIGUITY_JOBS would hand most of it to
           workers that never start. It is derived here for a single worker;
           the concretization search below still splits the budget its own
           way. Note that the profile's token bound feeds the entry-size
           estimate, so a narrower profile also buys a larger pair budget. *)
        let prove_limits =
          derive_memory_limits ~memory_mb ~max_frontier_ratio ~jobs:1
            ~max_tokens
        in
        printf
          "Proof budget: %d abstract pairs (single-threaded; the %d-worker \
           split does not apply).\n"
          prove_limits.max_frontiers jobs;
        (* Refinement's loop. A candidate is a question rather than an
           answer -- it may be a real ambiguity or a gap the abstraction left
           -- and the two are told apart by sharpening the abstraction exactly
           where this candidate needed it blunt. A spurious pair dies once the
           gotos along its path are exact; a real one survives every round and
           stops the loop by asking for nothing more, which is a far more
           informative way to fail than stopping at the first candidate.

           The rounds share the pair budget and the clock rather than each
           getting their own, so refining is bounded by the same limits an
           unrefined proof answers to. *)
        let precision =
          Array.make (Array.length automaton.states) !prove_level
        in
        let deadline = Unix.gettimeofday () +. timeout in
        let rounds = ref 0 in
        let cegar_used = ref 0 in
        let blocked_sentences = ref [] in
        let stalled = ref None in
        (* A request for more depth than --prove-refine allows is clamped to the
           ceiling rather than skipped, so refinement still makes what progress
           it can. Clamping silently is what made the ceiling invisible: a
           candidate could need a retained stack of 11, be asked for 9 every
           round, and survive without a single line of output saying the
           requirement had been cut down. The deepest request is kept so the
           report can name the number to raise the ceiling to. *)
        let capped : (int, int) Hashtbl.t = Hashtbl.create 16 in
        (* [retired] is what the search consults; [retirements], declared
           outside this block, is what the report prints, in the order the
           decisions were made -- the concretization search below is reached
           by a retiring run too, and its verdict has to say so. *)
        let retired : (int * int * string, unit) Hashtbl.t = Hashtbl.create 16 in
        (* The site the previous round's candidate was born at, and how many
           rounds in a row have landed on it. A refinement that deepens the
           stacks behind a blind spot and is answered by the same blind spot has
           bought nothing, and a site that answers that way every time is one no
           depth in this abstraction reaches. The counter is the only evidence
           available for that -- whether a blind spot is finite is not something
           a run can decide -- so it is reported as a decision to stop looking
           rather than as a property of the grammar. *)
        let last_site = ref None in
        let streak = ref 0 in
        (* The persistent walk is an optimisation, but its ancestry is an
           abstraction result.  After a refinement, a settled pair can still
           be reached through an ancestry that was only valid at the previous
           precision.  On the first repeated site at a given precision,
           replay the walk from its root once.  This is a cheap completeness
           guard for the refinement driver: it discards stale ancestry before
           spending another depth increment, while the marker prevents the
           fresh replay from recursively replaying itself. *)
        let fresh_checked_round = ref (-1) in
        (* What the exact recognizer made of a candidate's own sentence, said
           once per candidate wherever the candidate is handled. A spurious
           pair and a real one read identically in the abstract phase's own
           output, and the difference decides whether the next round is work
           or waste. *)
        let report_candidate_parse candidate =
          (match candidate.candidate_derivations with
          | 0 ->
              printf
                "  the recognizer rejects this sentence, so the pair is \
                 spurious\n"
          | 1 ->
              printf
                "  the recognizer accepts it exactly once, so the pair is \
                 spurious\n"
          | count -> printf "  the recognizer finds %d derivations of it\n" count);
          Option.iter
            (fun (index, token) ->
              printf
                "  the abstraction leaves the real parse's stacks after %d \
                 token(s), on %s\n"
                index token)
            candidate.candidate_decisive
        in
        (* One walk, carried across every round. A deepening sharpens the
           abstraction the walk is using; it does not invalidate what the walk
           has already settled, so the rounds share a table and a queue instead
           of each starting from the initial pair again. *)
        let walk = create_prove_state prove_limits.max_frontiers in
        let rec attempt () =
          let result =
            prove ~blocked_sentences:!blocked_sentences engine walk precision
              prove_limits.max_frontiers deadline !survey_limit !trace_forward
              retired
          in
          match result with
          (* Settled by the grammar rather than by the abstraction: the
             recognizer found two parses of the candidate's own sentence.
             Refining sharpens an abstraction that was right, so there is
             nothing here for another round to buy -- the run goes straight to
             the bounded search, which renders the witness family and reports
             the ambiguity. *)
          | Abstract_candidate candidate
            when candidate.candidate_derivations >= 2 ->
              result
          | Abstract_candidate candidate
            when !cegar_used < !cegar_rounds ->
              (match
                 check_exclusion engine candidate.candidate_tokens
                   ~variant_limit:4096 ~deadline
               with
              | Exclusion_checked variants ->
                  incr cegar_used;
                  blocked_sentences :=
                    candidate.candidate_tokens :: !blocked_sentences;
                  reset_prove_state walk;
                  printf
                    "CEGAR refinement %d: excluded complete history %s after \
                     exact-checking all %d terminal-class substitution(s) for \
                     at most one parse; restarting with a history-trie product.\n"
                    !cegar_used
                    (String.concat " " candidate.candidate_tokens) variants;
                  attempt ()
              | Exclusion_ambiguous tokens ->
                  Abstract_candidate
                    {
                      candidate with
                      candidate_tokens = tokens;
                      candidate_derivations = 2;
                      candidate_decisive = None;
                      candidate_forward = [];
                      candidate_example =
                        { candidate.candidate_example with example_tokens = tokens };
                    }
              | Exclusion_incomplete reason ->
                  printf
                    "CEGAR stopped: %s; the candidate remains in the proof \
                     language.\n"
                    reason;
                  result)
          | Abstract_candidate candidate when !refine_max > 0 ->
              let tokens = candidate.candidate_tokens in
              let site = candidate.candidate_site in
              if
                !last_site = Some site
                && !rounds > 0
                && !fresh_checked_round <> !rounds
              then begin
                fresh_checked_round := !rounds;
                reset_prove_state walk;
                printf
                  "  repeated site at refinement round %d; restarting the abstract walk at the current precision\n"
                  !rounds;
                attempt ()
              end
              else begin
              if !last_site = Some site then incr streak
              else begin
                last_site := Some site;
                streak := 1
              end;
              (* The aim is the step where the abstraction left the language,
                 and it is worth following while it moves the blind spot. A
                 site that answers a round with the same site has not been
                 moved by it, and asking the same step again would widen by one
                 entry per round behind an aim that has already been shown not
                 to be enough. So a repeat falls back to every guess on the
                 path -- what the loop asked for before it could aim -- and the
                 aim resumes at the next site. *)
              let requests =
                if !streak > 1 && candidate.candidate_path_requests <> [] then
                  candidate.candidate_path_requests
                else candidate.candidate_requests
              in
              (* What the chain asks for is the depth that would make each of
                 its guessed gotos exact. That is the right first request and
                 not always a sufficient one: a reduction consumes the entries
                 it pops, so a stack made deep enough for one reduction can be
                 too shallow for the next, and a blind spot whose appetite
                 grows that way is not something a local rule can name. When
                 the chain's own request buys nothing new, the loop widens by
                 one instead of stopping, which lets it climb to the ceiling
                 the caller set rather than stalling well below it - and makes
                 a candidate that survives all the way to that ceiling mean
                 what --prove-refine says it means. *)
              List.iter
                (fun (state, depth) ->
                  if depth > !refine_max then
                    match Hashtbl.find_opt capped state with
                    | Some existing when existing >= depth -> ()
                    | _ -> Hashtbl.replace capped state depth)
                requests;
              let wanted depth_of =
                List.filter_map
                  (fun request ->
                    let depth = min !refine_max (depth_of request) in
                    if depth > precision.(fst request) then
                      Some (fst request, depth)
                    else None)
                  requests
              in
              let exact = wanted snd in
              (* [wanted] keeps only requests for more than a state already
                 retains, so an empty list is exactly the case where deepening
                 would change nothing. Asking that question without performing
                 the deepening is what lets the round limit be checked first:
                 refining for a round that will not run would leave the report
                 describing a precision no proof was ever run at. *)
              let deeper =
                if exact <> [] then exact
                else wanted (fun (state, _) -> precision.(state) + 1)
              in
              let stop reason =
                stalled := Some reason;
                result
              in
              (* Why this site is not worth another round. Both reasons are
                 about this site alone, which is what makes retiring it and
                 carrying on meaningful; the round limit below is a budget for
                 the whole run, so reaching it says nothing about any one site
                 and still ends the loop. *)
              let exhausted =
                if deeper = [] then
                  Some
                    (Printf.sprintf
                       "it survives every stack --prove-refine %d allows"
                       !refine_max)
                else if !retire_after > 0 && !streak >= !retire_after then
                  Some
                    (Printf.sprintf
                       "%d consecutive round(s) of deepening left the \
                        divergence at the same site"
                       !streak)
                else None
              in
              let retire reason =
                let state, other, lookahead = site in
                Hashtbl.replace retired site ();
                reset_prove_state walk;
                retirements :=
                  (site, reason, candidate.candidate_example) :: !retirements;
                last_site := None;
                streak := 0;
                printf
                  "Retired the divergence site at state%s %d%s on lookahead \
                   %s: %s. Continuing with the rest of the grammar.\n"
                  (if state = other then "" else "s")
                  state
                  (if state = other then "" else Printf.sprintf " and %d" other)
                  lookahead reason;
                attempt ()
              in
              (* What the round limit is really bounding is abstract phases,
                 and a retirement starts one exactly as a deepening does.
                 Counting only deepenings would leave the limit unable to bite
                 at all on a grammar with many blind spots: nothing increments
                 [rounds], so a run could retire its way through one phase per
                 site with the ceiling never reached. Both are charged to the
                 same budget, while [rounds] stays a count of deepenings for
                 the report, which is the number that describes the
                 abstraction the run ended at. *)
              let budget_left =
                !rounds + List.length !retirements < !refine_rounds
              in
              if requests = [] then
                stop
                  "the candidate's chains never needed the abstraction to \
                   invent a goto and never stood on a stack it could not have \
                   rebuilt, so no retained stack rules it out"
              else if exhausted <> None then begin
                (* This site is finished either way. The only question left is
                   whether there is budget to retire it and go on. *)
                let reason = Option.get exhausted in
                if !retire_after > 0 && budget_left then retire reason
                else if !retire_after > 0 then
                  stop
                    (Printf.sprintf
                       "%s, and the round limit (%d) left no room to retire it \
                        and carry on"
                       reason !refine_rounds)
                else stop reason
              end
              else if not budget_left then
                stop
                  (Printf.sprintf "the round limit (%d) was reached"
                     !refine_rounds)
              else begin
                List.iter
                  (fun (state, depth) -> deepen precision state depth)
                  deeper;
                invalidate_prove_state walk (List.map fst deeper);
                incr rounds;
                report_candidate_parse candidate;
                printf
                  "Refinement round %d: deepened the stacks behind %s, \
                   retaining up to %d (%s).\n"
                  !rounds
                  (String.concat " " tokens)
                  (Array.fold_left max 0 precision)
                  (String.concat ", "
                     (List.map
                        (fun (state, depth) ->
                          Printf.sprintf "state %d to %d" state depth)
                        deeper));
                attempt ()
              end
              end
          | result -> result
        in
        let capped_summary () =
          if Hashtbl.length capped = 0 then None
          else
            let deepest_state, deepest_depth =
              Hashtbl.fold
                (fun state depth ((_, best) as previous) ->
                  if depth > best then (state, depth) else previous)
                capped (-1, 0)
            in
            Some
              (Printf.sprintf
                 "%d state(s) asked for a deeper stack than --prove-refine %d \
                  allows and were cut down to it; the deepest is state %d, \
                  which is exact from %d."
                 (Hashtbl.length capped) !refine_max deepest_state deepest_depth)
        in
        let precision_summary () =
          let deepest = Array.fold_left max 0 precision in
          let deepened =
            Array.fold_left
              (fun count depth -> if depth > !prove_level then count + 1 else count)
              0 precision
          in
          Printf.sprintf
            "%d refinement round(s); %d of %d state(s) deepened past level \
             %d, to a retained stack of %d at the deepest."
            !rounds deepened (Array.length precision) !prove_level deepest
        in
        (* Refinement's own state, for the outcomes that are not a verdict about
           the grammar. A run that deepened the abstraction and then ran out of
           pairs or clock is a different situation from one that never refined,
           and the ceiling may be part of why: reporting neither leaves the
           reader to guess whether raising --prove-refine would have helped or
           was already the thing making the run expensive. *)
        (* What the height test did, whenever it did anything. A move it
           refuses is one the abstraction would otherwise have carried, so a
           run that refused many explored a visibly different space from one
           that refused none, and the reader should not have to infer which
           from the pair count. *)
        let report_reachability () =
          if !refused_stacks > 0 then
            printf
              "Stack height: refused %d move(s) onto a state no stack that \
               short can carry; the height stops being counted past %d.\n"
              !refused_stacks !tracked_height;
          if !refused_residues > 0 then
            printf
              "Stack residue: refused %d move(s) whose outstanding terminals \
               cannot reach the selected automaton state (%d residue \
               classes).\n"
              !refused_residues residue_count
        in
        (* The retired sites are the part of a retiring run that is not in its
           verdict: the verdict says the rest of the grammar came out clean,
           and this says what "the rest" left out. Each one is printed with the
           sentence that reached it and the conflict behind it, because a site
           nobody can act on is not a useful thing to have stopped for. *)
        (* [exhaustive] is whether the abstract phase actually finished walking
           the space. Only then is "nowhere else" a claim about the grammar: a
           run stopped by the clock, the pair budget, or a surviving candidate
           has classified the sites it retired and nothing about the rest, and
           saying otherwise would read as coverage it never had. *)
        let report_retirements ~exhaustive () =
          if !retirements <> [] then begin
            let retirements = List.rev !retirements in
            printf
              "Retired %d divergence site(s), each after refinement stopped \
               moving it. The grammar is unproven at these sites %s:\n"
              (List.length retirements)
              (if exhaustive then "and nowhere else"
               else
                 "and unclassified everywhere else, since this run stopped \
                  before it finished walking the abstract space");
            List.iteri
              (fun index ((state, other, lookahead), reason, example) ->
                printf "  %d. state%s %d%s on lookahead %s: %s\n"
                  (index + 1)
                  (if state = other then "" else "s")
                  state
                  (if state = other then ""
                   else Printf.sprintf " and %d" other)
                  lookahead reason;
                printf "     reached by: %s\n"
                  (String.concat " " example.example_tokens);
                List.iter
                  (fun line -> printf "     %s\n" line)
                  example.example_site)
              retirements
          end
        in
        let report_refinement ~exhaustive () =
          report_retirements ~exhaustive ();
          if !rounds > 0 then
            printf "Refinement reached: %s\n" (precision_summary ());
          Option.iter
            (fun summary -> printf "Refinement was capped: %s\n" summary)
            (capped_summary ());
          report_reachability ()
        in
        match attempt () with
        | Proven pairs when !retirements <> [] ->
            (* Everything the search was still allowed to look at came out
               clean. That is a real result and a much sharper one than a
               candidate, but it is not a proof: the retired sites were stepped
               over, not answered, and a proof that quietly excluded them would
               be the most dangerous line this tool could print.

               It also does not end the run. Retiring a site drops the
               candidate that would otherwise have been handed to the bounded
               search, and if that site were a real ambiguity rather than a
               blind spot, exiting here would be how the witness stopped being
               reported. So a retiring run always goes on to concretize, and
               the verdict at the bottom names the retired sites. *)
            printf
              "Closed everywhere the search was still allowed to look: \
               outside the retired site(s), no diverging pair of accepting \
               parses exists in the top-%d stack abstraction (%d abstract \
               pairs explored).\n"
              !prove_level pairs;
            report_refinement ~exhaustive:true ();
            printf
              "Attempting to concretize with the bounded search...\n\n"
        | Proven pairs ->
            (* A proof is the one verdict that cannot be allowed to be an
               artifact of how the walk was carried. Every round after the
               first inherits a table built at blunter precisions, and the
               argument for keeping it -- that a pair found not to accept stays
               that way as the stacks get longer -- is exactly the kind of
               argument that a bookkeeping slip turns into a false theorem.
               So a refined proof is re-proved from nothing at the precision it
               ended on. The walk it doubts is the cheap one; this is paid once,
               only where a proof was claimed, and it is the difference between
               a theorem and a theorem about a table. *)
            let confirmed =
              if !rounds = 0 && !cegar_used = 0 then true
              else begin
                printf
                  "Re-proving from the initial pair at the precision and \
                   history filter this run ended on, against the same \
                   complete language...\n";
                match
                  prove ~blocked_sentences:!blocked_sentences engine
                    (create_prove_state prove_limits.max_frontiers)
                    precision prove_limits.max_frontiers deadline
                    !survey_limit false retired
                with
                | Proven fresh ->
                    printf
                      "Confirmed: the fresh walk reaches the same verdict (%d \
                       abstract pairs).\n"
                      fresh;
                    true
                | _ -> false
              end
            in
            if not confirmed then begin
              printf
                "NOT PROVEN: the shared walk reported a proof that a fresh \
                 walk at the same precision does not reach, so the proof was \
                 an artifact of what the rounds carried rather than a fact \
                 about the grammar. This is a bug in the prover, not a \
                 verdict about the grammar.\n";
              report_refinement ~exhaustive:false ();
              exit not_proven_status
            end;
            printf
              "PROVEN UNAMBIGUOUS: no diverging pair of accepting parses \
               exists in the top-%d stack abstraction (%d abstract pairs \
               explored%s).\n"
              !prove_level pairs
              (if !cegar_used = 0 then ""
               else
                 Printf.sprintf
                   ", after %d exact-checked complete-history exclusion(s)"
                   !cegar_used);
            (* What a regression run has to reproduce. A refined proof holds of
               a sharper abstraction than the level alone names, so the level
               alone does not identify it. *)
            if !rounds > 0 then
              printf "Refinement: %s\n" (precision_summary ());
            report_reachability ();
            exit 0
        | Surveyed survey ->
            printf
              "Survey at level %d: %d distinct divergence site(s), %d \
               accepting abstract pair(s), %d pairs explored%s.\n"
              !prove_level survey.sites survey.accepting survey.survey_pairs
              (if survey.covered then ""
               else " (incomplete: the counts are a floor)");
            List.iteri
              (fun index example ->
                printf "  %d. %s\n" (index + 1)
                  (String.concat " " example.example_tokens);
                List.iter
                  (fun line -> printf "     %s\n" line)
                  example.example_site)
              survey.examples;
            (* The proof turns on whether any diverging pair reaches
               acceptance, which is what `accepting` counts. Sites are a
               diagnostic breakdown of the same thing, and gating the verdict on
               them would let any gap in site accounting print a false proof. *)
            if survey.accepting = 0 && survey.covered then begin
              printf
                "PROVEN UNAMBIGUOUS: no diverging pair of accepting parses \
                 exists in the top-%d stack abstraction (%d abstract pairs \
                 explored).\n"
                !prove_level survey.survey_pairs;
              exit 0
            end;
            printf
              "NOT PROVEN: the survey enumerates where the abstraction cannot \
               separate two parses; it does not concretize them.\n";
            exit not_proven_status
        | Pair_overflow pairs ->
            printf
              "NOT PROVEN: the abstract pair limit (%d) was reached at \
               abstraction level %d. Raise AMBIGUITY_MEMORY_MB or \
               AMBIGUITY_MAX_FRONTIER_RATIO, or lower --prove.\n"
              pairs !prove_level;
            report_refinement ~exhaustive:false ();
            exit not_proven_status
        | Prove_timeout pairs ->
            printf
              "NOT PROVEN: the timeout (%gs) expired during the abstract \
               phase at level %d, after %d pairs. Raise --timeout, or lower \
               --prove.\n"
              timeout !prove_level pairs;
            report_refinement ~exhaustive:false ();
            exit not_proven_status
        | Abstract_candidate candidate ->
            let tokens = candidate.candidate_tokens in
            let example = candidate.candidate_example in
            let forward = candidate.candidate_forward in
            report_retirements ~exhaustive:false ();
            printf
              "Abstract ambiguity candidate at level %d after %d pairs (%s): \
               %s\n"
              !prove_level candidate.candidate_pairs
              (if candidate.candidate_derivations >= 2 then
                 "confirmed by the recognizer"
               else "spurious")
              (String.concat " " tokens);
            (* Where it stalled, not just what it stalled on. A candidate
               sentence says nothing about which context the abstraction lost,
               and after a refinement has run it is the only way to see whether
               deepening moved the blind spot or merely paid for it. *)
            List.iter
              (fun line -> printf "  %s\n" line)
              example.example_site;
            report_candidate_parse candidate;
            if candidate.candidate_derivations >= 2 then
              confirmed := Some tokens;
            List.iter (fun line -> printf "  %s\n" line) forward;
            (* Why refinement gave up is the part worth reading. A candidate
               that outlived an abstraction made exact along its own path is
               evidence of a real ambiguity, and reads very differently from
               one that only ran out of rounds or depth. *)
            Option.iter
              (fun reason ->
                printf "Refinement stopped after %d round(s): %s.\n"
                  !rounds reason;
                printf "Refinement reached: %s\n" (precision_summary ()))
              !stalled;
            (* Printed whether or not refinement stalled, because it is the one
               line that says the ceiling itself was the constraint. *)
            Option.iter
              (fun summary -> printf "Refinement was capped: %s\n" summary)
              (capped_summary ());
            (* A surviving candidate is exactly where the reader wants to know
               how much the height test was doing, because it is the line that
               separates "the abstraction is blind here" from "the abstraction
               looked and the moves were real". Leaving it off this path made
               the test look inert on every run that did not end in a proof. *)
            report_reachability ();
            (* The candidate sentence has already been checked by the exact
               recognizer. Once it has two derivations, the bounded replay
               below cannot change the verdict; it can only fail to reach a
               sentence that is already known ambiguous. *)
            if candidate.candidate_derivations >= 2 then begin
              printf
                "AMBIGUOUS: the recognizer found two derivations of %s (%s).\n"
                (String.concat " " tokens) (render automaton tokens);
              exit ambiguous_status
            end;
            printf
              "Attempting to concretize with the bounded search...\n\n"
      end;
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
          exit (if !prove_level > 0 then ambiguous_status else 0))

let () =
  try main ()
  with
  | Failure message | Invalid_argument message | Sys_error message
  | Unix.Unix_error (_, _, message) ->
      clear_progress ();
      prerr_endline ("error: " ^ message);
      exit 2
