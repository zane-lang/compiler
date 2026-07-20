(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol. *)

module StringSet = Set.Make (String)
module IntMap = Map.Make (Int)
module ConflictSet = Set.Make (struct
  type t = int * string
  let compare = compare
end)

type reduction = { lhs : string; width : int }

type state = {
  transitions : (string, int) Hashtbl.t;
  reductions : (string, reduction list) Hashtbl.t;
  mutable accepts : StringSet.t;
}

type automaton = {
  states : state array;
  terminals : StringSet.t;
  aliases : (string, string) Hashtbl.t;
}

let empty_state () =
  {
    transitions = Hashtbl.create 16;
    reductions = Hashtbl.create 16;
    accepts = StringSet.empty;
  }

let cap_add a b = min 2 (a + b)

let words_re = Str.regexp "[ \t]+"

let words text =
  if String.trim text = "" then []
  else Str.split words_re (String.trim text)

let read_lines path =
  let channel = open_in path in
  let rec loop result =
    match input_line channel with
    | line -> loop (line :: result)
    | exception End_of_file ->
        close_in channel;
        List.rev result
  in
  loop []

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      let length = in_channel_length channel in
      really_input_string channel length)

let strip_comments source =
  let length = String.length source in
  let buffer = Buffer.create length in
  let rec normal index =
    if index >= length then ()
    else if index + 1 < length && source.[index] = '(' && source.[index + 1] = '*'
    then ocaml_comment 1 (index + 2)
    else if index + 1 < length && source.[index] = '/' && source.[index + 1] = '*'
    then c_comment (index + 2)
    else begin
      Buffer.add_char buffer source.[index];
      normal (index + 1)
    end
  and ocaml_comment depth index =
    if index >= length then ()
    else if index + 1 < length && source.[index] = '(' && source.[index + 1] = '*'
    then ocaml_comment (depth + 1) (index + 2)
    else if index + 1 < length && source.[index] = '*' && source.[index + 1] = ')'
    then if depth = 1 then normal (index + 2) else ocaml_comment (depth - 1) (index + 2)
    else begin
      if source.[index] = '\n' then Buffer.add_char buffer '\n';
      ocaml_comment depth (index + 1)
    end
  and c_comment index =
    if index >= length then ()
    else if index + 1 < length && source.[index] = '*' && source.[index + 1] = '/'
    then normal (index + 2)
    else begin
      if source.[index] = '\n' then Buffer.add_char buffer '\n';
      c_comment (index + 1)
    end
  in
  normal 0;
  Buffer.contents buffer

let token_decl_re =
  Str.regexp "^[ \t]*%token\\([ \t]+<[^>]+>\\)?[ \t]+\\(.*\\)$"

let is_uppercase = function 'A' .. 'Z' -> true | _ -> false
let is_token_char = function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false

let parse_token_specs text add =
  let length = String.length text in
  let rec skip index =
    if index < length && not (is_uppercase text.[index]) then skip (index + 1)
    else index
  in
  let rec token_end index =
    if index < length && is_token_char text.[index] then token_end (index + 1)
    else index
  in
  let rec whitespace index =
    if index < length && (text.[index] = ' ' || text.[index] = '\t') then
      whitespace (index + 1)
    else index
  in
  let rec quoted_end escaped index =
    if index >= length then length
    else if escaped then quoted_end false (index + 1)
    else if text.[index] = '\\' then quoted_end true (index + 1)
    else if text.[index] = '"' then index
    else quoted_end false (index + 1)
  in
  let rec loop index =
    let start = skip index in
    if start < length then begin
      let finish = token_end start in
      let token = String.sub text start (finish - start) in
      let after = whitespace finish in
      if after < length && text.[after] = '"' then begin
        let quote_end = quoted_end false (after + 1) in
        let raw = String.sub text (after + 1) (quote_end - after - 1) in
        add token (Some raw);
        loop (min length (quote_end + 1))
      end
      else begin
        add token None;
        loop finish
      end
    end
  in
  loop 0

let parse_tokens grammar =
  let terminals = ref StringSet.empty in
  let aliases = Hashtbl.create 64 in
  let source = strip_comments (read_file grammar) in
  List.iter
    (fun line ->
      if Str.string_match token_decl_re line 0 then
        parse_token_specs (Str.matched_group 2 line) (fun token alias ->
            terminals := StringSet.add token !terminals;
            Option.iter
              (fun alias ->
                let alias = try Scanf.unescaped alias with _ -> alias in
                Hashtbl.replace aliases token alias)
              alias))
    (String.split_on_char '\n' source);
  (!terminals, aliases)

let quote = Filename.quote

let run command =
  match Sys.command command with
  | 0 -> true
  | _ -> false

let prepare_automaton ~menhir ~grammar ~directory =
  let expanded = Filename.concat directory "expanded.mly" in
  let preprocess_error = Filename.concat directory "preprocess.err" in
  let preprocess =
    Printf.sprintf "%s --only-preprocess-uu %s > %s 2> %s"
      (quote menhir) (quote grammar) (quote expanded) (quote preprocess_error)
  in
  if not (run preprocess) then begin
    List.iter prerr_endline (read_lines preprocess_error);
    failwith "Menhir failed to preprocess the grammar"
  end;
  let base = Filename.concat directory "automaton" in
  let build_error = Filename.concat directory "automaton.err" in
  let build =
    Printf.sprintf "%s --dump --base %s %s > /dev/null 2> %s"
      (quote menhir) (quote base) (quote expanded) (quote build_error)
  in
  ignore (run build);
  let automaton = base ^ ".automaton" in
  if not (Sys.file_exists automaton) then begin
    List.iter prerr_endline (read_lines build_error);
    failwith "Menhir did not produce an LR automaton"
  end;
  automaton

let state_re = Str.regexp "^State \\([0-9]+\\):$"
let transition_re =
  Str.regexp "^-- On \\([^ ]+\\) shift to state \\([0-9]+\\)$"
let lookahead_re = Str.regexp "^-- On \\(.+\\)$"
let reduction_re = Str.regexp "^--   reduce production \\(.+\\) ->\\(.*\\)$"
let accept_re = Str.regexp "^--   accept \\([^ ]+\\)$"

let parse_automaton path terminals aliases =
  let table = Hashtbl.create 1024 in
  let current = ref None in
  let lookaheads = ref [] in
  let get_state number =
    match Hashtbl.find_opt table number with
    | Some state -> state
    | None ->
        let state = empty_state () in
        Hashtbl.add table number state;
        state
  in
  List.iter
    (fun line ->
      if Str.string_match state_re line 0 then begin
        let number = int_of_string (Str.matched_group 1 line) in
        current := Some (get_state number);
        lookaheads := []
      end
      else
        match !current with
        | None -> ()
        | Some state ->
            if Str.string_match transition_re line 0 then begin
              let symbol = Str.matched_group 1 line in
              let target = int_of_string (Str.matched_group 2 line) in
              Hashtbl.replace state.transitions symbol target;
              lookaheads := []
            end
            else if Str.string_match lookahead_re line 0 then
              lookaheads := words (Str.matched_group 1 line)
            else if Str.string_match reduction_re line 0 then begin
              let lhs = String.trim (Str.matched_group 1 line) in
              let rhs = String.trim (Str.matched_group 2 line) in
              let reduction = { lhs; width = List.length (words rhs) } in
              List.iter
                (fun token ->
                  let previous =
                    Option.value (Hashtbl.find_opt state.reductions token)
                      ~default:[]
                  in
                  Hashtbl.replace state.reductions token
                    (reduction :: previous))
                !lookaheads
            end
            else if Str.string_match accept_re line 0 then
              List.iter
                (fun token ->
                  state.accepts <- StringSet.add token state.accepts)
                !lookaheads)
    (read_lines path);
  let maximum = Hashtbl.fold (fun number _ value -> max number value) table 0 in
  let states = Array.init (maximum + 1) (fun number -> get_state number) in
  { states; terminals; aliases }

module Stack_pool = struct
  type node = {
    id : int;
    state : int;
    parent : node option;
    depth : int;
  }

  type t = {
    by_edge : ((int * int), node) Hashtbl.t;
    by_id : (int, node) Hashtbl.t;
    mutable next_id : int;
    root : node;
  }

  let create () =
    let root = { id = 0; state = 0; parent = None; depth = 0 } in
    let by_id = Hashtbl.create 1_000_003 in
    Hashtbl.add by_id 0 root;
    {
      by_edge = Hashtbl.create 1_000_003;
      by_id;
      next_id = 1;
      root;
    }

  let find pool id = Hashtbl.find pool.by_id id

  let push pool parent state =
    let edge = (parent.id, state) in
    match Hashtbl.find_opt pool.by_edge edge with
    | Some node -> node
    | None ->
        let node =
          {
            id = pool.next_id;
            state;
            parent = Some parent;
            depth = parent.depth + 1;
          }
        in
        pool.next_id <- pool.next_id + 1;
        Hashtbl.add pool.by_edge edge node;
        Hashtbl.add pool.by_id node.id node;
        node

  let rec pop node count =
    if count = 0 then Some node
    else
      match node.parent with
      | None -> None
      | Some parent -> pop parent (count - 1)
end

type frontier = int IntMap.t
type signature = (int * int) list

let add_count stack_id count frontier =
  let old = Option.value (IntMap.find_opt stack_id frontier) ~default:0 in
  let updated = cap_add old count in
  (IntMap.add stack_id updated frontier, updated - old)

let signature frontier = IntMap.bindings frontier

let derivations frontier =
  IntMap.fold (fun _ count total -> cap_add total count) frontier 0

type engine = {
  automaton : automaton;
  stacks : Stack_pool.t;
  closure_cache : ((int * string), frontier) Hashtbl.t;
}

let reductions state token =
  Option.value (Hashtbl.find_opt state.reductions token) ~default:[]

let closure_one engine stack_id token =
  match Hashtbl.find_opt engine.closure_cache (stack_id, token) with
  | Some result -> result
  | None ->
      let closure = ref (IntMap.singleton stack_id 1) in
      let propagated = Hashtbl.create 16 in
      let queue = Queue.create () in
      Queue.add stack_id queue;
      while not (Queue.is_empty queue) do
        let current_id = Queue.take queue in
        let count = IntMap.find current_id !closure in
        let sent =
          Option.value (Hashtbl.find_opt propagated current_id) ~default:0
        in
        let available = count - sent in
        if available > 0 then begin
          Hashtbl.replace propagated current_id count;
          let current = Stack_pool.find engine.stacks current_id in
          let state = engine.automaton.states.(current.state) in
          List.iter
            (fun reduction ->
              match Stack_pool.pop current reduction.width with
              | None -> ()
              | Some base ->
                  (match
                     Hashtbl.find_opt
                       engine.automaton.states.(base.state).transitions
                       reduction.lhs
                   with
                  | None -> ()
                  | Some target ->
                      let reduced = Stack_pool.push engine.stacks base target in
                      let updated, delta =
                        add_count reduced.id available !closure
                      in
                      closure := updated;
                      if delta > 0 then Queue.add reduced.id queue))
            (reductions state token)
        end
      done;
      Hashtbl.add engine.closure_cache (stack_id, token) !closure;
      !closure

let closure engine frontier token =
  IntMap.fold
    (fun stack_id outer_count result ->
      IntMap.fold
        (fun reduced_id inner_count result ->
          fst
            (add_count reduced_id
               (min 2 (outer_count * inner_count))
               result))
        (closure_one engine stack_id token) result)
    frontier IntMap.empty

let shift engine frontier token =
  IntMap.fold
    (fun stack_id count result ->
      let stack = Stack_pool.find engine.stacks stack_id in
      match
        Hashtbl.find_opt engine.automaton.states.(stack.state).transitions token
      with
      | None -> result
      | Some target ->
          let shifted = Stack_pool.push engine.stacks stack target in
          fst (add_count shifted.id count result))
    (closure engine frontier token) IntMap.empty

let accepted_count engine frontier =
  IntMap.fold
    (fun stack_id count total ->
      let stack = Stack_pool.find engine.stacks stack_id in
      if
        StringSet.mem "#"
          engine.automaton.states.(stack.state).accepts
      then cap_add total count
      else total)
    (closure engine frontier "#") 0

let possible_tokens engine frontier =
  IntMap.fold
    (fun stack_id _ tokens ->
      let stack = Stack_pool.find engine.stacks stack_id in
      let state = engine.automaton.states.(stack.state) in
      let tokens =
        Hashtbl.fold
          (fun symbol _ tokens ->
            if StringSet.mem symbol engine.automaton.terminals then
              StringSet.add symbol tokens
            else tokens)
          state.transitions tokens
      in
      Hashtbl.fold
        (fun token _ tokens ->
          if token = "#" then tokens else StringSet.add token tokens)
        state.reductions tokens)
    frontier StringSet.empty

let conflict_states automaton =
  Array.mapi
    (fun _ state ->
      Hashtbl.fold
        (fun token reductions conflict ->
          conflict
          || List.length reductions > 1
          || Hashtbl.mem state.transitions token)
        state.reductions false)
    automaton.states

(* Build an optimistic state graph. Terminal shifts cost one token;
   nonterminal transitions and reductions cost zero. Reverse shortest paths on
   this graph are safe lower bounds, even though stack context is ignored. *)
let reverse_distances automaton targets =
  let count = Array.length automaton.states in
  let reverse = Array.make count [] in
  let add_edge source target cost =
    reverse.(target) <- (source, cost) :: reverse.(target)
  in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun symbol target ->
          let cost = if StringSet.mem symbol automaton.terminals then 1 else 0 in
          add_edge source target cost)
        state.transitions)
    automaton.states;
  let gotos = Hashtbl.create 128 in
  Array.iter
    (fun state ->
      Hashtbl.iter
        (fun symbol target ->
          if not (StringSet.mem symbol automaton.terminals) then
            let previous =
              Option.value (Hashtbl.find_opt gotos symbol) ~default:[]
            in
            Hashtbl.replace gotos symbol (target :: previous))
        state.transitions)
    automaton.states;
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun _ reductions ->
          List.iter
            (fun reduction ->
              List.iter (fun target -> add_edge source target 0)
                (Option.value (Hashtbl.find_opt gotos reduction.lhs) ~default:[]))
            reductions)
        state.reductions)
    automaton.states;
  let infinity = max_int / 4 in
  let distance = Array.make count infinity in
  let deque = Queue.create () in
  Array.iteri
    (fun state is_target ->
      if is_target then begin
        distance.(state) <- 0;
        Queue.add state deque
      end)
    targets;
  (* Repeated relaxation is sufficient here; zero/one weights and 590 states
     keep this construction negligible compared with the search. *)
  while not (Queue.is_empty deque) do
    let target = Queue.take deque in
    List.iter
      (fun (source, cost) ->
        let candidate = distance.(target) + cost in
        if candidate < distance.(source) then begin
          distance.(source) <- candidate;
          Queue.add source deque
        end)
      reverse.(target)
  done;
  distance

let frontier_lower_bound engine distances frontier =
  IntMap.fold
    (fun stack_id _ best ->
      let stack = Stack_pool.find engine.stacks stack_id in
      min best distances.(stack.state))
    frontier (max_int / 4)

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
  let conflicts = ref ConflictSet.empty in
  let inspect token =
    let reduced = closure engine !frontier token in
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
      frontier := shift engine !frontier token)
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

let unified_search engine initial ~max_tokens ~timeout ~max_frontiers
    ~max_witnesses conflict_distance accept_distance =
  let deadline = Unix.gettimeofday () +. timeout in
  let buckets = Array.init (max_tokens + 1) (fun _ -> Queue.create ()) in
  let seen_plain = Hashtbl.create 1_000_003 in
  let seen_branched = Hashtbl.create 1_000_003 in
  let unique_count () =
    Hashtbl.length seen_plain + Hashtbl.length seen_branched
  in
  let add item =
    if item.depth <= max_tokens then
      if derivations item.frontier >= 2 && accepted_count engine item.frontier >= 2
      then Queue.add item buckets.(item.depth)
      else
        let seen = if item.branched then seen_branched else seen_plain in
        let key = signature item.frontier in
        match Hashtbl.find_opt seen key with
        | Some depth when depth <= item.depth -> ()
        | _ when unique_count () < max_frontiers ->
            Hashtbl.replace seen key item.depth;
            Queue.add item buckets.(item.depth)
        | _ -> ()
  in
  List.iter add initial;
  let explored = ref 0 in
  let deepest = ref 0 in
  let conflict_seeds = ref 0 in
  let witnesses = Hashtbl.create max_witnesses in
  let stopped = ref None in
  let depth = ref 0 in
  while
    Hashtbl.length witnesses < max_witnesses
    && !depth <= max_tokens
    && !explored < max_frontiers
    && unique_count () < max_frontiers
    && Unix.gettimeofday () < deadline
  do
    if Queue.is_empty buckets.(!depth) then incr depth
    else begin
      let item = Queue.take buckets.(!depth) in
      incr explored;
      deepest := max !deepest item.depth;
      if accepted_count engine item.frontier >= 2 then begin
        let tokens = List.rev item.tokens_rev in
        let profile = conflict_profile engine tokens in
        if not (Hashtbl.mem witnesses profile) then
          Hashtbl.add witnesses profile tokens
      end
      else if item.depth < max_tokens then
        StringSet.iter
          (fun token ->
            let next = shift engine item.frontier token in
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
          (possible_tokens engine item.frontier)
    end
  done;
  if !explored >= max_frontiers || unique_count () >= max_frontiers then
      stopped := Some "the frontier limit was reached"
    else if Unix.gettimeofday () >= deadline then
      stopped := Some "the timeout was reached"
    else if Hashtbl.length witnesses >= max_witnesses then
      stopped := Some "the witness limit was reached";
  ( {
      witnesses =
        Hashtbl.fold
          (fun profile tokens result -> (profile, tokens) :: result)
          witnesses [];
      explored = !explored;
      unique = unique_count ();
      deepest = !deepest;
      stopped = !stopped;
    },
    !conflict_seeds )

let initial_partitions engine jobs max_tokens =
  let root = IntMap.singleton engine.stacks.root.id 1 in
  if jobs <= 1 || max_tokens = 0 then
    ( [| [ { tokens_rev = []; depth = 0; frontier = root; branched = false } ] |],
      0,
      0,
      0 )
  else begin
    let split_depth = min 3 max_tokens in
    let current = ref [ { tokens_rev = []; depth = 0; frontier = root; branched = false } ] in
    let explored = ref 0 in
    let unique = ref 1 in
    let conflict_seeds = ref 0 in
    for _ = 1 to split_depth do
      explored := !explored + List.length !current;
      let seen = Hashtbl.create 1024 in
      let next = ref [] in
      List.iter
        (fun item ->
          if accepted_count engine item.frontier >= 2 then
            next := item :: !next
          else
            StringSet.iter
              (fun token ->
                let frontier = shift engine item.frontier token in
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
                  let key = (branched, signature frontier) in
                  if not (Hashtbl.mem seen key) then begin
                    Hashtbl.add seen key ();
                    next := item :: !next
                  end
                end)
              (possible_tokens engine item.frontier))
        !current;
      unique := !unique + Hashtbl.length seen;
      current := !next
    done;
    let buckets = Array.make jobs [] in
    List.iter
      (fun item ->
        let hash = Hashtbl.hash (item.branched, signature item.frontier) land max_int in
        let bucket = hash mod jobs in
        buckets.(bucket) <- item :: buckets.(bucket))
      !current;
    (buckets, !explored, !unique, !conflict_seeds)
  end

let parallel_unified_search engine ~jobs ~max_tokens ~timeout ~max_frontiers
    ~max_witnesses conflict_distance accept_distance temporary =
  let partitions, prefix_explored, prefix_unique, prefix_seeds =
    initial_partitions engine (max 1 jobs) max_tokens
  in
  if Array.length partitions = 1 then
    let outcome, seeds =
      unified_search engine partitions.(0) ~max_tokens ~timeout ~max_frontiers
        ~max_witnesses conflict_distance accept_distance
    in
    ( {
        outcome with
        explored = prefix_explored + outcome.explored;
        unique = prefix_unique + outcome.unique;
      },
      prefix_seeds + seeds )
  else begin
    let children = ref [] in
    Array.iteri
      (fun index initial ->
        let output = Filename.concat temporary (Printf.sprintf "worker-%d" index) in
        match Unix.fork () with
        | 0 ->
            let result =
              unified_search engine initial ~max_tokens ~timeout ~max_frontiers
                ~max_witnesses conflict_distance accept_distance
            in
            let channel = open_out_bin output in
            Marshal.to_channel channel result [];
            close_out channel;
            exit 0
        | pid -> children := (pid, output) :: !children)
      partitions;
    let outcomes =
      List.map
        (fun (pid, output) ->
          match Unix.waitpid [] pid with
          | _, Unix.WEXITED 0 ->
              let channel = open_in_bin output in
              Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
                  (Marshal.from_channel channel : outcome * int))
          | _, Unix.WEXITED code ->
              failwith (Printf.sprintf "ambiguity-search worker %d exited with status %d" pid code)
          | _, Unix.WSIGNALED signal ->
              failwith (Printf.sprintf "ambiguity-search worker %d was killed by signal %d" pid signal)
          | _, Unix.WSTOPPED signal ->
              failwith (Printf.sprintf "ambiguity-search worker %d stopped on signal %d" pid signal))
        !children
    in
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

let grammar = ref ""
let menhir = ref "menhir"
let max_tokens = ref 20
let max_frontiers = ref 500_000
let timeout = ref 60.
let jobs = ref 1
let max_witnesses = ref 20
let check_tokens = ref []

let options =
  [
    ("--menhir", Arg.Set_string menhir, "PATH Menhir executable");
    ("--max-tokens", Arg.Set_int max_tokens, "N maximum tokens, including EOF");
    ("--max-frontiers", Arg.Set_int max_frontiers, "N search-state limit per worker");
    ("--timeout", Arg.Set_float timeout, "SECONDS time limit per search phase");
    ("--jobs", Arg.Set_int jobs, "N worker processes");
    ("--max-witnesses", Arg.Set_int max_witnesses, "N ambiguity families to report");
    ( "--check-tokens",
      Arg.String (fun value -> check_tokens := words value),
      "TOKENS check one space-separated token sequence" );
  ]

let main () =
  Arg.parse options (fun value -> grammar := value)
    "ambiguity_search [options] GRAMMAR";
  if !grammar = "" then begin
    Arg.usage options "ambiguity_search [options] GRAMMAR";
    exit 2
  end;
  if !max_tokens < 0 then invalid_arg "--max-tokens must be at least 0";
  if !max_frontiers < 1 then invalid_arg "--max-frontiers must be at least 1";
  if !timeout < 0. then invalid_arg "--timeout must be non-negative";
  if !jobs < 1 then invalid_arg "--jobs must be at least 1";
  if !max_witnesses < 1 then invalid_arg "--max-witnesses must be at least 1";
  let grammar_path = Unix.realpath !grammar in
  let temporary = temporary_directory () in
  Fun.protect
    ~finally:(fun () -> remove_tree temporary)
    (fun () ->
      let terminals, aliases = parse_tokens grammar_path in
      let automaton_path =
        prepare_automaton ~menhir:!menhir ~grammar:grammar_path
          ~directory:temporary
      in
      let automaton = parse_automaton automaton_path terminals aliases in
      let stacks = Stack_pool.create () in
      let engine =
        { automaton; stacks; closure_cache = Hashtbl.create 1_000_003 }
      in
      if !check_tokens <> [] then begin
        let frontier =
          List.fold_left (shift engine)
            (IntMap.singleton engine.stacks.root.id 1)
            !check_tokens
        in
        let count = accepted_count engine frontier in
        Printf.printf "Accepting derivations: %d\n" count;
        exit (if count >= 2 then 1 else 0)
      end;
      let conflicts = conflict_states automaton in
      let conflict_distance = reverse_distances automaton conflicts in
      let accept_targets =
        Array.map
          (fun state -> StringSet.mem "#" state.accepts)
          automaton.states
      in
      let accept_distance = reverse_distances automaton accept_targets in
      let outcome, conflict_seeds =
        parallel_unified_search engine ~jobs:!jobs ~max_tokens:!max_tokens
          ~timeout:!timeout ~max_frontiers:!max_frontiers
          ~max_witnesses:!max_witnesses conflict_distance accept_distance
          temporary
      in
      match outcome.witnesses with
      | [] ->
          (match outcome.stopped with
          | None ->
              Printf.printf
                "No complete ambiguity found through %d tokens after exploring %d frontiers (%d unique).\n"
                !max_tokens outcome.explored outcome.unique
          | Some reason ->
              Printf.printf
                "Search stopped at depth %d because %s; no complete ambiguity was found in %d explored frontiers (%d unique).\n"
                outcome.deepest reason outcome.explored outcome.unique);
          Printf.printf "This is a bounded result, not a proof of unambiguity.\n";
          exit 0
      | witnesses ->
          Printf.printf "Found %d complete ambiguity %s.\n"
            (List.length witnesses)
            (if List.length witnesses = 1 then "family" else "families");
          List.iteri
            (fun index (profile, witness) ->
              Printf.printf "\n%d. Tokens (%d): %s\n   Source: %s\n"
                (index + 1) (List.length witness) (String.concat " " witness)
                (render automaton witness);
              Printf.printf "   Conflict origins: %s\n"
                (profile
                |> List.map (fun (state, token) ->
                       Printf.sprintf "state %d on %s" state token)
                |> String.concat ", "))
            witnesses;
          Printf.printf "\n";
          Printf.printf "Explored %d frontiers (%d unique); %d conflict seeds.\n"
            outcome.explored outcome.unique conflict_seeds;
          Option.iter
            (fun reason ->
              Printf.printf "Search stopped because %s.\n" reason)
            outcome.stopped;
          exit 1)

let () =
  try main ()
  with
  | Failure message | Invalid_argument message | Sys_error message
  | Unix.Unix_error (_, _, message) ->
      prerr_endline ("error: " ^ message);
      exit 2
