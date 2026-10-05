(* Whether a concrete ambiguous sentence exists within the requested bound.

   The bounded side of the engine: one unified breadth- or depth-limited walk
   over concrete frontiers, the caches that keep it from re-exploring, and the
   partitioning that spreads it over forked workers. *)

type outcome = {
  witnesses : ((int * string) list * string list) list;
  explored : int;
  unique : int;
  deepest : int;
  stopped : string option;
}

let () = Random.self_init ()

let rec temporary_directory () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "zane-ambiguity-%d-%08x" (Unix.getpid ()) (Random.bits ()))
  in
  try
    Unix.mkdir path 0o700;
    path
  with Unix.Unix_error (Unix.EEXIST, _, _) -> temporary_directory ()

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  end
  else Sys.remove path

let render automaton tokens =
  tokens
  |> List.filter (fun token -> token <> "EOF")
  |> List.map (fun token ->
         Option.value (Hashtbl.find_opt automaton.Automaton.aliases token)
           ~default:("<" ^ token ^ ">"))
  |> String.concat " "

let conflict_profile engine tokens =
  let frontier = ref (Automaton.IntMap.singleton engine.Recognizer.stacks.root.id 1) in
  let conflicts = ref Automaton.ConflictSet.empty in
  let inspect token =
    let reduced = Recognizer.closure engine !frontier token in
    Automaton.IntMap.iter
      (fun stack_id _ ->
        let stack = Stack_pool.find engine.stacks stack_id in
        let state = engine.automaton.states.(stack.state) in
        let reductions = Recognizer.reductions state token in
        if
          List.length reductions > 1
          || (reductions <> [] && Hashtbl.mem state.transitions token)
        then conflicts := Automaton.ConflictSet.add (stack.state, token) !conflicts)
      reduced
  in
  List.iter
    (fun token ->
      inspect token;
      frontier := Recognizer.shift engine !frontier token)
    tokens;
  inspect "#";
  Automaton.ConflictSet.elements !conflicts

let compare_witness (_, left) (_, right) =
  match compare (List.length left) (List.length right) with
  | 0 -> compare left right
  | order -> order

let merge_witnesses limit lists =
  let by_profile = Hashtbl.create 128 in
  List.iter
    (fun (profile, tokens) ->
      match Hashtbl.find_opt by_profile profile with
      | Some previous when List.length previous <= List.length tokens -> ()
      | _ -> Hashtbl.replace by_profile profile tokens)
    (List.concat lists);
  Hashtbl.fold (fun profile tokens result -> (profile, tokens) :: result)
    by_profile []
  |> List.sort compare_witness
  |> List.to_seq |> Seq.take limit |> List.of_seq

type directed_item = {
  tokens_rev : string list;
  depth : int;
  frontier : Recognizer.frontier;
  branched : bool;
}

(* Bounded two-generation dedup cache over 124-bit frontier digests. Inserts
   and hits go to the young generation; when it fills, the old generation is
   dropped and the generations flip, so recently touched entries survive and
   stale ones are forgotten. Deduplication is pruning, not correctness - a
   forgotten entry costs re-exploration, never a missed witness - so a full
   cache degrades the search instead of stopping it or exhausting memory. *)
module Seen_cache = struct
  type digest = int * int

  (* The mix constants (and the lane seeds below) need OCaml's 63-bit native
     int, so this tool requires a 64-bit platform; Int64 would box every
     operation on this hot path. *)
  let mix hash value =
    let hash = hash + value in
    let hash = (hash lxor (hash lsr 30)) * 0x3F58476D1CE4E5B9 in
    let hash = (hash lxor (hash lsr 27)) * 0x14D049BB133111EB in
    hash lxor (hash lsr 31)

  (* Two independently seeded 62-bit lanes make colliding distinct frontiers
     astronomically unlikely even across billions of entries. A collision
     could only skip a frontier wrongly, never produce a false witness. *)
  let digest branched progress frontier =
    let lane seed =
      Automaton.IntMap.fold
        (fun stack_id count hash -> mix (mix hash stack_id) count)
        frontier
        (mix (mix seed (Bool.to_int branched)) progress)
    in
    (lane 0x2545F4914F6CDD1D, lane 0x27220A95FE4D1D65)

  type t = {
    generation_capacity : int;
    mutable young : (digest, int) Hashtbl.t;
    mutable old : (digest, int) Hashtbl.t;
    mutable inserted : int;
  }

  (* [capacity] is the total number of entries retained across both
     generations.  Keeping that meaning literal is important: callers use it
     to divide a fixed memory budget between the queue and deduplication. *)
  let create capacity =
    {
      generation_capacity = max 1 (capacity / 2);
      young = Hashtbl.create 4_096;
      old = Hashtbl.create 4_096;
      inserted = 0;
    }

  let find cache key =
    match Hashtbl.find_opt cache.young key with
    | Some _ as found -> found
    | None -> Hashtbl.find_opt cache.old key

  let refresh cache key depth =
    if
      (not (Hashtbl.mem cache.young key))
      && Hashtbl.length cache.young >= cache.generation_capacity
    then begin
      cache.old <- cache.young;
      cache.young <- Hashtbl.create 4_096
    end;
    Hashtbl.replace cache.young key depth

  let insert cache key depth =
    cache.inserted <- cache.inserted + 1;
    refresh cache key depth

  (* Deduplication is an optimization, so the older generation is the safest
     memory to reclaim under pressure: forgetting it can cause re-exploration
     but cannot hide a witness. *)
  let release_old cache = cache.old <- Hashtbl.create 4_096
end

let managed_heap_bytes () =
  let stats = Gc.quick_stat () in
  float_of_int stats.heap_words *. float_of_int (Sys.word_size / 8)

let resident_memory_bytes () =
  try
    Automaton.read_lines "/proc/self/status"
    |> List.find_map (fun line ->
           if String.starts_with ~prefix:"VmRSS:" line then
             try Some (Scanf.sscanf line "VmRSS: %f kB" (fun kib -> kib *. 1024.))
             with _ -> None
           else None)
    |> Option.value ~default:(managed_heap_bytes ())
  with _ -> managed_heap_bytes ()

(* One run of [unified_search]: its bounds, the queued frontiers by depth,
   what it has found, and the memory and scheduling state the phases below
   share. *)
type search = {
  engine : Recognizer.engine;
  max_tokens : int;
  min_tokens : int;
  nodes_per_depth : int option;
  max_queue : int;
  max_witnesses : int;
  soft_heap_bytes : float;
  hard_heap_bytes : float;
  (* soft and hard are 80% and 90% of the worker share respectively. Resume
     at 85% so pressure mode holds a narrow 85--90% plateau instead of
     producing a large sawtooth while the queue drains and refills. *)
  resume_heap_bytes : float;
  deadline : float;
  conflict_distance : int array;
  accept_distance : int array;
  buckets : directed_item Queue.t array;
  seen : Seen_cache.t;
  mutable queued : int;
  mutable dropped : bool;
  mutable admit_new : bool;
  mutable expanded : int;
  mutable deepest_depth : int;
  mutable conflict_seeds : int;
  found : ((int * string) list, string list) Hashtbl.t;
  mutable current_depth : int;
  mutable expanded_at_depth : int;
  mutable last_depth : int;
  mutable last_progress : float;
  (* The stack pool and closure cache also grow with the search; they are
     swept against the live queue on a geometric schedule so total memory
     stays proportional to the queue itself, whose size is bounded by
     max_queue. *)
  stack_budget : int;
  mutable compact_floor : int;
  mutable next_heap_check : float;
}

(* max_queue caps the number of queued items - the search reach. A full
   queue drops new discoveries (recorded so the result is reported as
   incomplete) instead of growing without bound; a dropped frontier can still
   be rediscovered once the queue drains, because only enqueued frontiers
   enter the dedup cache. max_frontiers is the independent dedup memory
   budget (see Seen_cache above): a smaller table simply prunes less. *)
let admit s item =
  let enqueue item =
    s.queued <- s.queued + 1;
    Queue.add item s.buckets.(item.depth)
  in
  if item.depth <= s.max_tokens then
    if not s.admit_new then s.dropped <- true
    else
      (* Before [min_tokens], revisiting the same parser frontier at a
         greater depth is useful rather than redundant: it can eventually
         produce a witness long enough to report. Once the minimum is met,
         the usual shortest-path deduplication applies. Accepted prefixes use
         this same admission path, so they obey the queue and memory limits
         instead of bypassing them. *)
      let progress = min item.depth s.min_tokens in
      let key = Seen_cache.digest item.branched progress item.frontier in
      match Seen_cache.find s.seen key with
      | Some depth when depth <= item.depth -> Seen_cache.refresh s.seen key depth
      | Some _ when s.queued < s.max_queue ->
          Seen_cache.refresh s.seen key item.depth;
          enqueue item
      | None when s.queued < s.max_queue ->
          Seen_cache.insert s.seen key item.depth;
          enqueue item
      | _ -> s.dropped <- true

let compact_search_state s =
  let mark_live mark =
    Array.iter
      (fun bucket ->
        Queue.iter
          (fun item ->
            Automaton.IntMap.iter
              (fun stack_id _ -> mark (Stack_pool.find s.engine.Recognizer.stacks stack_id))
              item.frontier)
          bucket)
      s.buckets
  in
  Stack_pool.compact s.engine.stacks mark_live;
  Hashtbl.reset s.engine.closure_cache;
  s.compact_floor <- max s.stack_budget (2 * Stack_pool.size s.engine.stacks)

let maybe_compact_stacks s =
  if Stack_pool.size s.engine.stacks > s.compact_floor then compact_search_state s

(* Static entry-size estimates determine the shape of the search, but the
   heap guard is what keeps the process inside the requested machine budget.
   Near the soft limit, compact once and keep using the reclaimed space. At
   the hard limit, pause admission and drain queued work until compaction
   brings the heap below the resume watermark. This hysteresis keeps memory
   near a plateau instead of repeatedly overshooting the budget. *)
let manage_memory s =
  let before = managed_heap_bytes () in
  if before >= s.next_heap_check then begin
    Seen_cache.release_old s.seen;
    compact_search_state s;
    Gc.compact ();
    let after = managed_heap_bytes () in
    if after >= s.hard_heap_bytes then begin
      s.admit_new <- false;
      s.dropped <- true;
      s.next_heap_check <- 0.
    end
    else begin
      if (not s.admit_new) && after <= s.resume_heap_bytes then s.admit_new <- true;
      s.next_heap_check <-
        (if s.admit_new then min s.hard_heap_bytes (max s.soft_heap_bytes (after *. 1.10))
         else 0.)
    end
  end

(* A quota forms a depth wave: expand a bounded number of siblings, descend
   through their children, then return to the earliest unfinished siblings
   when no deeper bucket remains. Nothing is discarded, so repeated waves
   eventually cover the same frontiers as breadth-first search. *)
let next_bucket s =
  let first_nonempty start =
    let depth = ref start in
    while !depth <= s.max_tokens && Queue.is_empty s.buckets.(!depth) do
      incr depth
    done;
    if !depth <= s.max_tokens then Some !depth else None
  in
  match s.nodes_per_depth with
  | None -> Option.get (first_nonempty 0)
  | Some limit ->
      let current_available =
        s.current_depth <= s.max_tokens && not (Queue.is_empty s.buckets.(s.current_depth))
      in
      if (not current_available) || s.expanded_at_depth >= limit then begin
        let next =
          match first_nonempty (s.current_depth + 1) with
          | Some depth -> depth
          | None -> Option.get (first_nonempty 0)
        in
        s.current_depth <- next;
        s.expanded_at_depth <- 0
      end;
      s.expanded_at_depth <- s.expanded_at_depth + 1;
      s.current_depth

(* One frontier taken from the queue: recorded as a witness when two
   derivations accept it, and its successors admitted. *)
let expand s item =
  s.expanded <- s.expanded + 1;
  s.last_depth <- item.depth;
  s.deepest_depth <- max s.deepest_depth item.depth;
  let engine = s.engine in
  let accepting = Recognizer.accepted_count engine item.frontier >= 2 in
  if accepting && item.depth >= s.min_tokens then begin
    let tokens = List.rev item.tokens_rev in
    let profile = conflict_profile engine tokens in
    if not (Hashtbl.mem s.found profile) then Hashtbl.add s.found profile tokens
  end;
  (* An accepted prefix below [min_tokens] is not reportable yet. Keep
     expanding it so the lower bound cannot hide a longer witness. *)
  if item.depth < s.max_tokens && ((not accepting) || item.depth < s.min_tokens) then
    Automaton.StringSet.iter
      (fun token ->
        let next = Recognizer.shift engine item.frontier token in
        if not (Automaton.IntMap.is_empty next) then begin
          let branched = item.branched || Recognizer.derivations next >= 2 in
          if branched && not item.branched then s.conflict_seeds <- s.conflict_seeds + 1;
          let distance = if branched then s.accept_distance else s.conflict_distance in
          let next_depth = item.depth + 1 in
          let lower = Recognizer.frontier_lower_bound engine distance next in
          if next_depth + lower <= s.max_tokens then
            admit s { tokens_rev = token :: item.tokens_rev; depth = next_depth; frontier = next; branched }
        end)
      (Automaton.class_representatives engine.automaton
         (Recognizer.possible_tokens engine item.frontier))

(* The deadline alone does not mean the deadline stopped anything. The loop
   also exits with a drained queue, and expanding the last frontier can carry
   the clock past the deadline on its way out - so a search that finished the
   whole token bound would be recorded as timed out, and reported as a
   curtailed run when it is the conclusive one. Only work still queued makes
   the deadline the reason. A dropped frontier keeps its own reason whatever
   the clock says: the bound was not covered, so the run is not exhaustive. *)
let stop_reason s =
  if Hashtbl.length s.found >= s.max_witnesses then Some "the witness limit was reached"
  else if s.dropped then Some "the memory budget dropped part of the search space"
  else if s.queued > 0 && Unix.gettimeofday () >= s.deadline then Some "the timeout was reached"
  else None

let unified_search engine initial ~max_tokens ~min_tokens ~nodes_per_depth
    ~timeout ~max_frontiers ~max_queue ~max_witnesses ~soft_heap_bytes
    ~hard_heap_bytes ~show_progress ~on_progress conflict_distance
    accept_distance =
  let stack_budget = max 65_536 (4 * max_queue) in
  let s =
    {
      engine;
      max_tokens;
      min_tokens;
      nodes_per_depth;
      max_queue;
      max_witnesses;
      soft_heap_bytes;
      hard_heap_bytes;
      resume_heap_bytes = 1.0625 *. soft_heap_bytes;
      deadline = Unix.gettimeofday () +. timeout;
      conflict_distance;
      accept_distance;
      buckets = Array.init (max_tokens + 1) (fun _ -> Queue.create ());
      seen = Seen_cache.create max_frontiers;
      queued = 0;
      dropped = false;
      admit_new = true;
      expanded = 0;
      deepest_depth = 0;
      conflict_seeds = 0;
      found = Hashtbl.create max_witnesses;
      current_depth = 0;
      expanded_at_depth = 0;
      last_depth = 0;
      last_progress = 0.;
      stack_budget;
      compact_floor = stack_budget;
      next_heap_check = soft_heap_bytes;
    }
  in
  List.iter (admit s) initial;
  let interval = Lazy.force Output.progress_interval in
  let emit_progress force =
    let now = Unix.gettimeofday () in
    if show_progress && (force || now -. s.last_progress >= interval) then begin
      s.last_progress <- now;
      on_progress
        {
          depth = s.last_depth;
          Output.ambiguities =
            Hashtbl.fold
              (fun profile tokens result -> (profile, List.length tokens) :: result)
              s.found [];
          explored = s.expanded;
          unique = s.seen.Seen_cache.inserted;
          rss_bytes = resident_memory_bytes ();
        }
    end
  in
  while
    Hashtbl.length s.found < max_witnesses && s.queued > 0 && Unix.gettimeofday () < s.deadline
  do
    let bucket = next_bucket s in
    if bucket >= 0 && bucket <= max_tokens then begin
      maybe_compact_stacks s;
      if s.admit_new then begin
        if s.expanded mod 4_096 = 0 then manage_memory s
      end
      else manage_memory s;
      let item = Queue.take s.buckets.(bucket) in
      s.queued <- s.queued - 1;
      expand s item
    end;
    emit_progress false
  done;
  emit_progress true;
  ( {
      witnesses = Hashtbl.fold (fun profile tokens result -> (profile, tokens) :: result) s.found [];
      explored = s.expanded;
      unique = s.seen.Seen_cache.inserted;
      deepest = s.deepest_depth;
      stopped = stop_reason s;
    },
    s.conflict_seeds )

let initial_partitions engine jobs max_tokens min_tokens ~max_queue
    ~max_frontiers ~hard_heap_bytes ~deadline initial =
  if jobs <= 1 || initial.depth = max_tokens then
    ([| [ initial ] |], 0, 0, 0, None)
  else begin
    let split_depth = min 3 (max_tokens - initial.depth) in
    let current = ref [ initial ] in
    let explored = ref 0 in
    let unique = ref 1 in
    let conflict_seeds = ref 0 in
    let stopped = ref None in
    let stop reason =
      if !stopped = None then stopped := Some reason
    in
    let over_budget () =
      if Unix.gettimeofday () >= deadline then begin
        stop "the timeout was reached during initial partitioning";
        true
      end
      else if managed_heap_bytes () >= hard_heap_bytes then begin
        stop "the memory budget stopped initial partitioning";
        true
      end
      else false
    in
    let depth = ref 0 in
    while !depth < split_depth && !stopped = None && !current <> [] do
      let current_count = List.length !current in
      explored := !explored + current_count;
      let seen = Hashtbl.create (min 1_024 max_frontiers) in
      let next = ref [] in
      let next_count = ref 0 in
      List.iter
        (fun item ->
          if !stopped = None && over_budget () then ()
          else if Recognizer.accepted_count engine item.frontier >= 2
             && item.depth >= min_tokens then begin
            if current_count + !next_count >= max_queue then
              stop "the queue budget stopped initial partitioning"
            else begin
              next := item :: !next;
              incr next_count
            end
          end
          else
            Automaton.StringSet.iter
              (fun token ->
                if !stopped = None && not (over_budget ()) then begin
                  let frontier = Recognizer.shift engine item.frontier token in
                  if not (Automaton.IntMap.is_empty frontier) then begin
                    let branched =
                      item.branched || Recognizer.derivations frontier >= 2
                    in
                    if branched && not item.branched then incr conflict_seeds;
                    let item =
                      {
                        tokens_rev = token :: item.tokens_rev;
                        depth = item.depth + 1;
                        frontier;
                        branched;
                      }
                    in
                    let key = (branched, Recognizer.signature frontier) in
                    if not (Hashtbl.mem seen key) then begin
                      if current_count + !next_count >= max_queue then
                        stop "the queue budget stopped initial partitioning"
                      else if !unique >= max_frontiers then
                        stop "the frontier budget stopped initial partitioning"
                      else begin
                        Hashtbl.add seen key ();
                        incr unique;
                        incr next_count;
                        next := item :: !next
                      end
                    end
                  end
                end)
              (Automaton.class_representatives engine.automaton
                 (Recognizer.possible_tokens engine item.frontier)))
        !current;
      (* If a budget stops this level partway through, [next] is only a
         partial set of children. Keep the last complete level so workers
         still cover every frontier within the token bound. *)
      if !stopped = None then current := !next;
      incr depth
    done;
    (* Never hand back an empty bucket: [parallel_unified_search] forks one
       worker per partition, and a worker with no frontiers is a wasted process
       that only reports "no witnesses". Hashing can leave buckets empty either
       because there are fewer items than jobs or because several items collide,
       so cap the bucket count at the item count and drop any that stay empty. *)
    let items = !current in
    let buckets =
      if items = [] then [| [ initial ] |]
      else begin
        let count = min jobs (List.length items) in
        let buckets = Array.make count [] in
        List.iter
          (fun item ->
            let hash =
              Hashtbl.hash (item.branched, Recognizer.signature item.frontier) land max_int
            in
            let bucket = hash mod count in
            buckets.(bucket) <- item :: buckets.(bucket))
          items;
        match Array.to_list buckets |> List.filter (fun b -> b <> []) with
        | [] -> [| items |]
        | non_empty -> Array.of_list non_empty
      end
    in
    (buckets, !explored, !unique, !conflict_seeds, !stopped)
  end

(* Queue, frontier, and heap limits in [initial_partitions] cap only the
   partitioning prepass. When they fire, the complete previous level is handed
   to workers, which compact and enforce their own limits. The deadline is
   global, so a timeout during partitioning remains a result reason. *)
let partitioning_stop_reason = function
  | Some reason
    when String.starts_with ~prefix:"the queue budget" reason
         || String.starts_with ~prefix:"the frontier budget" reason
         || String.starts_with ~prefix:"the memory budget" reason ->
      None
  | stopped -> stopped

(* One worker per partition, each searching it in a child process that
   writes its outcome, and its progress, into [temporary]. *)
let fork_workers ~temporary ~search partitions =
  (* Do not make every child inherit avoidable garbage or an unnecessarily
     sparse major heap: after fork those pages become copy-on-write overhead. *)
  Gc.compact ();
  (* Anything still buffered would be replayed by every child's exit. *)
  flush stdout;
  flush stderr;
  let children = ref [] in
  Array.iteri
    (fun index initial ->
      let output = Filename.concat temporary (Printf.sprintf "worker-%d" index) in
      let progress_path = Filename.concat temporary (Printf.sprintf "progress-%d" index) in
      match Unix.fork () with
      | 0 ->
          let report progress =
            if Output.progress_is_visible () then Output.write_progress progress_path progress
          in
          let result =
            search ~show_progress:(Output.progress_is_visible ()) ~on_progress:report initial
          in
          let channel = open_out_bin output in
          Marshal.to_channel channel result [];
          close_out channel;
          exit 0
      | pid -> children := (pid, output, progress_path) :: !children)
    partitions;
  !children

(* What a worker that ended with [status] found. *)
let worker_result pid output status =
  match status with
  | Unix.WEXITED 0 ->
      let channel = open_in_bin output in
      Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
          (Marshal.from_channel channel : outcome * int))
  | Unix.WEXITED code ->
      failwith (Printf.sprintf "ambiguity-search worker %d exited with status %d" pid code)
  | Unix.WSIGNALED signal ->
      failwith (Printf.sprintf "ambiguity-search worker %d was killed by signal %d" pid signal)
  | Unix.WSTOPPED signal ->
      failwith (Printf.sprintf "ambiguity-search worker %d stopped on signal %d" pid signal)

(* Every worker's outcome, rendering their progress while they run. A worker
   failure aborts the whole search, and kills the workers still running so
   they do not go on burning the memory budget as orphans. *)
let collect_workers ~started ~max_tokens ~memory_budget ~prefix_progress children =
  (* Pids that have been forked but not yet reaped. *)
  let live = Hashtbl.create (List.length children) in
  List.iter (fun (pid, _, _) -> Hashtbl.replace live pid ()) children;
  let rec reap pid =
    match Unix.waitpid [] pid with
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap pid
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  let terminate_live () =
    let pids = Hashtbl.fold (fun pid () acc -> pid :: acc) live [] in
    List.iter (fun pid -> try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ()) pids;
    List.iter
      (fun pid ->
        reap pid;
        Hashtbl.remove live pid)
      pids
  in
  let latest = Hashtbl.create (List.length children) in
  let rec collect pending outcomes =
    List.iter
      (fun (pid, _, progress_path) ->
        Option.iter
          (fun progress -> Hashtbl.replace latest pid progress)
          (Output.read_progress progress_path))
      pending;
    let active = Hashtbl.create (List.length pending) in
    List.iter (fun (pid, _, _) -> Hashtbl.replace active pid ()) pending;
    let entries =
      (false, prefix_progress)
      :: Hashtbl.fold (fun pid progress result -> (Hashtbl.mem active pid, progress) :: result) latest []
    in
    Output.render_progress ~started ~max_tokens ~memory_budget entries;
    match pending with
    | [] -> List.rev outcomes
    | _ ->
        let remaining = ref [] in
        let completed = ref [] in
        List.iter
          (fun ((pid, output, progress_path) as child) ->
            let waited, status =
              try Unix.waitpid [ Unix.WNOHANG ] pid
              with Unix.Unix_error (Unix.EINTR, _, _) -> (0, Unix.WEXITED 0)
            in
            if waited = 0 then remaining := child :: !remaining
            else begin
              Hashtbl.remove live pid;
              let ((outcome, _) as result) = worker_result pid output status in
              let final_progress =
                Option.value (Output.read_progress progress_path)
                  ~default:
                    {
                      depth = outcome.deepest;
                      ambiguities =
                        List.map (fun (profile, tokens) -> (profile, List.length tokens)) outcome.witnesses;
                      explored = outcome.explored;
                      unique = outcome.unique;
                      rss_bytes = 0.;
                    }
              in
              Hashtbl.replace latest pid { final_progress with rss_bytes = 0. };
              completed := result :: !completed
            end)
          pending;
        if !completed = [] then ignore (Unix.select [] [] [] 0.1);
        collect (List.rev !remaining) (List.rev_append !completed outcomes)
  in
  try collect children []
  with exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    terminate_live ();
    Output.clear_progress ();
    Printexc.raise_with_backtrace exn backtrace

(* The workers' outcomes as one: every witness, the counts summed, and why
   the search ended, the witness limit first. *)
let combine_outcomes ~prefix_stopped outcomes =
  List.fold_left
    (fun (combined, seeds) (outcome, worker_seeds) ->
      ( {
          witnesses = outcome.witnesses @ combined.witnesses;
          explored = combined.explored + outcome.explored;
          unique = combined.unique + outcome.unique;
          deepest = max combined.deepest outcome.deepest;
          stopped =
            (match (combined.stopped, outcome.stopped, prefix_stopped) with
            | Some "the witness limit was reached", _, _ | _, Some "the witness limit was reached", _
              ->
                Some "the witness limit was reached"
            | _, _, Some reason -> Some reason
            | None, None, None -> None
            | _ -> Some "one or more workers reached a search limit");
        },
        seeds + worker_seeds ))
    ({ witnesses = []; explored = 0; unique = 0; deepest = 0; stopped = None }, 0)
    outcomes

let parallel_unified_search engine initial ~jobs ~max_tokens ~min_tokens
    ~nodes_per_depth ~timeout ~max_frontiers ~max_queue ~max_witnesses
    ~soft_heap_bytes ~hard_heap_bytes conflict_distance accept_distance
    temporary =
  let started = Unix.gettimeofday () in
  let memory_budget = hard_heap_bytes /. 0.90 *. float_of_int (max 1 jobs) in
  let deadline = started +. timeout in
  let partitions, prefix_explored, prefix_unique, prefix_seeds, prefix_stopped =
    initial_partitions engine (max 1 jobs) max_tokens min_tokens ~max_queue ~max_frontiers
      ~hard_heap_bytes ~deadline initial
  in
  let prefix_stopped = partitioning_stop_reason prefix_stopped in
  let remaining_timeout = max 0. (deadline -. Unix.gettimeofday ()) in
  let prefix_progress =
    {
      depth = initial.depth;
      Output.ambiguities = [];
      explored = prefix_explored;
      unique = prefix_unique;
      rss_bytes = 0.;
    }
  in
  let search ~show_progress ~on_progress partition =
    unified_search engine partition ~max_tokens ~min_tokens ~nodes_per_depth
      ~timeout:remaining_timeout ~max_frontiers ~max_queue ~max_witnesses ~soft_heap_bytes
      ~hard_heap_bytes ~show_progress ~on_progress conflict_distance accept_distance
  in
  if Array.length partitions = 1 then begin
    let show progress =
      Output.render_progress ~started ~max_tokens ~memory_budget
        [ (false, prefix_progress); (true, progress) ]
    in
    let outcome, seeds =
      search ~show_progress:(Output.progress_is_visible ()) ~on_progress:show partitions.(0)
    in
    Output.clear_progress ();
    ( {
        outcome with
        explored = prefix_explored + outcome.explored;
        unique = prefix_unique + outcome.unique;
        stopped =
          (match (prefix_stopped, outcome.stopped) with
          | Some _, Some reason when reason = "the witness limit was reached" -> outcome.stopped
          | Some _, _ -> prefix_stopped
          | None, _ -> outcome.stopped);
      },
      prefix_seeds + seeds )
  end
  else begin
    let children = fork_workers ~temporary ~search partitions in
    let outcomes = collect_workers ~started ~max_tokens ~memory_budget ~prefix_progress children in
    Output.clear_progress ();
    let outcome, seeds = combine_outcomes ~prefix_stopped outcomes in
    ( {
        outcome with
        witnesses = merge_witnesses max_witnesses [ outcome.witnesses ];
        explored = prefix_explored + outcome.explored;
        unique = prefix_unique + outcome.unique;
      },
      prefix_seeds + seeds )
  end
