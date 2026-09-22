(* How a run is configured: the machine settings read from the environment,
   the flags the command line accepts, the memory limits derived from both, and
   the refusal of flag combinations that cannot mean anything together.

   [Automaton] is opened for [words] alone, which splits a token list the same
   way the grammar's own token declarations are split; nothing else here knows
   about the automaton. *)

open Output
open Automaton

let environment name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> value
  | _ -> invalid_arg (name ^ " must be set")

let environment_int name =
  match Sys.getenv_opt name with
  | None | Some "" -> invalid_arg (name ^ " must be set")
  | Some value ->
      (match int_of_string_opt value with
      | Some parsed -> parsed
      | None -> invalid_arg (name ^ " must be an integer"))

let environment_float name =
  match Sys.getenv_opt name with
  | None | Some "" -> invalid_arg (name ^ " must be set")
  | Some value ->
      (try float_of_string value
       with Failure _ -> invalid_arg (name ^ " must be a number"))

let grammar = ref ""
let max_tokens = ref None
let min_tokens = ref 0
let prefix_tokens = ref []
let nodes_per_depth = ref None
let timeout = ref None
let max_witnesses = ref None
let check_tokens = ref []
let prove_level = ref 0
let survey_limit = ref 0
let refine_max = ref 0
let refine_rounds = ref 12
let retire_after = ref 0
let trace_forward = ref false
let dump_classes = ref false
let raw_derivations = ref false

type memory_limits = {
  max_queue : int;
  max_frontiers : int;
  soft_heap_bytes : float;
  hard_heap_bytes : float;
}

(* Structural estimates choose how to divide the search space between queued
   work and deduplication.  Actual managed-heap measurements enforce the
   budget at runtime, so unexpectedly large frontiers reduce search reach
   instead of causing an unbounded memory spike.  Ten percent remains outside
   the worker high-water marks for the coordinator, native allocations, and
   short-lived copy-on-write/compaction overhead. *)
let derive_memory_limits ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens =
  let queue_entry_bytes = 600. +. (24. *. float_of_int max_tokens) in
  let frontier_entry_bytes = 240. in
  let declared_per_worker_bytes =
    float_of_int memory_mb *. 1024. *. 1024. /. float_of_int jobs
  in
  let hard_heap_bytes = 0.90 *. declared_per_worker_bytes in
  let soft_heap_bytes = 0.80 *. declared_per_worker_bytes in
  let combined_entry_bytes =
    queue_entry_bytes +. (max_frontier_ratio *. frontier_entry_bytes)
  in
  let max_queue_float = floor (hard_heap_bytes /. combined_entry_bytes) in
  if max_queue_float < 1. || max_queue_float > float_of_int max_int then
    invalid_arg
      "AMBIGUITY_MEMORY_MB is too small or too large for AMBIGUITY_JOBS";
  let max_queue = int_of_float max_queue_float in
  let max_frontiers_float =
    floor (float_of_int max_queue *. max_frontier_ratio)
  in
  if max_frontiers_float > float_of_int max_int then
    invalid_arg
      "AMBIGUITY_MEMORY_MB or AMBIGUITY_MAX_FRONTIER_RATIO is too large";
  let max_frontiers = max 1 (int_of_float max_frontiers_float) in
  { max_queue; max_frontiers; soft_heap_bytes; hard_heap_bytes }

let options =
  [
    ( "--max-tokens",
      Arg.Int (fun value -> max_tokens := Some value),
      "N maximum tokens, including EOF (required for search/prove)" );
    ( "--min-tokens",
      Arg.Set_int min_tokens,
      "N minimum tokens for reported witnesses, including the prefix and EOF \
       (default 0)" );
    ( "--prefix-tokens",
      Arg.String (fun value -> prefix_tokens := words value),
      "TOKENS consume a space-separated token prefix before searching" );
    ( "--nodes-per-depth",
      Arg.Int (fun value -> nodes_per_depth := Some value),
      "N queued frontiers to expand at each depth before descending; omitted \
       for breadth-first search" );
    ( "--timeout",
      Arg.Float (fun value -> timeout := Some value),
      "SECONDS time limit per search phase (required for search/prove)" );
    ( "--max-witnesses",
      Arg.Int (fun value -> max_witnesses := Some value),
      "N ambiguity families to report (required for search/prove)" );
    ( "--check-tokens",
      Arg.String (fun value -> check_tokens := words value),
      "TOKENS check one space-separated token sequence" );
    ( "--prove",
      Arg.Set_int prove_level,
      "K attempt an unambiguity proof with a top-K stack abstraction; \
       exits 0 proven, 1 a concrete ambiguous sentence, 3 neither, \
       2 a failed run \
       (the derived dedup-frontier limit also bounds the abstract pair count)" );
    ( "--prove-refine",
      Arg.Set_int refine_max,
      "K with --prove, treat a candidate as a reason to sharpen the \
       abstraction rather than as an answer: deepen the retained stack along \
       the candidate's own chain to a depth of at most K, and try again \
       (0 disables)" );
    ( "--prove-refine-rounds",
      Arg.Set_int refine_rounds,
      "N give up after N refinement rounds (default 12)" );
    ( "--prove-retire",
      Arg.Set_int retire_after,
      "N with --prove-refine, stop pursuing a divergence site once N \
       consecutive rounds of deepening have left the candidate at the same \
       site, and continue with the rest of the grammar; a run that retired \
       anything reports which sites and never reports a proof (0 disables)" );
    ( "--prove-trace",
      Arg.Set trace_forward,
      " with --prove, follow the reported candidate from its divergence site \
       down to acceptance, naming every step where either side needed the \
       abstraction to guess a goto" );
    ( "--prove-survey",
      Arg.Set_int survey_limit,
      "N with --prove, do not stop at the first divergence: walk the whole \
       abstract space and report how many distinct sites produce one, with up \
       to N example sentences" );
    ( "--dump-terminal-classes",
      Arg.Set dump_classes,
      " list the terminal equivalence classes the search collapses, then exit" );
    ( "--raw-derivations",
      Arg.Set raw_derivations,
      " count every derivation the grammar admits, including those the \
       compiler rejects after parsing; without it a grammar the validity \
       model recognizes has those derivations refused, so a count is of \
       readings that are programs" );
  ]

(* Everything a run needs to know before it builds anything, read and checked
   in one place so a bad setting is refused at the start rather than at the
   moment the run first depends on it. *)
type settings = {
  menhir : string;
  memory_mb : int;
  max_frontier_ratio : float;
  jobs : int;
  (* The bounds search and proof runs require and the other subcommands do
     not: maximum tokens, timeout, and how many witness families to report. *)
  search_limits : (int * float * int) option;
}

let settings () =
  let menhir = environment "AMBIGUITY_MENHIR" in
  let memory_mb = environment_int "AMBIGUITY_MEMORY_MB" in
  let max_frontier_ratio =
    environment_float "AMBIGUITY_MAX_FRONTIER_RATIO"
  in
  let jobs = environment_int "AMBIGUITY_JOBS" in
  (* Read here with the rest of the settings so a malformed cadence is refused
     before the run starts, rather than at whatever moment the first progress
     line happened to fall due. *)
  ignore (Lazy.force progress_interval : float);
  Option.iter
    (fun value ->
      if value < 0 then invalid_arg "--max-tokens must be at least 0")
    !max_tokens;
  if !min_tokens < 0 then invalid_arg "--min-tokens must be at least 0";
  Option.iter
    (fun value ->
      if value < 1 then invalid_arg "--nodes-per-depth must be at least 1")
    !nodes_per_depth;
  if memory_mb < 1 then invalid_arg "AMBIGUITY_MEMORY_MB must be at least 1";
  if
    Float.is_nan max_frontier_ratio
    || Float.is_infinite max_frontier_ratio
    || max_frontier_ratio <= 0.
  then
    invalid_arg
      "AMBIGUITY_MAX_FRONTIER_RATIO must be finite and greater than 0";
  Option.iter
    (fun value ->
      if value < 0. then invalid_arg "--timeout must be non-negative")
    !timeout;
  if jobs < 1 then invalid_arg "AMBIGUITY_JOBS must be at least 1";
  Option.iter
    (fun value ->
      if value < 1 then invalid_arg "--max-witnesses must be at least 1")
    !max_witnesses;
  if !survey_limit < 0 then
    invalid_arg "--prove-survey must be non-negative";
  if !survey_limit > 0 && !prove_level <= 0 then
    invalid_arg "--prove-survey requires --prove";
  if !refine_max < 0 then invalid_arg "--prove-refine must be non-negative";
  if !refine_max > 0 && !prove_level <= 0 then
    invalid_arg "--prove-refine requires --prove";
  if !refine_max > 0 && !refine_max < !prove_level then
    invalid_arg "--prove-refine must be at least --prove";
  (* A survey walks the whole abstract space and reports every site rather than
     stopping at one, so it never produces the single candidate a refinement
     would be guided by. Refusing the combination is better than accepting it
     and silently refining nothing. *)
  if !refine_max > 0 && !survey_limit > 0 then
    invalid_arg "--prove-refine cannot be combined with --prove-survey";
  if !refine_rounds < 1 then
    invalid_arg "--prove-refine-rounds must be at least 1";
  if !retire_after < 0 then invalid_arg "--prove-retire must be non-negative";
  (* Retiring is a decision about what refinement is failing to close, so it has
     nothing to act on without refinement running. *)
  if !retire_after > 0 && !refine_max = 0 then
    invalid_arg "--prove-retire requires --prove-refine";
  if !trace_forward && !prove_level <= 0 then
    invalid_arg "--prove-trace requires --prove";
  (* A survey never reports a single candidate, so there is no path to follow;
     it walks the whole abstract space and prints sites instead. *)
  if !trace_forward && !survey_limit > 0 then
    invalid_arg "--prove-trace cannot be combined with --prove-survey";
  let search_limits =
    if !check_tokens <> [] || !dump_classes then None
    else
      let required name = function
        | Some value -> value
        | None -> invalid_arg (name ^ " is required for search/prove")
      in
      Some
        ( required "--max-tokens" !max_tokens,
          required "--timeout" !timeout,
          required "--max-witnesses" !max_witnesses )
  in
  { menhir; memory_mb; max_frontier_ratio; jobs; search_limits }
