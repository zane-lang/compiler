(* `--prove`: the abstract phase (docs/ambiguity/soundness.md). It proves
   the grammar unambiguous at the level asked for, or hands the concretization
   search a candidate the recognizer could not settle, and every verdict it
   reaches on its own ends the run. *)

open Output
open Automaton
open Abstraction
open Prover
open Search
open Config

let run ~automaton ~engine ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens ~timeout ~initial
    ~retirements ~confirmed =
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
    "Proof budget: %d %s (single-threaded; the %d-worker \
     split does not apply).\n"
    prove_limits.max_frontiers
    (if !balanced_proof then "summary entries" else "abstract pairs") jobs;
  if !balanced_proof then begin
    Balanced_walk.validate automaton;
    printf "Balanced proof: all reachable production skeletons are well-nested; \
            ()/[]/{} histories are checked at arbitrary depth.\n"
  end;
  if Delimiter_history.modulus > 1 then begin
    Balanced_walk.validate automaton;
    printf "Delimiter history: net counts modulo %d; balanced production \
            skeletons checked; no depth or input-length bound.\n"
      Delimiter_history.modulus
  end;
  let delimiter_description =
    if Delimiter_history.modulus = 1 then ""
    else Printf.sprintf " intersected with delimiter counts modulo %d"
        Delimiter_history.modulus in
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
  (* A candidate whose complete terminal-class product exceeds the exact
     check budget cannot be excluded by CEGAR at any stack precision.
     Remember that sentence so a refinement retry can reach the normal
     stack-refinement branch instead of repeating the same incomplete
     check forever. *)
  let cegar_skipped : (string list, unit) Hashtbl.t =
    Hashtbl.create 16
  in
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
      when
        !cegar_used < !cegar_rounds
        && not (Hashtbl.mem cegar_skipped candidate.candidate_tokens) ->
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
              "CEGAR refinement %d: excluded complete history %s; the \
               representative has %d parse(s), and all %d concrete \
               terminal-class substitution(s) were checked for at most \
               one parse; restarting with a history-trie product.\n"
              !cegar_used
              (String.concat " " candidate.candidate_tokens)
              candidate.candidate_derivations variants;
            attempt ()
        | Exclusion_ambiguous tokens ->
            Exact_ambiguity tokens
        | Exclusion_incomplete reason ->
            Hashtbl.replace cegar_skipped candidate.candidate_tokens ();
            if !refine_max > 0 && Unix.gettimeofday () < deadline then begin
              printf
                "CEGAR check skipped: %s; continuing with stack \
                 refinement for this candidate.\n"
                reason;
              attempt ()
            end
            else begin
              printf
                "CEGAR stopped: %s; the candidate remains available as \
                 an abstract candidate.\n"
                reason;
              result
            end)
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
         exists in the top-%d stack abstraction%s (%d abstract pairs \
         explored%s).\n"
        !prove_level
        ((if !balanced_proof then " intersected with well-nested histories" else "")
         ^ delimiter_description) pairs
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
           exists in the top-%d stack abstraction%s (%d abstract pairs \
           explored).\n"
          !prove_level delimiter_description survey.survey_pairs;
        exit 0
      end;
      printf
        "NOT PROVEN: the survey enumerates where the abstraction cannot \
         separate two parses; it does not concretize them.\n";
      exit not_proven_status
  | Pair_overflow pairs ->
      printf
        "NOT PROVEN: the %s limit (%d) was reached at \
         abstraction level %d. Raise AMBIGUITY_MEMORY_MB or \
         AMBIGUITY_MAX_FRONTIER_RATIO, or lower --prove.\n"
        (if !balanced_proof then "summary entry" else "abstract pair") pairs !prove_level;
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
  | Exact_ambiguity tokens ->
      printf
        "AMBIGUOUS: exact validation of the candidate's terminal-class \
         substitutions found two derivations of %s (%s).\n"
        (String.concat " " tokens) (render automaton tokens);
      exit ambiguous_status
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
