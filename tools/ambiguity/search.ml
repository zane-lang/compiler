(* Whether a concrete ambiguous sentence exists within the requested bound.

   The bounded side of the engine: one unified breadth- or depth-limited walk
   over concrete frontiers, the caches that keep it from re-exploring, and the
   partitioning that spreads it over forked workers. *)

open Output
open Automaton
open Recognizer
open Abstraction
open Prover

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
         Option.value (Hashtbl.find_opt automaton.aliases token)
           ~default:("<" ^ token ^ ">"))
  |> String.concat " "

let conflict_profile engine tokens =
  let frontier = ref (IntMap.singleton engine.stacks.root.id 1) in
  let shifted = ref [] in
  let conflicts = ref ConflictSet.empty in
  let inspect token =
    let reduced = closure engine ~shifted:!shifted !frontier token in
    IntMap.iter
      (fun stack_id _ ->
        let stack = Stack_pool.find engine.stacks stack_id in
        let state = engine.automaton.states.(stack.state) in
        let reductions = reductions state token in
        if
          List.length reductions > 1
          || (reductions <> [] && Hashtbl.mem state.transitions token)
        then conflicts := ConflictSet.add (stack.state, token) !conflicts)
      reduced
  in
  List.iter
    (fun token ->
      inspect token;
      frontier := shift engine ~shifted:!shifted !frontier token;
      shifted := token :: !shifted)
    tokens;
  inspect "#";
  ConflictSet.elements !conflicts

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
  frontier : frontier;
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

  (* [context] is the validity model's reading of the tokens already shifted,
     and it has to be part of the key: a frontier no longer determines what
     happens next on its own. Two sentences can reach the same stacks with
     different tokens behind them -- `abort false ;` and `abort v() { } ;`
     leave the same chain of states, an [expr] entry either way -- and the
     statement reduction waiting at the next token is refused after the brace
     and taken after the name. Keyed on the frontier alone, whichever arrived
     first would stand for both, and the one that was still going anywhere
     would be the one dropped.

     Every other fact about the future is in the frontier. An LR state is
     reached by one symbol, so the stacks already say which token was shifted
     last; only whether a closer sits behind a terminator is not recoverable
     from them, and that is the bit this carries. *)
  let digest branched progress context frontier =
    let lane seed =
      IntMap.fold
        (fun stack_id count hash -> mix (mix hash stack_id) count)
        frontier
        (mix (mix (mix seed (Bool.to_int branched)) progress) context)
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
    read_lines "/proc/self/status"
    |> List.find_map (fun line ->
           if String.starts_with ~prefix:"VmRSS:" line then
             try Some (Scanf.sscanf line "VmRSS: %f kB" (fun kib -> kib *. 1024.))
             with _ -> None
           else None)
    |> Option.value ~default:(managed_heap_bytes ())
  with _ -> managed_heap_bytes ()

let unified_search engine initial ~max_tokens ~min_tokens ~nodes_per_depth
    ~timeout ~max_frontiers ~max_queue ~max_witnesses ~soft_heap_bytes
    ~hard_heap_bytes ~show_progress ~on_progress conflict_distance
    accept_distance =
  let deadline = Unix.gettimeofday () +. timeout in
  let buckets = Array.init (max_tokens + 1) (fun _ -> Queue.create ()) in
  let seen = Seen_cache.create max_frontiers in
  let queued = ref 0 in
  let dropped = ref false in
  let admit_new = ref true in
  let enqueue item =
    incr queued;
    Queue.add item buckets.(item.depth)
  in
  (* max_queue caps the number of queued items - the search reach. A full
     queue drops new discoveries (recorded so the result is reported as
     incomplete) instead of growing without bound; a dropped frontier can
     still be rediscovered once the queue drains, because only enqueued
     frontiers enter the dedup cache. max_frontiers is the independent dedup
     memory budget (see Seen_cache above): a smaller table simply prunes less. *)
  let add item =
    if item.depth <= max_tokens then
      if
        derivations item.frontier >= 2
        && accepted_count engine ~shifted:item.tokens_rev item.frontier >= 2
      then enqueue item
      else if not !admit_new then dropped := true
      else
        (* Before [min_tokens], revisiting the same parser frontier at a
           greater depth is useful rather than redundant: it can eventually
           produce a witness long enough to report. Once the minimum is met,
           the usual shortest-path deduplication applies. *)
        let progress = min item.depth min_tokens in
        let key =
          Seen_cache.digest item.branched progress
            (validity_context engine item.tokens_rev)
            item.frontier
        in
        match Seen_cache.find seen key with
        | Some depth when depth <= item.depth ->
            Seen_cache.refresh seen key depth
        | Some _ when !queued < max_queue ->
            Seen_cache.refresh seen key item.depth;
            enqueue item
        | None when !queued < max_queue ->
            Seen_cache.insert seen key item.depth;
            enqueue item
        | _ -> dropped := true
  in
  List.iter add initial;
  let explored = ref 0 in
  let deepest = ref 0 in
  let conflict_seeds = ref 0 in
  let witnesses = Hashtbl.create max_witnesses in
  let stopped = ref None in
  let current_depth = ref 0 in
  let expanded_at_depth = ref 0 in
  let last_depth = ref 0 in
  let last_progress = ref 0. in
  let interval = Lazy.force progress_interval in
  let emit_progress force =
    let now = Unix.gettimeofday () in
    if show_progress && (force || now -. !last_progress >= interval) then begin
      last_progress := now;
      on_progress
        {
          depth = !last_depth;
          ambiguities =
            Hashtbl.fold
              (fun profile tokens result ->
                (profile, List.length tokens) :: result)
              witnesses [];
          explored = !explored;
          unique = seen.Seen_cache.inserted;
          rss_bytes = resident_memory_bytes ();
        }
    end
  in
  (* The stack pool and closure cache also grow with the search; sweep them
     against the live queue on a geometric schedule so total memory stays
     proportional to the queue itself (the live set marked below), whose size
     is bounded by max_queue. *)
  let stack_budget = max 65_536 (4 * max_queue) in
  let compact_floor = ref stack_budget in
  let mark_live mark =
    Array.iter
      (fun bucket ->
        Queue.iter
          (fun item ->
            IntMap.iter
              (fun stack_id _ ->
                mark (Stack_pool.find engine.stacks stack_id))
              item.frontier)
          bucket)
      buckets
  in
  let compact_search_state () =
    Stack_pool.compact engine.stacks mark_live;
    Hashtbl.reset engine.closure_cache;
    compact_floor := max stack_budget (2 * Stack_pool.size engine.stacks)
  in
  let maybe_compact_stacks () =
    if Stack_pool.size engine.stacks > !compact_floor then begin
      compact_search_state ()
    end
  in
  (* Static entry-size estimates determine the shape of the search, but the
     heap guard is what keeps the process inside the requested machine budget.
     Near the soft limit, compact once and keep using the reclaimed space.  At
     the hard limit, pause admission and drain queued work until compaction
     brings the heap below the resume watermark.  This hysteresis keeps memory
     near a plateau instead of repeatedly overshooting the budget. *)
  (* soft and hard are 80% and 90% of the worker share respectively. Resume at
     85% so pressure mode holds a narrow 85--90% plateau instead of producing
     a large sawtooth while the queue drains and refills. *)
  let resume_heap_bytes = 1.0625 *. soft_heap_bytes in
  let next_heap_check = ref soft_heap_bytes in
  let manage_memory () =
    let before = managed_heap_bytes () in
    if before >= !next_heap_check then begin
      Seen_cache.release_old seen;
      compact_search_state ();
      Gc.compact ();
      let after = managed_heap_bytes () in
      if after >= hard_heap_bytes then begin
        admit_new := false;
        dropped := true;
        next_heap_check := 0.
      end
      else begin
        if (not !admit_new) && after <= resume_heap_bytes then
          admit_new := true;
        next_heap_check :=
          if !admit_new then
            min hard_heap_bytes (max soft_heap_bytes (after *. 1.10))
          else 0.
      end
    end
  in
  (* A quota forms a depth wave: expand a bounded number of siblings, descend
     through their children, then return to the earliest unfinished siblings
     when no deeper bucket remains. Nothing is discarded, so repeated waves
     eventually cover the same frontiers as breadth-first search. *)
  let first_nonempty start =
    let depth = ref start in
    while !depth <= max_tokens && Queue.is_empty buckets.(!depth) do
      incr depth
    done;
    if !depth <= max_tokens then Some !depth else None
  in
  let next_bucket () =
    match nodes_per_depth with
    | None -> Option.get (first_nonempty 0)
    | Some limit ->
        let current_available =
          !current_depth <= max_tokens
          && not (Queue.is_empty buckets.(!current_depth))
        in
        if (not current_available) || !expanded_at_depth >= limit then begin
          let next =
            match first_nonempty (!current_depth + 1) with
            | Some depth -> depth
            | None -> Option.get (first_nonempty 0)
          in
          current_depth := next;
          expanded_at_depth := 0
        end;
        incr expanded_at_depth;
        !current_depth
  in
  while
    Hashtbl.length witnesses < max_witnesses
    && !queued > 0
    && Unix.gettimeofday () < deadline
  do
    let bucket = next_bucket () in
    if bucket >= 0 && bucket <= max_tokens then begin
      maybe_compact_stacks ();
      if !admit_new then begin
        if !explored mod 4_096 = 0 then manage_memory ()
      end
      else manage_memory ();
      let item = Queue.take buckets.(bucket) in
      decr queued;
      incr explored;
      last_depth := item.depth;
      deepest := max !deepest item.depth;
      if accepted_count engine ~shifted:item.tokens_rev item.frontier >= 2 then begin
        if item.depth >= min_tokens then begin
          let tokens = List.rev item.tokens_rev in
          let profile = conflict_profile engine tokens in
          if not (Hashtbl.mem witnesses profile) then
            Hashtbl.add witnesses profile tokens
        end
      end
      else if item.depth < max_tokens then
        StringSet.iter
          (fun token ->
            let next = shift engine ~shifted:item.tokens_rev item.frontier token in
            if not (IntMap.is_empty next) then begin
              let branched = item.branched || derivations next >= 2 in
              if branched && not item.branched then incr conflict_seeds;
              let distance =
                if branched then accept_distance else conflict_distance
              in
              let next_depth = item.depth + 1 in
              let lower = frontier_lower_bound engine distance next in
              if next_depth + lower <= max_tokens then
                add
                  {
                    tokens_rev = token :: item.tokens_rev;
                    depth = next_depth;
                    frontier = next;
                    branched;
                  }
            end)
          (class_representatives engine.automaton
             (possible_tokens engine item.frontier))
    end;
    emit_progress false
  done;
  emit_progress true;
  (* The deadline alone does not mean the deadline stopped anything. The loop
     also exits with a drained queue, and expanding the last frontier can carry
     the clock past the deadline on its way out - so a search that finished the
     whole token bound would be recorded as timed out, and reported as a
     curtailed run when it is the conclusive one. Only work still queued makes
     the deadline the reason. A dropped frontier keeps its own reason whatever
     the clock says: the bound was not covered, so the run is not exhaustive. *)
  if Hashtbl.length witnesses >= max_witnesses then
    stopped := Some "the witness limit was reached"
  else if !dropped then
    stopped := Some "the memory budget dropped part of the search space"
  else if !queued > 0 && Unix.gettimeofday () >= deadline then
    stopped := Some "the timeout was reached";
  ( {
      witnesses =
        Hashtbl.fold
          (fun profile tokens result -> (profile, tokens) :: result)
          witnesses [];
      explored = !explored;
      unique = seen.Seen_cache.inserted;
      deepest = !deepest;
      stopped = !stopped;
    },
    !conflict_seeds )

let initial_partitions engine jobs max_tokens initial =
  if jobs <= 1 || initial.depth = max_tokens then
    ( [| [ initial ] |],
      0,
      0,
      0 )
  else begin
    let split_depth = min 3 (max_tokens - initial.depth) in
    let current = ref [ initial ] in
    let explored = ref 0 in
    let unique = ref 1 in
    let conflict_seeds = ref 0 in
    for _ = 1 to split_depth do
      explored := !explored + List.length !current;
      let seen = Hashtbl.create 1024 in
      let next = ref [] in
      List.iter
        (fun item ->
          if accepted_count engine ~shifted:item.tokens_rev item.frontier >= 2 then
            next := item :: !next
          else
            StringSet.iter
              (fun token ->
                let frontier =
                  shift engine ~shifted:item.tokens_rev item.frontier token
                in
                if not (IntMap.is_empty frontier) then begin
                  let branched = item.branched || derivations frontier >= 2 in
                  if branched && not item.branched then incr conflict_seeds;
                  let item =
                    {
                      tokens_rev = token :: item.tokens_rev;
                      depth = item.depth + 1;
                      frontier;
                      branched;
                    }
                  in
                  (* The validity context belongs in this key for the same
                     reason it belongs in [Seen_cache.digest]: two prefixes
                     reaching the same stacks with different tokens behind
                     them part ways at the next statement reduction, so
                     collapsing them here would hand one worker a prefix
                     standing for a sibling it cannot reach. *)
                  let key =
                    ( branched,
                      validity_context engine item.tokens_rev,
                      signature frontier )
                  in
                  if not (Hashtbl.mem seen key) then begin
                    Hashtbl.add seen key ();
                    next := item :: !next
                  end
                end)
              (class_representatives engine.automaton
                 (possible_tokens engine item.frontier)))
        !current;
      unique := !unique + Hashtbl.length seen;
      current := !next
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
              Hashtbl.hash (item.branched, signature item.frontier) land max_int
            in
            let bucket = hash mod count in
            buckets.(bucket) <- item :: buckets.(bucket))
          items;
        match Array.to_list buckets |> List.filter (fun b -> b <> []) with
        | [] -> [| items |]
        | non_empty -> Array.of_list non_empty
      end
    in
    (buckets, !explored, !unique, !conflict_seeds)
  end

let parallel_unified_search engine initial ~jobs ~max_tokens ~min_tokens
    ~nodes_per_depth ~timeout ~max_frontiers ~max_queue ~max_witnesses
    ~soft_heap_bytes ~hard_heap_bytes conflict_distance accept_distance
    temporary =
  let started = Unix.gettimeofday () in
  let memory_budget =
    hard_heap_bytes /. 0.90 *. float_of_int (max 1 jobs)
  in
  let partitions, prefix_explored, prefix_unique, prefix_seeds =
    initial_partitions engine (max 1 jobs) max_tokens initial
  in
  let prefix_progress =
    {
      depth = initial.depth;
      ambiguities = [];
      explored = prefix_explored;
      unique = prefix_unique;
      rss_bytes = 0.;
    }
  in
  if Array.length partitions = 1 then
    let show progress =
      render_progress ~started ~max_tokens ~memory_budget
        [ (false, prefix_progress); (true, progress) ]
    in
    let outcome, seeds =
      unified_search engine partitions.(0) ~max_tokens ~min_tokens
        ~nodes_per_depth ~timeout ~max_frontiers ~max_queue ~max_witnesses
        ~soft_heap_bytes ~hard_heap_bytes
        ~show_progress:(progress_is_visible ())
        ~on_progress:show conflict_distance accept_distance
    in
    clear_progress ();
    ( {
        outcome with
        explored = prefix_explored + outcome.explored;
        unique = prefix_unique + outcome.unique;
      },
      prefix_seeds + seeds )
  else begin
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
        let progress_path =
          Filename.concat temporary (Printf.sprintf "progress-%d" index)
        in
        match Unix.fork () with
        | 0 ->
            let report progress =
              if progress_is_visible () then
                write_progress progress_path progress
            in
            let result =
              unified_search engine initial ~max_tokens ~min_tokens
                ~nodes_per_depth ~timeout ~max_frontiers ~max_queue
                ~max_witnesses ~soft_heap_bytes ~hard_heap_bytes
                ~show_progress:(progress_is_visible ()) ~on_progress:report
                conflict_distance accept_distance
            in
            let channel = open_out_bin output in
            Marshal.to_channel channel result [];
            close_out channel;
            exit 0
        | pid -> children := (pid, output, progress_path) :: !children)
      partitions;
    (* Pids that have been forked but not yet reaped. A worker failure aborts
       the whole search, and without this the siblings would keep running as
       orphans, still burning the memory budget the coordinator just gave up
       on. *)
    let live = Hashtbl.create (Array.length partitions) in
    List.iter (fun (pid, _, _) -> Hashtbl.replace live pid ()) !children;
    let rec reap pid =
      match Unix.waitpid [] pid with
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap pid
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
    in
    let terminate_live () =
      let pids = Hashtbl.fold (fun pid () acc -> pid :: acc) live [] in
      List.iter
        (fun pid ->
          try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ())
        pids;
      List.iter
        (fun pid ->
          reap pid;
          Hashtbl.remove live pid)
        pids
    in
    let latest = Hashtbl.create (Array.length partitions) in
    let worker_result pid output status =
      match status with
      | Unix.WEXITED 0 ->
          let channel = open_in_bin output in
          Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
              (Marshal.from_channel channel : outcome * int))
      | Unix.WEXITED code ->
          failwith
            (Printf.sprintf "ambiguity-search worker %d exited with status %d"
               pid code)
      | Unix.WSIGNALED signal ->
          failwith
            (Printf.sprintf "ambiguity-search worker %d was killed by signal %d"
               pid signal)
      | Unix.WSTOPPED signal ->
          failwith
            (Printf.sprintf "ambiguity-search worker %d stopped on signal %d"
               pid signal)
    in
    let rec collect pending outcomes =
      List.iter
        (fun (pid, _, progress_path) ->
          Option.iter
            (fun progress -> Hashtbl.replace latest pid progress)
            (read_progress progress_path))
        pending;
      let active = Hashtbl.create (List.length pending) in
      List.iter (fun (pid, _, _) -> Hashtbl.replace active pid ()) pending;
      let entries =
        (false, prefix_progress)
        :: Hashtbl.fold
             (fun pid progress result ->
               (Hashtbl.mem active pid, progress) :: result)
             latest []
      in
      render_progress ~started ~max_tokens ~memory_budget entries;
      match pending with
      | [] -> List.rev outcomes
      | _ ->
          let remaining = ref [] in
          let completed = ref [] in
          List.iter
            (fun ((pid, output, progress_path) as child) ->
              let waited, status =
                try Unix.waitpid [ Unix.WNOHANG ] pid
                with Unix.Unix_error (Unix.EINTR, _, _) ->
                  (0, Unix.WEXITED 0)
              in
              if waited = 0 then remaining := child :: !remaining
              else begin
                Hashtbl.remove live pid;
                let ((outcome, _) as result) =
                  worker_result pid output status
                in
                let final_progress =
                  Option.value (read_progress progress_path)
                    ~default:
                      {
                        depth = outcome.deepest;
                        ambiguities =
                          List.map
                            (fun (profile, tokens) ->
                              (profile, List.length tokens))
                            outcome.witnesses;
                        explored = outcome.explored;
                        unique = outcome.unique;
                        rss_bytes = 0.;
                      }
                in
                Hashtbl.replace latest pid
                  { final_progress with rss_bytes = 0. };
                completed := result :: !completed
              end)
            pending;
          if !completed = [] then
            ignore (Unix.select [] [] [] 0.1);
          collect (List.rev !remaining) (List.rev_append !completed outcomes)
    in
    let outcomes =
      try collect !children []
      with exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        terminate_live ();
        clear_progress ();
        Printexc.raise_with_backtrace exn backtrace
    in
    clear_progress ();
    let outcome, seeds = List.fold_left
      (fun (combined, seeds) (outcome, worker_seeds) ->
        ( {
            witnesses = outcome.witnesses @ combined.witnesses;
            explored = combined.explored + outcome.explored;
            unique = combined.unique + outcome.unique;
            deepest = max combined.deepest outcome.deepest;
            stopped =
              (match (combined.stopped, outcome.stopped) with
              | None, None -> None
              | _ -> Some "one or more workers reached a search limit");
          },
          seeds + worker_seeds ))
      ( { witnesses = []; explored = 0; unique = 0; deepest = 0; stopped = None },
        0 )
      outcomes
    in
    ( {
        outcome with
        witnesses = merge_witnesses max_witnesses [ outcome.witnesses ];
        explored = prefix_explored + outcome.explored;
        unique = prefix_unique + outcome.unique;
      },
      prefix_seeds + seeds )
  end
