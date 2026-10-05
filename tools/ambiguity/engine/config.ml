(* How a run is configured: the machine settings read from the environment,
   the flags the command line accepts, the memory limits derived from both, and
   the refusal of flag combinations that cannot mean anything together.

   [Automaton.words] splits a token list the same way the grammar's own token
   declarations are split; nothing else here knows about the automaton. *)

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

(* What the command line asked for. *)
type options = {
  grammar : string;
  max_tokens : int option;
  min_tokens : int;
  prefix_tokens : string list;
  nodes_per_depth : int option;
  timeout : float option;
  max_witnesses : int option;
  check_tokens : string list;
  dump_classes : bool;
}

let usage = "ambiguity_search [options] GRAMMAR"

(* The command line, parsed. Without a GRAMMAR it prints the usage and exits
   with status 2. *)
let parse_options () =
  let grammar = ref "" in
  let max_tokens = ref None in
  let min_tokens = ref 0 in
  let prefix_tokens = ref [] in
  let nodes_per_depth = ref None in
  let timeout = ref None in
  let max_witnesses = ref None in
  let check_tokens = ref [] in
  let dump_classes = ref false in
  let specs =
    [
      ( "--max-tokens",
        Arg.Int (fun value -> max_tokens := Some value),
        "N maximum tokens, including EOF (required for search)" );
      ( "--min-tokens",
        Arg.Set_int min_tokens,
        "N minimum tokens for reported witnesses, including the prefix and EOF \
         (default 0)" );
      ( "--prefix-tokens",
        Arg.String (fun value -> prefix_tokens := Automaton.words value),
        "TOKENS consume a space-separated token prefix before searching" );
      ( "--nodes-per-depth",
        Arg.Int (fun value -> nodes_per_depth := Some value),
        "N queued frontiers to expand at each depth before descending; omitted \
         for breadth-first search" );
      ( "--timeout",
        Arg.Float (fun value -> timeout := Some value),
        "SECONDS time limit per search phase (required for search)" );
      ( "--max-witnesses",
        Arg.Int (fun value -> max_witnesses := Some value),
        "N ambiguity families to report (required for search)" );
      ( "--check-tokens",
        Arg.String (fun value -> check_tokens := Automaton.words value),
        "TOKENS check one space-separated token sequence" );
      ( "--dump-terminal-classes",
        Arg.Set dump_classes,
        " list the terminal equivalence classes the search collapses, then exit" );
    ]
  in
  Arg.parse specs (fun value -> grammar := value) usage;
  if !grammar = "" then begin
    Arg.usage specs usage;
    exit 2
  end;
  {
    grammar = !grammar;
    max_tokens = !max_tokens;
    min_tokens = !min_tokens;
    prefix_tokens = !prefix_tokens;
    nodes_per_depth = !nodes_per_depth;
    timeout = !timeout;
    max_witnesses = !max_witnesses;
    check_tokens = !check_tokens;
    dump_classes = !dump_classes;
  }

(* Everything a run needs to know before it builds anything, read and checked
   in one place so a bad setting is refused at the start rather than at the
   moment the run first depends on it. *)
type settings = {
  menhir : string;
  memory_mb : int;
  max_frontier_ratio : float;
  jobs : int;
  (* The bounds a search requires and the other subcommands do not: maximum
     tokens, timeout, and how many witness families to report. *)
  search_limits : (int * float * int) option;
}

let settings (o : options) =
  let menhir = environment "AMBIGUITY_MENHIR" in
  let memory_mb = environment_int "AMBIGUITY_MEMORY_MB" in
  let max_frontier_ratio =
    environment_float "AMBIGUITY_MAX_FRONTIER_RATIO"
  in
  let jobs = environment_int "AMBIGUITY_JOBS" in
  (* Read here with the rest of the settings so a malformed cadence is refused
     before the run starts, rather than at whatever moment the first progress
     line happened to fall due. *)
  ignore (Lazy.force Output.progress_interval : float);
  Option.iter
    (fun value ->
      if value < 0 then invalid_arg "--max-tokens must be at least 0")
    o.max_tokens;
  if o.min_tokens < 0 then invalid_arg "--min-tokens must be at least 0";
  Option.iter
    (fun value ->
      if value < 1 then invalid_arg "--nodes-per-depth must be at least 1")
    o.nodes_per_depth;
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
    o.timeout;
  if jobs < 1 then invalid_arg "AMBIGUITY_JOBS must be at least 1";
  Option.iter
    (fun value ->
      if value < 1 then invalid_arg "--max-witnesses must be at least 1")
    o.max_witnesses;
  let search_limits =
    if o.check_tokens <> [] || o.dump_classes then None
    else
      let required name = function
        | Some value -> value
        | None -> invalid_arg (name ^ " is required for search")
      in
      Some
        ( required "--max-tokens" o.max_tokens,
          required "--timeout" o.timeout,
          required "--max-witnesses" o.max_witnesses )
  in
  { menhir; memory_mb; max_frontier_ratio; jobs; search_limits }
