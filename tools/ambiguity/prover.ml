(* Whether the abstract state space can rule out ambiguity.

   Explores pairs of abstract runs over the same input; a pair that diverges
   and accepts is a candidate rather than an answer, so this module also owns
   the refinement rounds that try to sharpen the abstraction at the site the
   candidate was born at, and the retirement that gives a site up. *)

open Output
open Automaton
open Recognizer
open Abstraction

type pair_node = stack * stack * bool * int

(* Proof states are long-lived keys containing two linked stack suffixes.
   Default polymorphic hashing walks both suffixes on every table probe. The
   immutable stack digest is computed once by Abstraction.make_stack; use it
   only for bucket selection and retain complete structural equality, which
   preserves exact pair identity even if digests collide. *)
module PairTable = Hashtbl.Make (struct
  type t = pair_node
  let equal (a, b, x, c) (d, e, y, f) =
    x = y && c = f && a = d && b = e
  let hash (a, b, x, c) = Hashtbl.hash (a.digest, b.digest, x, c)
end)

(* A survey answers a different question from a proof. The proof stops at the
   first divergence it can reach, which says nothing about how many more lie
   behind it - and that count is what decides whether refining the abstraction
   is worth attempting at all. A handful of sites is a tractable list; a
   thousand means the grammar is not unambiguous for reasons this abstraction
   can ever see, and the remainder belong in written obligations instead. *)
(* A sentence alone does not say why the abstraction admitted a pair: the same
   token trail is reported whether the two parses genuinely differ or the
   abstraction merely lost the context that separated them. The site does say,
   so each example carries the stacks and lookahead it was born at, rendered
   with the moves available there. *)
type survey_example = {
  example_tokens : string list;
  example_site : string list;
}

type prove_survey = {
  sites : int;
  accepting : int;
  examples : survey_example list;
  survey_pairs : int;
  covered : bool;
}

(* A candidate carries the site it was born at and the refinement requests its
   own path justifies: the states where the abstraction had to invent a goto to
   keep the pair alive, each with the depth that would have made that step
   exact. An empty request list is the interesting case -- the pair survived an
   abstraction that was exact everywhere along its path, so no amount of extra
   depth will remove it. The site is what says where refinement stalled, in the
   same form a survey prints. *)
type abstract_candidate = {
  candidate_tokens : string list;
  candidate_pairs : int;
  candidate_example : survey_example;
  candidate_forward : string list;
  candidate_requests : (int * int) list;
  (* The site reduced to what survives a change of abstraction: the two states
     on top and the lookahead. The stacks under those states are exactly what a
     refinement lengthens, so the rendered site in [candidate_example] names a
     different triple after every round even when the blind spot has not moved.
     This one does not, which is what lets the loop ask whether a round bought
     anything. *)
  candidate_site : int * int * string;
  (* What the exact recognizer makes of the candidate's own sentence: 0 if it
     rejects it, 1 if it has a single parse, 2 if the abstraction was right and
     this is a real ambiguity. The abstract phase cannot answer this -- it
     reasons about every sentence at once -- but one sentence is cheap to parse
     for real, and the answer decides whether there is anything to refine. *)
  candidate_derivations : int;
  (* The first step at which the abstraction was standing on a stack no real
     parse of this sentence stands on, as the number of tokens consumed before
     it and the token that produced it. That is where the abstraction went
     wrong, so it is where a refinement is worth spending: the requests the
     candidate carries are the ones made at that step, rather than every guess
     anywhere along a path whose tail the real parse never reached. *)
  candidate_decisive : (int * string) option;
  (* Every guess anywhere on the candidate's path, which is what the aim
     narrows down from. Aiming is worth it while it moves the blind spot, and
     when it stops moving it the loop has to be able to ask for everything
     again rather than crawl one entry per round behind an aim that is not
     enough. *)
  candidate_path_requests : (int * int) list;
}

type prove_result =
  | Proven of int
  | Abstract_candidate of abstract_candidate
  | Exact_ambiguity of string list
  | Pair_overflow of int
  | Prove_timeout of int
  | Surveyed of prove_survey

type exclusion_check =
  | Exclusion_checked of int
  | Exclusion_ambiguous of string list
  | Exclusion_incomplete of string

(* Proof-mode exit statuses. A proof is a verdict rather than a success or a
   failure, so `ambiguity prove` reports which of the three it reached in its
   status: 0 proven, 1 a concrete ambiguous sentence, 3 neither. Status 2 stays
   what it is everywhere else in this tool - the run itself went wrong - so a
   caller can tell a verdict from a broken invocation. A plain search reports no
   verdict and keeps exiting 0 whether or not it found witnesses. *)
let ambiguous_status = 1
let not_proven_status = 3


(* What a refinement round inherits from the one before it.

   A round used to re-prove the grammar from nothing at the precision the last
   one left behind, and that is what made the rounds get dearer as they went:
   the twenty-second round of a ninety-minute run was re-deriving the first
   round's pairs before it could reach anything new. Nothing about the previous
   round's work goes stale, though. Deepening a retained stack only ever
   sharpens the abstraction, and a sharper abstraction has fewer behaviours
   than the one it refines -- so a pair explored under the blunt abstraction
   and found not to accept cannot start accepting once the stacks behind it get
   longer. The pairs are a result about the grammar, not about the round that
   found them.

   So the table and the queue live across rounds, and a round pays only for
   what it has not already settled. What does go stale is everything derived
   from the precision array: the two caches are keyed by stacks whose
   truncation the deepening just changed, so they are emptied and refilled
   lazily by the walk that follows.

   [requeue] is the exception that keeps this sound. The one pair a finished
   round did *not* settle is the candidate it stopped at, and the finer pairs
   that replace it are reached from the pair before it. That parent is pushed
   again by hand, and the candidate is dropped from the table so that a
   deepening which fails to split it can rediscover it rather than mistake it
   for settled. *)
type prove_state = {
  parents :
    (pair_node, (string * pair_node) option) PairTable.t;
  (* Queued pairs, in buckets by how many tokens it took to reach them, so the
     walk stays shortest-first across every round. One queue would not: a round
     resumes with deep pairs left over from the round before it and shallow
     ones just reopened by a deepening, and whichever went in first would come
     out first. The walk would then report whatever candidate lay nearest to
     where it stopped rather than the shortest one in the grammar, and a blind
     spot that answers each deepening with a longer sentence -- the signature
     of one no depth closes -- would stop being visible as one. *)
  buckets : (int, pair_node Queue.t) Hashtbl.t;
  depths : (pair_node, int) PairTable.t;
  (* Pairs that are in the table but have not been walked yet. [parents] holds
     a pair from the moment it is pushed, so it is not by itself a record of
     what has been settled, and a deepening has to treat the two differently:
     a settled pair stays as the result it is, an unsettled one is only a plan
     to look, and a stale plan is worth less than the sharper one that
     replaces it. *)
  waiting : (pair_node, unit) PairTable.t;
  mutable pending : int;
  (* The shallowest bucket that may still hold anything. Children are one
     deeper than their parent, so it only moves forward, except where a
     reopened pair puts something shallower back. *)
  mutable cursor : int;
  mutable requeue : pair_node list;
  mutable seeded : bool;
}

let enqueue state node depth =
  let bucket =
    match Hashtbl.find_opt state.buckets depth with
    | Some bucket -> bucket
    | None ->
        let bucket = Queue.create () in
        Hashtbl.add state.buckets depth bucket;
        bucket
  in
  Queue.add node bucket;
  PairTable.replace state.waiting node ();
  state.pending <- state.pending + 1;
  if depth < state.cursor then state.cursor <- depth

let dequeue state =
  let rec take () =
    if state.pending <= 0 then None
    else
      match Hashtbl.find_opt state.buckets state.cursor with
      | Some bucket when not (Queue.is_empty bucket) ->
          state.pending <- state.pending - 1;
          let node = Queue.take bucket in
          PairTable.remove state.waiting node;
          Some node
      | _ ->
          state.cursor <- state.cursor + 1;
          take ()
  in
  take ()

let node_depth state node =
  Option.value (PairTable.find_opt state.depths node) ~default:0

(* Retiring a site is the one thing that invalidates the walk behind it.

   A pair is deduplicated on first arrival, so it keeps the ancestry it was
   first reached by -- and after a retirement that ancestry decides whether it
   is pruned, since a pair under a retired divergence is stepped over. A pair
   first reached through the site that has just been retired is therefore
   written off, while the same pair reached from somewhere else would not be,
   and a site lying behind it goes with it. Restarting each round hid this,
   because every round reached every pair afresh; carrying the table across
   rounds does not, and the palindrome loses its second site to it.

   So a retirement empties the walk. That costs the one round it happens in and
   keeps the rest, which is the trade the whole persistence is: deepening never
   invalidates a settled pair, retiring always can. *)
let reset_prove_state state =
  PairTable.reset state.parents;
  Hashtbl.reset state.buckets;
  PairTable.reset state.depths;
  PairTable.reset state.waiting;
  state.pending <- 0;
  state.cursor <- 0;
  state.requeue <- [];
  state.seeded <- false

(* What a deepening puts back into play: the pairs standing on it.

   A stack is truncated to what the state on top of it is granted, so deepening
   a state changes every stack that state appears in. What that means for a
   pair depends on whether the walk has been through it.

   A **settled** pair -- one the walk has already taken its successors from --
   is still true: a pair explored under a blunter abstraction and found not to
   accept cannot start accepting once the stacks get longer. It stays in the
   table, and deleting it would strand the ancestry of everything below it,
   which the trail and the site both read. What is missing is the sharper pair
   that would stand in its place now, and that is reached by asking the pair
   before it again.

   An **unsettled** pair -- pushed but not yet walked -- is not a result at
   all, only a plan to look. Leaving a stale one in the queue means the walk
   will look at the blunt pair rather than the sharp one, which is the round's
   own work undone: the deepening buys nothing wherever the queue still holds
   the shape it was meant to replace. So those are dropped from the queue and
   from the table, and their parents rebuild them at the precision that now
   applies. Dropping them loses nothing, because a pair that has never been
   walked has nothing below it to strand.

   Everything the deepening did not touch stands. That is the point: on a
   grammar with a thousand states, deepening a handful of them leaves almost
   the whole table alone, where restarting the round threw all of it away. *)
let invalidate_prove_state state deepened =
  match deepened with
  | [] -> ()
  | _ ->
      let touched = Hashtbl.create (2 * List.length deepened) in
      List.iter (fun id -> Hashtbl.replace touched id ()) deepened;
      let standing_on stack =
        List.exists (fun id -> Hashtbl.mem touched id) stack.suffix
      in
      (* The table holds queued pairs beside settled ones, so the count of what
         a round kept has to take them back out -- and the reopened count is
         the stale pairs that stayed, not the ones discarded below. *)
      let settled = PairTable.length state.parents - PairTable.length state.waiting in
      let stale = Hashtbl.create 1_009 in
      PairTable.iter
        (fun ((left, right, _, _) as node) _ ->
          if standing_on left || standing_on right then
            Hashtbl.replace stale node ())
        state.parents;
      (* The unsettled ones leave altogether, so that the parent's rebuild can
         push their replacement -- keeping them in the table would let the
         replacement be dropped as already seen. *)
      let dropped = Hashtbl.create 1_009 in
      let orphaned = ref [] in
      Hashtbl.iter
        (fun node () ->
          if PairTable.mem state.waiting node then begin
            (* The parent is read before the entry goes, because it is what
               rebuilds this pair at the new precision. Losing it here would
               lose the pair altogether, which is the one thing this must not
               do. *)
            (match PairTable.find_opt state.parents node with
            | Some (Some (_, parent)) -> orphaned := parent :: !orphaned
            | Some None | None -> state.seeded <- false);
            Hashtbl.replace dropped node ();
            PairTable.remove state.parents node;
            PairTable.remove state.waiting node;
            PairTable.remove state.depths node
          end)
        stale;
      if Hashtbl.length dropped > 0 then begin
        let buckets = Hashtbl.copy state.buckets in
        Hashtbl.reset state.buckets;
        state.pending <- 0;
        state.cursor <- max_int;
        Hashtbl.iter
          (fun depth bucket ->
            Queue.iter
              (fun node ->
                if not (Hashtbl.mem dropped node) then enqueue state node depth)
              bucket)
          buckets;
        if state.cursor = max_int then state.cursor <- 0
      end;
      (* The pair the last round asked for again stays on the list even when
         the deepening made it stale, and this is load-bearing. Asking a stale
         settled pair again is how its children are rebuilt at the new
         precision -- and where the deepening does not change that pair at all,
         it is the only way, because the unchanged rebuild is dropped as
         already seen and its own parent then has nothing new to push. Filter
         it out and the candidate hanging off it disappears with it: the walk
         drains, and the run prints a proof of a grammar it stopped looking at.
         The palindrome does exactly that, which is what the fresh walk below a
         proof is there to catch. Entries the table no longer has are another
         matter, since nothing can be asked of a pair that is gone. *)
      state.requeue <-
        List.filter (fun node -> PairTable.mem state.parents node) state.requeue;
      (* A pair whose own parent is stale is left to that parent, so one sweep
         pushes the shallowest edge of the affected region rather than every
         pair in it. Seeded with what the list already holds, so a pair asked
         for twice is queued once -- twice would walk it twice and leave the
         waiting set disagreeing with the buckets after the first dequeue. *)
      let queued = Hashtbl.create 1_009 in
      List.iter (fun node -> Hashtbl.replace queued node ()) state.requeue;
      let ask parent =
        if
          (not (Hashtbl.mem stale parent))
          && (not (Hashtbl.mem queued parent))
          && PairTable.mem state.parents parent
        then begin
          Hashtbl.replace queued parent ();
          state.requeue <- parent :: state.requeue
        end
      in
      Hashtbl.iter
        (fun node () ->
          match PairTable.find_opt state.parents node with
          | Some (Some (_, parent)) -> ask parent
          | Some None ->
              (* The initial pair itself was truncated differently. It has no
                 earlier pair to ask, so it is dropped and the walk re-seeds. *)
              PairTable.remove state.parents node;
              state.seeded <- false
          | None ->
              (* Dropped above as unsettled; its parent was taken then. *)
              ())
        stale;
      List.iter ask !orphaned;
      printf
        "  reopened %d of %d settled pair(s) from %d entry point(s), \
         discarding %d queued\n"
        (Hashtbl.length stale - Hashtbl.length dropped)
        settled (Hashtbl.length queued) (Hashtbl.length dropped)

let create_prove_state pair_limit =
  {
    parents = PairTable.create (min 100_003 (max 1 pair_limit));
    buckets = Hashtbl.create 64;
    depths = PairTable.create (min 100_003 (max 1 pair_limit));
    waiting = PairTable.create (min 100_003 (max 1 pair_limit));
    pending = 0;
    cursor = 0;
    requeue = [];
    seeded = false;
  }

(* A representative token sequence stands for every sequence obtained by
   substituting a member of the same terminal class at each position. Replay
   every concrete substitution before excluding that representative history.
   The cap fails closed instead of treating unchecked variants as harmless. *)
let check_exclusion engine tokens ~variant_limit ~deadline =
  let class_members = Hashtbl.create 16 in
  let members token =
    match Hashtbl.find_opt engine.automaton.terminal_class token with
    | None -> [ token ]
    | Some class_id -> (
        match Hashtbl.find_opt class_members class_id with
        | Some members -> members
        | None ->
            let members =
              StringSet.elements engine.automaton.terminals
              |> List.filter (fun candidate ->
                     Hashtbl.find_opt engine.automaton.terminal_class candidate
                     = Some class_id)
            in
            Hashtbl.add class_members class_id members;
            members)
  in
  let choices = List.map members tokens in
  let variants =
    List.fold_left
      (fun count choices ->
        let width = List.length choices in
        if width = 0 || count > variant_limit / max 1 width then
          variant_limit + 1
        else count * width)
      1 choices
  in
  if variants > variant_limit then
    Exclusion_incomplete
      (Printf.sprintf
         "the candidate represents more than %d concrete terminal sequence(s)"
         variant_limit)
  else
    let rec visit prefix = function
      | [] ->
          if Unix.gettimeofday () >= deadline then
            Exclusion_incomplete "the exact-check deadline expired"
          else
            let concrete = List.rev prefix in
            let frontiers = replay engine concrete in
            if
              accepted_count engine
                frontiers.(Array.length frontiers - 1)
              >= 2
            then Exclusion_ambiguous concrete
            else Exclusion_checked variants
      | choices :: rest ->
          let rec try_choices = function
            | [] -> Exclusion_checked variants
            | token :: tail ->
                (match visit (token :: prefix) rest with
                | Exclusion_checked _ -> try_choices tail
                | result -> result)
          in
          try_choices choices
    in
    visit [] choices

(* [deadline] is absolute rather than a duration because refinement runs this
   several times over: the rounds share one budget for the abstract phase, so a
   proof that needed four of them is not four times as patient as one that
   needed none. *)
(* [retired] names sites the caller has already given up on. A pair whose
   divergence was born at one of them is not a candidate: the search steps over
   it and keeps going, so one blind spot that no depth closes stops standing in
   for every other question about the grammar. Retiring is the caller's
   judgement and not a fact about the grammar, which is why a run that used it
   can never print a proof - see the verdict below. *)
let prove ?(blocked_sentences = []) engine (state : prove_state)
    (precision : precision) pair_limit
    deadline survey_limit trace
    (retired : (int * int * string, unit) Hashtbl.t) =
  let automaton = engine.automaton in
  (* Filter states are included in every abstract pair key. Any added sentence
     therefore requires a fresh walk and fresh caches. *)
  let history_filter = History_filter.create blocked_sentences in
  let gotos = goto_edges automaton in
  let preds = predecessors automaton in
  let below = below_steps preds in
  let reachable = reachable_stack_residues automaton in
  let prod_residues = production_residues automaton in
  (* Past the widest reduction in the grammar the exact height stops deciding
     anything: every reduction has the entries it needs and one to spare, which
     is what the abstraction assumed before it counted at all. So that is where
     the count saturates, and the abstract stack space stays finite. *)
  refused_stacks := 0;
  refused_residues := 0;
  let widest_reduction =
    Array.fold_left
      (fun widest state ->
        Hashtbl.fold
          (fun _ reductions widest ->
            List.fold_left
              (fun widest reduction -> max widest reduction.width)
              widest reductions)
          state.reductions widest)
      0 automaton.states
  in
  (* Two tests read the height, and they want different things from it.
     Ruling out a reduction that would pop the whole stack only has to tell
     heights apart up to the widest reduction, so that test alone would be
     content to stop counting just past [widest_reduction]. Pinning a stack to
     the initial state - what turns a truncated goto from a guess into the only
     move available - needs the height to still be a number at the depths real
     stacks reach, which is further down. [min_height] measures how far: the
     deepest one is the tallest stack the automaton forces any parse to build,
     and counting a little past it keeps the pinning available where it pays.
     Stopping too early is not unsound, it is merely blind - a saturated height
     admits every move - which is why a ceiling that only served the first test
     left the second one inert on a real grammar. Counting higher is sharper
     still and costs more distinct stacks; [AMBIGUITY_HEIGHT_CEILING] raises it
     for a grammar that wants the trade. *)
  let tallest_forced =
    Array.fold_left
      (fun tallest needed ->
        if needed = max_int then tallest else max tallest needed)
      0 automaton.min_height
  in
  let height_ceiling =
    let natural = max widest_reduction tallest_forced + 2 in
    match Sys.getenv_opt "AMBIGUITY_HEIGHT_CEILING" with
    | None | Some "" -> natural
    | Some value -> (
        match int_of_string_opt value with
        | Some raised -> max natural raised
        | None -> invalid_arg "AMBIGUITY_HEIGHT_CEILING must be an integer")
  in
  tracked_height := height_ceiling;
  (* Joint height/residue reachability, not the intersection of two unrelated
     existential paths. Saturated heights retain the unrestricted table. *)
  let reachable_height =
    Array.init height_ceiling (fun _ ->
        Array.init (Array.length automaton.states) (fun _ ->
            Bytes.make residue_count '\000'))
  in
  Bytes.set reachable_height.(1).(0) 0 '\001';
  for height = 1 to height_ceiling - 2 do
    Array.iteri
      (fun source state ->
        Hashtbl.iter
          (fun symbol target ->
            let edge =
              if StringSet.mem symbol automaton.terminals then
                terminal_residue symbol else 0
            in
            for residue = 0 to residue_count - 1 do
              if Bytes.get reachable_height.(height).(source) residue = '\001'
              then Bytes.set reachable_height.(height + 1).(target)
                  (residue lxor edge) '\001'
            done)
          state.transitions)
      automaton.states
  done;
  (* Keyed by a single suffix rather than a pair, so this stays small and is
     read by every pair that reaches the same stack: worth keeping whole. *)
  let moves_cache = Hashtbl.create 100_003 in
  let reduction_cache = Hashtbl.create 100_003 in
  let incoming = Array.make (Array.length automaton.states) IntSet.empty in
  Array.iter
    (fun state -> Hashtbl.iter
        (fun symbol target ->
          let edge = if StringSet.mem symbol automaton.terminals then
              terminal_residue symbol else 0 in
          incoming.(target) <- IntSet.add edge incoming.(target))
        state.transitions)
    automaton.states;
  let viable stack =
    let rec check height residue = function
      | [] -> true
      | top :: rest ->
          let fits = reachable.(top).(residue)
            && (height >= height_ceiling
                || (height > 0 && Bytes.get reachable_height.(height).(top)
                    residue = '\001')) in
          fits && (match rest with
            | [] -> true
            | _ when IntSet.cardinal incoming.(top) = 1 ->
                check (if height >= height_ceiling then height else height - 1)
                  (residue lxor IntSet.choose incoming.(top)) rest
            | _ -> true)
    in
    let fits = check stack.height stack.residue stack.suffix in
    if not fits then incr refused_residues;
    fits
  in
  let viable_cache = Hashtbl.create 16_384 in
  let viable stack =
    match Hashtbl.find_opt viable_cache stack with
    | Some fits -> fits
    | None ->
        let fits = viable stack in
        Hashtbl.add viable_cache stack fits;
        fits
  in
  let moves =
    let raw = side_moves automaton gotos below preds reachable reachable_height
        prod_residues precision height_ceiling reduction_cache moves_cache in
    fun stack token ->
      if viable stack then raw stack token else []
  in
  (* One stack walked back down to its full height, for the refinement scan to
     ask whether anything was lost by cutting it short. A saturated height is
     not a height at all, so there is nothing to walk down to and the walk
     reports none rather than one. *)
  let descend stack =
    if stack.height >= height_ceiling then []
    else
      cap_variants preds below precision stack.height height_ceiling
        stack.height stack.suffix
  in
  (* The pair cache is the opposite. Each node is dequeued once and asks for
     every terminal class exactly once, so the only repeat key is the twin
     node that shares a stack pair and differs in its divergence flag. Left
     unbounded it would hold one entry per explored pair per terminal class,
     dwarfing the pair table that the memory budget actually caps, so it is
     emptied whenever it outgrows its share. *)
  let joint_capacity = max 1 (pair_limit / 8) in
  (* Sized to start where the other tables do, but never larger than the cap it
     will be held to: a small budget must not pre-allocate a table it can never
     fill, and a large one should still grow on demand rather than reserve its
     ceiling up front. *)
  let joint_cache = Hashtbl.create (min 100_003 joint_capacity) in
  (* Many pairs share one side. Its completed reduction closure is independent
     of the other side; retaining it across pairs avoids repeating that walk.
     Clear this optional cache at the same capacity bound as the joint cache.
     Both are local to one precision round. *)
  let finish_cache = Hashtbl.create (min 100_003 joint_capacity) in
  let joint pair token diverged =
    match Hashtbl.find_opt joint_cache (pair, token, diverged) with
    | Some outcomes -> outcomes
    | None ->
        if Hashtbl.length finish_cache >= joint_capacity then
          Hashtbl.reset finish_cache;
        let outcomes = joint_outcomes moves finish_cache ~diverged pair token in
        if Hashtbl.length joint_cache >= joint_capacity then
          Hashtbl.reset joint_cache;
        Hashtbl.add joint_cache (pair, token, diverged) outcomes;
        outcomes
  in
  let parents = state.parents in
  let overflow = ref false in
  let candidate = ref None in
  (* A site is the stack pair and lookahead at which two parses first part
     ways: the same divergence reached by many sentences is one blind spot,
     not many, so sites are what get counted. *)
  let sites : (stack * stack * string, unit) Hashtbl.t =
    Hashtbl.create 1_009
  in
  let accepting = ref 0 in
  let examples = ref [] in
  let example_count = ref 0 in
  let history_subsumption_checks = ref 0 in
  let history_subsumed = ref 0 in
  let surveying = survey_limit > 0 in
  let canonical (left, right, diverged, history) =
    if compare left right <= 0 then (left, right, diverged, history)
    else (right, left, diverged, history)
  in
  (* An Other-history pair has at least one concrete prefix which has already
     left every excluded sentence's prefix trie. At identical abstract stacks,
     its continuation moves are the same as a trie-prefix pair's, and every
     accepting continuation from Other remains outside the finite exclusion
     set. So it subsumes that trie-prefix pair for this existential proof
     search. The converse is false: a trie prefix may be the only way to reach
     an excluded acceptance. A diverged Other pair may cover an undiverged
     trie pair, but not vice versa. Keep this deliberately narrower than stack
     subsumption; no abstract stack simulation is involved. If a site has been
     retired, disable the shortcut because retirement is ancestry-sensitive. *)
  let subsumed_by_other (left, right, diverged, history) =
    if
      not
        (History_filter.history_subsumption_enabled ~surveying
           ~has_retired_sites:(Hashtbl.length retired > 0))
      || History_filter.is_other history_filter history
    then false
    else begin
      incr history_subsumption_checks;
      List.exists
        (fun other_diverged ->
          History_filter.other_history_subsumes ~covering_other:true
            ~covering_diverged:other_diverged ~covered_other:false
            ~covered_diverged:diverged
          && PairTable.mem parents
               (left, right, other_diverged, History_filter.other))
        [ false; true ]
    end
  in
  let push origin node =
    let node = canonical node in
    if not (PairTable.mem parents node) then
      if subsumed_by_other node then incr history_subsumed
      else if PairTable.length parents >= pair_limit then overflow := true
      else begin
        PairTable.add parents node origin;
        let depth =
          match origin with
          | None -> 0
          | Some (_, parent) -> node_depth state parent + 1
        in
        PairTable.replace state.depths node depth;
        enqueue state node depth
      end
  in
  let rec trail node =
    match PairTable.find parents node with
    | None -> []
    | Some (token, parent) -> token :: trail parent
  in
  (* Where the divergence was born, not where it was noticed. An accepting pair
     usually inherits its flag from an ancestor, and it is the ancestor's
     stacks and lookahead - the same triple the site table counts - that say
     why the abstraction could not separate the two parses. A pair that is not
     itself diverged reached acceptance by parting ways on end of input, so its
     own stacks under "#" are the site. *)
  let accepting_site ((left, right, _, _) as node) =
    let rec climb ((_, _, diverged, _) as node) =
      if not diverged then None
      else
        match PairTable.find parents node with
        | None -> None
        | Some
            ( token,
              ((parent_left, parent_right, parent_diverged, _) as parent) )
          ->
            if parent_diverged then climb parent
            else Some (parent_left, parent_right, token)
    in
    match climb node with
    | Some site -> site
    | None -> (left, right, "#")
  in
  (* The site as something two runs at different precisions can compare. Only
     the top entry of each stack is kept, because that is the entry a deepening
     never changes: refinement lengthens what sits below it. The two states are
     ordered so that a pair and its mirror name one site, the same way
     [canonical] treats the stacks themselves. *)
  let site_identity (left, right, lookahead) =
    let top stack = match stack.suffix with state :: _ -> state | [] -> -1 in
    let one = top left and other = top right in
    if one <= other then (one, other, lookahead) else (other, one, lookahead)
  in
  let is_retired node =
    Hashtbl.length retired > 0
    && Hashtbl.mem retired (site_identity (accepting_site node))
  in
  (* A retired site takes its whole subtree with it. A child inherits
     [diverged], and [accepting_site] climbs to the first ancestor that is not
     diverged, so every node below a diverged one reports that node's site: the
     subtree under a retired divergence cannot produce a candidate anywhere
     else, and walking it is work that has no outcome. Stepping over the site
     without pruning it was measured on Zane's grammar at 55 minutes and 1.3M
     pairs after the retirement, with no second candidate and no end to the
     phase.

     Only diverged nodes are eligible. An undiverged node has no site yet --
     [accepting_site] hands back its own stacks under "#" -- so asking whether
     it is retired would prune on a triple that names something else.

     One thing this can cost: pairs are deduplicated on first arrival, so a
     triple first reached under a retired site is not pushed again from
     elsewhere, and a site reachable only that way is not found. That is a
     reason a retiring run reports what it looked at rather than a proof; it
     already never claims one. *)
  let prune_subtree ((_, _, diverged, _) as node) =
    diverged && is_retired node
  in
  (* The node the divergence was born at, rather than the triple describing it:
     the forward walk has to start somewhere it can walk down from. *)
  let divergence_origin node =
    let rec climb ((_, _, diverged, _) as node) =
      if not diverged then None
      else
        match PairTable.find parents node with
        | None -> None
        | Some (_, ((_, _, parent_diverged, _) as parent)) ->
            if parent_diverged then climb parent else Some parent
    in
    climb node
  in
  (* Every step a pair took, root first, as the node standing before each token
     and the token it then consumed. [parents] points upward, so this is the
     same walk [trail] makes, keeping the nodes instead of discarding them. *)
  let path_steps node =
    let rec walk node collected =
      match PairTable.find parents node with
      | None -> collected
      | Some (token, parent) -> walk parent ((parent, token) :: collected)
    in
    walk node []
  in
  (* What happened *after* the two parses parted ways.

     Every other diagnostic here reports where a divergence was born. That is
     the right thing when the abstraction lost the context that separated two
     parses, because then the site is also the explanation. It says nothing
     when the site's own conflict is exact - two moves a real sentence could
     both begin with - since then the pair is admitted not by anything at the
     site but by both sides walking on to acceptance, and the step that should
     have killed one of them is somewhere along that walk.

     So this replays the recorded path from the site down to the accepting
     node, and asks of each step the only question that distinguishes a real
     ambiguity from an artifact: did this step need the abstraction to guess a
     goto anywhere in it? A walk that guesses nowhere is a pair no extra precision will
     remove, whatever the level, and says the sentence is worth concretizing.
     One that guesses at a particular step names the state to sharpen, which
     the site alone never could. *)
  let describe_forward node =
    let node_pair = node in
    let render_stack stack =
      String.concat " " (List.map string_of_int stack.suffix)
    in
    let guesses (left, right, _, _) token child =
      let target =
        Option.map
          (fun (child_left, child_right, _, _) -> (child_left, child_right))
          child
      in
      List.map
        (fun (top, depth) ->
          Printf.sprintf "guessed at state %d (exact from %d)" top depth)
        (joint_imprecision automaton moves (left, right) token target)
    in
    let step index ((left, right, _, _) as node) token child =
      let stacks =
        if left = right then Printf.sprintf "stack %s" (render_stack left)
        else
          Printf.sprintf "left %s | right %s" (render_stack left)
            (render_stack right)
      in
      let line =
        Printf.sprintf "%2d. on %-12s %s" index token stacks
      in
      match guesses node token child with
      | [] -> [ line ^ "  [exact]" ]
      | found -> line :: List.map (fun text -> "      " ^ text) found
    in
    (* Acceptance is not one of the recorded edges - the pair reaches it under
       the end-of-input sentinel, which the walk takes separately - so it is
       replayed here rather than left off the end. It has no recorded child, so
       any termination counts. *)
    let closing index = step index node "#" None in
    match divergence_origin node with
    (* Not diverged means the pair parted ways on end of input, exactly as
       [accepting_site] treats it: its own stacks under "#" are the site, and
       that single step is the whole walk. Returning nothing here printed no
       trace at all for a candidate whose divergence was born at EOF, while
       still reporting that one was requested. *)
    | None -> "forward from the site, to acceptance:" :: closing 1
    | Some origin ->
        let rec from_origin = function
          | [] -> []
          | (candidate, _) :: _ as rest when candidate = origin -> rest
          | _ :: tail -> from_origin tail
        in
        let steps = from_origin (path_steps node) in
        (* Each recorded step is rendered against the pair it actually produced,
           which is the next step's node, or the accepting node for the last.
           An origin that is somehow not on the recorded path leaves no steps to
           pair up; the closing step still says what happened at acceptance,
           which is better than a diagnostic that raises. *)
        let rec render index = function
          | [] -> []
          | [ (node, token) ] -> step index node token (Some node_pair)
          | (node, token) :: ((next, _) :: _ as rest) ->
              step index node token (Some next) @ render (index + 1) rest
        in
        ("forward from the site, to acceptance:" :: render 1 steps)
        @ closing (List.length steps + 1)
  in
  (* Every place along a candidate's path where the abstraction guessed, keyed
     by the state on top there and carrying the deepest request made of it. The
     scan covers both sides of every step and then the end of input, which is
     where a pair that parted ways on "#" did its guessing. Runs once, on a
     path bounded by the token budget. *)
  let candidate_refinements node =
    let wanted = Hashtbl.create 64 in
    let record (top, depth) =
      match Hashtbl.find_opt wanted top with
      | Some existing when existing >= depth -> ()
      | _ -> Hashtbl.replace wanted top depth
    in
    let scan (left, right, _, _) token =
      List.iter
        (fun stack -> List.iter record (chain_imprecision automaton moves stack token))
        (if left = right then [ left ] else [ left; right ])
    in
    let rec walk node =
      match PairTable.find parents node with
      | None -> ()
      | Some (token, parent) ->
          scan parent token;
          walk parent
    in
    walk node;
    scan node "#";
    begin
      (* Imprecision is not only invented gotos: a truncated stack conflates
         every real stack that ends the same way, and two of those can differ
         in what happens next. Nothing about that asks for depth at a goto, so
         a candidate whose chain is already clean would have nothing to
         sharpen - and a candidate whose gotos ask for depth they have already
         been granted would have nothing new, which is the same dead end
         reached from the other side.

         So ask each truncated stack on the path for its own height. Its
         height is how many entries it really has, so that is the one depth
         that stops conflating it with anything: a stack retaining as many
         entries as it is tall is the whole stack, and no deeper request can
         mean anything, since nothing sits below the initial state. Truncated
         is therefore the whole condition - when every stack the chains stand
         on is already complete there is nothing left to sharpen, and the run
         says so rather than pretending another round would help.

         Asking for the height rather than one entry more than the stack
         carries matters more than it looks. Widening by one turns a single
         blind spot into a round per entry, and every one of those rounds pays
         for a whole proof at a precision that was never going to be enough;
         the ceiling clamps the request anyway, so the crawl buys nothing the
         jump does not.

         The stacks between tokens are not the only ones to ask. A reduction
         chain truncates at every step, and the stack that was cut is usually
         one inside the chain rather than one the path recorded - which is how
         a candidate could reach acceptance with every recorded stack complete,
         every goto exact, and a chain standing the whole way on entries the
         descent had invented. So walk the chains, exactly as the goto scan
         does. Each recorded stack is the first stack of its own chain, so this
         asks for everything the path-level widening asked for and more. *)
      let widen (left, right, _, _) token =
        List.iter
          (fun stack ->
            List.iter record (chain_truncations descend moves stack token))
          (if left = right then [ left ] else [ left; right ])
      in
      let rec walk node =
        match PairTable.find parents node with
        | None -> ()
        | Some (token, parent) ->
            widen parent token;
            walk parent
      in
      walk node;
      widen node "#"
    end;
    Hashtbl.fold (fun top depth result -> (top, depth) :: result) wanted []
  in
  (* One representative per terminal class: interchangeable lookaheads drive
     the same abstract reduction chains, so exploring one covers the class and
     shrinks the abstract pair space by the same factor as the search. *)
  let terminals =
    StringSet.elements (class_representatives automaton automaton.terminals)
  in
  let render_stack stack =
    String.concat " " (List.map string_of_int stack.suffix)
  in
  (* One move at the stack it fires from. A reduction is tagged by how far it
     pops, because that is what says how much the abstraction had to invent
     about where it lands. Popping less than the retained stack resolves the
     goto exactly and needs no tag. Popping the stack exactly exposes whatever
     sat directly below its deepest entry, so the goto source is narrowed to
     that entry's predecessors - constrained, but no longer known. Popping
     further is the same rule applied further down: the source is narrowed to
     the states that many entries below the deepest one retained, a set that
     widens with every step past the suffix and is what a deeper stack would
     replace with a single state. The two must not share a tag: they say
     different things about how much room a refinement has, and reading the
     exact-pop case as the looser one would point a refinement at a gap the
     predecessor filter already closed. *)
  let describe_move stack lookahead move =
    match move with
    | Terminate next ->
        if lookahead = "#" then "accept"
        else (
          match next.suffix with
          | target :: _ -> Printf.sprintf "shift to %d" target
          | [] -> "shift")
    | Reduce (prod, _) ->
        let depth = List.length stack.suffix in
        let width =
          match stack.suffix with
          | [] -> None
          | top :: _ ->
              Option.map
                (fun reduction -> reduction.width)
                (List.find_opt
                   (fun reduction -> reduction.prod = prod)
                   (reductions automaton.states.(top) lookahead))
        in
        Printf.sprintf "reduce %s%s"
          (production_name automaton prod)
          (match width with
          | Some width when width > depth ->
              Printf.sprintf
                " [pops past the retained stack: goto limited to states %d \
                 below its deepest]"
                (width - depth + 1)
          | Some width when width = depth ->
              " [pops the retained stack exactly: goto limited to predecessors]"
          | _ -> "")
  in
  (* Two runs can only part ways by taking different moves, so a pair that is
     still undiverged carries the same stack on both sides and a site is one
     stack, not two. The unequal case is printed rather than assumed away: if
     that invariant ever stops holding, the report should show it instead of
     quietly picking a side. *)
  let describe_site (left, right, lookahead) =
    let header = Printf.sprintf "divergence site on lookahead %s" lookahead in
    let stacks =
      if left = right then
        [ Printf.sprintf "abstract stack (top first): %s" (render_stack left) ]
      else
        [
          Printf.sprintf "left stack (top first): %s" (render_stack left);
          Printf.sprintf "right stack (top first): %s" (render_stack right);
        ]
    in
    let conflict =
      match conflicting_moves moves left lookahead with
      | Some (stack, (one, other)) ->
          [
            Printf.sprintf "conflict at stack %s:" (render_stack stack);
            "  " ^ describe_move stack lookahead one;
            "  " ^ describe_move stack lookahead other;
          ]
      | None -> [ "conflict not localized within the reduction chain" ]
    in
    (header :: stacks) @ conflict
  in
  if not state.seeded then begin
    let start = make_stack [ 0 ] 1 0 in
    state.seeded <- true;
    push None (start, start, false, History_filter.root history_filter)
  end;
  (* The pairs a deepening put back into play. They are already in [parents]
     from the round that explored them, so [push] would drop them as seen:
     they go onto the queue directly, and keep the origin edge they already
     have so their trail still reads back to the initial pair. *)
  List.iter
    (fun node -> enqueue state node (node_depth state node))
    state.requeue;
  state.requeue <- [];
  (* The abstract phase used to run in silence: minutes on a real grammar,
     often the whole timeout, with the verdict as the first line of output. A
     reader watching it wants to know the same three things the concretization
     search reports -- how much has been settled, how much is still queued, and
     whether anything accepting has turned up -- so they go out on the same
     channel, at the same cadence, and are cleared the same way.

     [since_progress] keeps the extra clock read off the per-pair path. Every
     pair costs a joint-outcome pass over every terminal class, so one check
     per 128 of them is still far finer than the interval it feeds, and a phase
     that never reaches 128 pairs is over long before a line would have been
     due. *)
  let phase_started = Unix.gettimeofday () in
  let since_progress = ref 0 in
  let report_progress () =
    if progress_due () then
      show_progress_line
        (Printf.sprintf
           "● abstract level %d | pairs %s | queued %s | accepting %d%s | %s"
           (Array.fold_left max 0 precision)
           (compact_number (PairTable.length parents))
           (compact_number state.pending)
           !accepting
           (* Sites are only recorded while surveying, so a run that is not
              surveying would report a standing zero that says nothing. *)
           (if surveying then
              Printf.sprintf " | sites %d" (Hashtbl.length sites)
            else "")
           (elapsed_clock (Unix.gettimeofday () -. phase_started)))
  in
  (* The clock is read once per dequeued pair, as the concretization search
     reads it once per expanded frontier: a pair costs a joint-outcome pass
     over every terminal class, so the read does not show up beside it. *)
  while
    state.pending > 0
    && (surveying || !candidate = None)
    && (not !overflow)
    && Unix.gettimeofday () < deadline
  do
    (* [pending] counts what the buckets hold, so a dequeue under it always
       finds a pair. *)
    let (left, right, diverged, history) as node =
      match dequeue state with Some node -> node | None -> assert false
    in
    incr since_progress;
    if !since_progress >= 128 then begin
      since_progress := 0;
      report_progress ()
    end;
    (* EOF is a lookahead like any other, but it is not in [terminals] - it is
       the sentinel the joint outcomes take separately - so a pair that first
       parts ways on end of input would otherwise never have its site recorded
       while still counting as an accepting divergence. *)
    let eof_outcomes = joint (left, right) "#" diverged in
    (* Only complete blocked histories are discarded, at an accepting EOF
       outcome. Prefixes keep all continuations, including longer sentences. *)
    let excluded_at_eof = History_filter.is_blocked history_filter history in
    let accepts_diverged =
      (not excluded_at_eof)
      && List.exists
        (fun (_, _, chain_diverged) -> diverged || chain_diverged)
        eof_outcomes
    in
    if
      surveying && (not diverged)
      && List.exists (fun (_, _, chain_diverged) -> chain_diverged) eof_outcomes
    then Hashtbl.replace sites (left, right, "#") ();
    if accepts_diverged then begin
      incr accepting;
      (* A pair at a retired site still counts as an accepting divergence --
         it is as real as it ever was, and hiding it from the count would let a
         retirement look like progress. It just stops being the answer. The
         count does thin out below one, because the subtree is pruned rather
         than walked, which is another reason it is a floor on a retiring
         run. *)
      if !candidate = None && not (is_retired node) then candidate := Some node;
      if surveying && !example_count < survey_limit then begin
        examples :=
          {
            example_tokens = List.rev (trail node);
            example_site = describe_site (accepting_site node);
          }
          :: !examples;
        incr example_count
      end
    end;
    if (surveying || !candidate = None) && not (prune_subtree node) then
      List.iter
        (fun token ->
          List.iter
            (fun (next_left, next_right, chain_diverged) ->
              (* Born here, rather than inherited: a node that is already
                 diverged carries its ancestor's site, and counting it again
                 at every step would report the length of the path instead of
                 the number of blind spots. *)
              if surveying && (not diverged) && chain_diverged then
                Hashtbl.replace sites (left, right, token) ();
              let next_history =
                History_filter.advance history_filter history token
              in
              push
                (Some (token, node))
                (next_left, next_right, diverged || chain_diverged, next_history))
            (joint (left, right) token diverged))
        terminals
  done;
  clear_progress ();
  let explored = PairTable.length parents in
  (* A queue left with work in it is the only way past the loop other than a
     verdict, so it - not the clock - is what says the deadline cut the search
     short. Draining the queue exactly as time runs out is a completed proof,
     and is reported as one. *)
  let ran_out_of_time = state.pending > 0 in
  if !history_subsumption_checks > 0 then
    printf
      "History subsumption: checked %d trie-prefix enqueue(s); skipped %d already covered by an existing Other-history pair.\n"
      !history_subsumption_checks !history_subsumed;
  if surveying then
    Surveyed
      {
        sites = Hashtbl.length sites;
        accepting = !accepting;
        examples = List.rev !examples;
        survey_pairs = explored;
        (* Counts are a floor unless the whole abstract space was walked. *)
        covered = (not !overflow) && not ran_out_of_time;
      }
  else
    match !candidate with
    | Some node ->
        let site = accepting_site node in
        let tokens = List.rev (trail node) in
        (* The candidate, parsed for real. Two things come back that the
           abstract phase cannot know: whether the sentence is ambiguous at
           all, and - step by step - which stacks a real parse of it was
           standing on. *)
        let frontiers = replay engine tokens in
        let parses = accepted_count engine frontiers.(Array.length frontiers - 1) in
        let steps = Array.of_list (path_steps node) in
        let pair_at index =
          if index < Array.length steps then fst steps.(index) else node
        in
        (* Whether any stack the recognizer really built after [index] tokens
           ends the way this abstract stack says it does. An abstract stack
           with no such counterpart is one the abstraction invented: either
           the real parse died before here, or it went somewhere else. *)
        let carried index stack =
          match stack.suffix with
          | [] -> true
          | _ ->
              let depth = List.length stack.suffix in
              IntMap.exists
                (fun stack_id _ ->
                  concrete_suffix engine stack_id depth = stack.suffix)
                frontiers.(index)
        in
        let decisive_step =
          let limit = min (Array.length frontiers - 1) (Array.length steps) in
          let rec scan index =
            if index > limit then None
            else
              let left, right, _, _ = pair_at index in
              if carried index left && carried index right then
                scan (index + 1)
              else
                let parent, token = steps.(index - 1) in
                Some (index, token, parent)
          in
          (* The initial pair is the real initial stack, so the walk starts
             one step in: the first stack the abstraction could have got wrong
             is the one the first move produced. *)
          scan 1
        in
        (* The guesses made at one step, which is what a refinement aimed by
           the real parse asks for. [candidate_refinements] asks the same of
           every step on the path; that is the right question when nothing
           says which step was the wrong one, and the wrong one to pay for
           when something does. *)
        let requests_at (left, right, _, _) token =
          let wanted = Hashtbl.create 16 in
          let record (top, depth) =
            match Hashtbl.find_opt wanted top with
            | Some existing when existing >= depth -> ()
            | _ -> Hashtbl.replace wanted top depth
          in
          List.iter
            (fun stack ->
              List.iter record (chain_imprecision automaton moves stack token);
              List.iter record (chain_truncations descend moves stack token))
            (if left = right then [ left ] else [ left; right ]);
          Hashtbl.fold (fun top depth found -> (top, depth) :: found) wanted []
        in
        let aimed =
          match decisive_step with
          | None -> []
          | Some (_, token, parent) -> requests_at parent token
        in
        let along_the_path = candidate_refinements node in
        let found =
          Abstract_candidate
            {
              candidate_tokens = tokens;
              candidate_pairs = explored;
              candidate_example =
                { example_tokens = tokens; example_site = describe_site site };
              candidate_forward = (if trace then describe_forward node else []);
              candidate_requests = (if aimed <> [] then aimed else along_the_path);
              candidate_site = site_identity site;
              candidate_derivations = parses;
              candidate_decisive =
                Option.map (fun (index, token, _) -> (index, token)) decisive_step;
              candidate_path_requests = along_the_path;
            }
        in
        (* The one pair this round did not settle. Everything else it walked
           stays settled however the abstraction is sharpened, but this pair
           accepted, so the round after this one has to see whatever replaces
           it: the pair before it goes back on the queue, and this one leaves
           the table so that a deepening which does not split it rediscovers it
           instead of walking past it as seen.

           Done after the record is built, because every diagnostic in it --
           the trail, the site, the forward walk -- reads this node's entry. *)
        (match PairTable.find_opt parents node with
        | Some (Some (_, parent)) ->
            PairTable.remove parents node;
            state.requeue <- [ parent ]
        | Some None | None ->
            (* The initial pair accepted, so there is no earlier pair to push:
               the next round starts the walk again from the beginning. *)
            PairTable.remove parents node;
            state.seeded <- false);
        found
    | None ->
        if !overflow then Pair_overflow explored
        else if ran_out_of_time then Prove_timeout explored
        else Proven explored
