(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol. *)

(* Everything this tool prints is written as it is produced, not at the end.

   A proof run is long -- an abstract phase that can hold the whole timeout,
   then a bounded search that can run for an hour -- and it is nearly always
   read through a pipe: `tools/ambiguity.py` folds stderr into stdout, streams
   both to the terminal, and copies every line into the saved report. On a pipe
   OCaml block-buffers stdout, so the survey, the retirements and the line
   announcing that concretization has started all sat in a 64 KiB buffer until
   the process exited, and the report file stayed empty for the whole run it
   was meant to document. Flushing on every write costs one syscall per line,
   on output no run produces much of. *)
let printf fmt =
  Printf.ksprintf
    (fun text ->
      print_string text;
      flush stdout)
    fmt

let eprintf fmt =
  Printf.ksprintf
    (fun text ->
      prerr_string text;
      flush stderr)
    fmt

(* How progress is shown, and how often.

   On a terminal it is one line rewritten in place several times a second.
   Everywhere else there is no cursor to move back to and the stream is usually
   being saved, so the same numbers go out as ordinary lines at a much slower
   cadence. Showing nothing at all off a terminal -- which is what this used to
   do -- is what made every wrapped run silent for its entire length: the
   wrapper that streams the engine's output line by line was the one guaranteed
   never to receive a line. AMBIGUITY_PROGRESS_SECONDS sets the cadence; zero
   or less turns progress off, for a caller that wants the verdict and nothing
   else. *)
let progress_on_terminal = Unix.isatty Unix.stderr

(* Read on first use rather than at module initialisation, so a malformed value
   is reported by the same handler that reports every other bad setting --
   "error: ..." and status 2 -- instead of an uncaught exception printed before
   [main] has begun. *)
let progress_interval =
  lazy
    (match Sys.getenv_opt "AMBIGUITY_PROGRESS_SECONDS" with
    | None | Some "" -> if progress_on_terminal then 0.2 else 10.
    | Some value -> (
        match float_of_string_opt value with
        (* [float_of_string_opt] accepts "nan" and "infinity", and neither is a
           cadence. Both would be taken for a setting and then silently show no
           progress at all: every comparison against nan is false, so it reads
           as switched off, and nothing is ever as old as infinity, so a run
           reports progress as enabled and then never prints a line.
           [classify_float] rather than [Float.is_finite] because it is in
           every version of the stdlib this builds under. *)
        | Some seconds when classify_float seconds <> FP_nan
                           && classify_float seconds <> FP_infinite ->
            seconds
        | _ ->
            invalid_arg "AMBIGUITY_PROGRESS_SECONDS must be a finite number"))

let progress_is_visible () = Lazy.force progress_interval > 0.

(* One clock across every phase, so that handing over from the abstract phase
   to the concretization search cannot produce two lines at once, and so a
   phase that ends quickly does not leave the next one waiting out an interval
   it never used. *)
let last_progress_render = ref 0.

let progress_due () =
  progress_is_visible ()
  && Unix.gettimeofday () -. !last_progress_render
     >= Lazy.force progress_interval

let show_progress_line text =
  if progress_is_visible () then begin
    last_progress_render := Unix.gettimeofday ();
    if progress_on_terminal then eprintf "\r\027[2K%s" text
    else eprintf "%s\n" text
  end

(* Only a terminal has a partial line to take back. Off one the progress lines
   are ordinary output and stay in the log, which is the point of them.

   Deliberately independent of the interval: this also runs from the toplevel
   error handler, and a malformed AMBIGUITY_PROGRESS_SECONDS is one of the
   errors that gets it there. Reading the setting here would raise a second
   time, out of the handler, and turn a reported error into an uncaught
   exception. *)
let clear_progress () = if progress_on_terminal then eprintf "\r\027[2K"

let compact_number value =
  let value = float_of_int value in
  if value >= 1_000_000_000. then Printf.sprintf "%.1fB" (value /. 1_000_000_000.)
  else if value >= 1_000_000. then Printf.sprintf "%.1fM" (value /. 1_000_000.)
  else if value >= 1_000. then Printf.sprintf "%.1fk" (value /. 1_000.)
  else Printf.sprintf "%.0f" value

let elapsed_clock seconds =
  let seconds = int_of_float (max 0. seconds) in
  Printf.sprintf "%02d:%02d" (seconds / 60) (seconds mod 60)

module StringSet = Set.Make (String)
module IntMap = Map.Make (Int)
module IntSet = Set.Make (Int)
module ConflictSet = Set.Make (struct
  type t = int * string
  let compare = compare
end)

type reduction = { lhs : string; width : int; prod : int }

type state = {
  transitions : (string, int) Hashtbl.t;
  reductions : (string, reduction list) Hashtbl.t;
  mutable accepts : StringSet.t;
}

type automaton = {
  states : state array;
  terminals : StringSet.t;
  aliases : (string, string) Hashtbl.t;
  (* Terminals that behave identically everywhere in the automaton share a
     class id. Two terminals are in one class when swapping them is an
     automorphism of the recognition relation, so the search only needs to try
     one representative per class instead of every interchangeable token. *)
  terminal_class : (string, int) Hashtbl.t;
  (* Production ids read back as the text Menhir printed for them. The search
     itself only ever compares ids, but a diagnostic that names the two
     productions a conflict is between is what makes the conflict findable in
     the grammar, so the mapping is kept rather than discarded after parsing. *)
  production_text : (int, string) Hashtbl.t;
  (* The fewest entries a stack can have with a state on top: the length of
     the shortest path from the initial state to it.

     This is the one thing about a stack that the retained suffix never says.
     A suffix is a chain of adjacent states and nothing more, so an abstract
     stack rebuilt on a guessed goto source can name a state that no stack
     that short could be carrying - the chain is a valid path through the
     automaton, just not one that fits. Comparing it against the height rules
     those out, and it is a property of the automaton, so it costs one table
     built once. *)
  min_height : int array;
}

let production_name automaton prod =
  Option.value
    (Hashtbl.find_opt automaton.production_text prod)
    ~default:(Printf.sprintf "production %d" prod)

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
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      let rec loop result =
        match input_line channel with
        | line -> loop (line :: result)
        | exception End_of_file -> List.rev result
      in
      loop [])

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      let length = in_channel_length channel in
      really_input_string channel length)

let split_lines source =
  List.map
    (fun line ->
      let length = String.length line in
      if length > 0 && line.[length - 1] = '\r' then
        String.sub line 0 (length - 1)
      else line)
    (String.split_on_char '\n' source)

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
    (split_lines source);
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

(* How short a stack can be with each state on top.

   A stack is a path from the initial state, one entry per edge, so this is a
   breadth-first walk of the transition graph and nothing more. [max_int] marks
   a state no path reaches, which is a state no stack can be carrying at all.

   The bound is sound in the direction it is used. It is a minimum over all
   paths, so a stack shorter than a state's minimum cannot have that state on
   top; one that clears it may or may not. Rejecting on it can therefore remove
   impossible stacks and never a possible one. *)
let solve_min_height states =
  let distance = Array.make (Array.length states) max_int in
  if Array.length states > 0 then begin
    distance.(0) <- 1;
    let queue = Queue.create () in
    Queue.add 0 queue;
    while not (Queue.is_empty queue) do
      let source = Queue.take queue in
      Hashtbl.iter
        (fun _ target ->
          if distance.(target) = max_int then begin
            distance.(target) <- distance.(source) + 1;
            Queue.add target queue
          end)
        states.(source).transitions
    done
  end;
  distance

(* Terminal equivalence classes.

   Two terminals are interchangeable when replacing every occurrence of one by
   the other is an automorphism of the recognition relation: they shift to
   equivalent states, trigger the same reductions as a lookahead, and are
   accepted in the same places. Interchangeable terminals generate isomorphic
   parse forests, so an ambiguous sentence exists with one iff it exists with
   the other; the search may therefore explore a single representative per
   class. Because precedence and associativity are already baked into the
   automaton's concrete shift/reduce actions, tokens with different precedence
   land in different classes automatically.

   Equivalence is computed in two steps. First a partition refinement over the
   states (a bisimulation on recognition behaviour: shift-target blocks,
   reduction (lhs, width) sets, nonterminal goto-target blocks, and accepts)
   collapses states that differ only in which production they carry - so
   [primary -> INT], [primary -> FLOAT] and [primary -> STRING] states become
   one block. Then terminals are grouped by their action across every state,
   comparing shift targets up to that state partition. This is why FLOAT and
   STRING merge even though they shift to distinct states, while INT stays
   separate: it is also valid as a const generic argument, a context the other
   two never reach. *)
let compute_terminal_classes states terminals =
  let count = Array.length states in
  let terminal_list = StringSet.elements terminals in
  (* "#" is the end marker; it is never shifted but does drive reductions and
     acceptance, so it participates in the lookahead-role signatures. *)
  let lookaheads = "#" :: terminal_list in
  let reduce_signature state token =
    match Hashtbl.find_opt state.reductions token with
    | None -> []
    | Some reductions ->
        List.sort_uniq compare
          (List.map (fun reduction -> (reduction.lhs, reduction.width)) reductions)
  in
  let shift_target state token =
    if StringSet.mem token terminals then Hashtbl.find_opt state.transitions token
    else None
  in
  let goto_targets state =
    Hashtbl.fold
      (fun symbol target result ->
        if StringSet.mem symbol terminals then result
        else (symbol, target) :: result)
      state.transitions []
    |> List.sort compare
  in
  let block = Array.make (max 1 count) 0 in
  let state_signature index =
    let state = states.(index) in
    let shifts =
      List.map
        (fun token ->
          match shift_target state token with
          | Some target -> Some block.(target)
          | None -> None)
        terminal_list
    in
    let reduces = List.map (reduce_signature state) lookaheads in
    let accepts =
      List.map (fun token -> StringSet.mem token state.accepts) lookaheads
    in
    let gotos =
      List.map (fun (symbol, target) -> (symbol, block.(target))) (goto_targets state)
    in
    (shifts, reduces, accepts, gotos)
  in
  (* One refinement pass. Keying by the previous block keeps the partition
     monotonically finer, so the block count never decreases and the loop
     below terminates once it stabilizes. *)
  let refine () =
    let table = Hashtbl.create 1024 in
    let fresh = ref 0 in
    let updated = Array.make (max 1 count) 0 in
    for index = 0 to count - 1 do
      let key = (block.(index), state_signature index) in
      match Hashtbl.find_opt table key with
      | Some id -> updated.(index) <- id
      | None ->
          let id = !fresh in
          incr fresh;
          Hashtbl.add table key id;
          updated.(index) <- id
    done;
    Array.blit updated 0 block 0 count;
    !fresh
  in
  let previous = ref (-1) in
  let blocks = ref (refine ()) in
  while !blocks <> !previous do
    previous := !blocks;
    blocks := refine ()
  done;
  let terminal_signature token =
    List.init count (fun index ->
        let state = states.(index) in
        let shift =
          match shift_target state token with
          | Some target -> Some block.(target)
          | None -> None
        in
        (shift, reduce_signature state token, StringSet.mem token state.accepts))
  in
  let signatures = Hashtbl.create 64 in
  let terminal_class = Hashtbl.create 64 in
  let fresh = ref 0 in
  List.iter
    (fun token ->
      let key = terminal_signature token in
      let id =
        match Hashtbl.find_opt signatures key with
        | Some id -> id
        | None ->
            let id = !fresh in
            incr fresh;
            Hashtbl.add signatures key id;
            id
      in
      Hashtbl.add terminal_class token id)
    terminal_list;
  terminal_class

(* Keep one terminal per class - the alphabetically first, for reproducible
   witnesses - so interchangeable tokens are explored once. A class is either
   wholly present in a frontier's possible tokens or wholly absent (its members
   act identically in every state), so picking representatives never drops a
   reachable token. *)
let class_representatives automaton tokens =
  let seen = Hashtbl.create 32 in
  StringSet.fold
    (fun token result ->
      match Hashtbl.find_opt automaton.terminal_class token with
      | Some id when Hashtbl.mem seen id -> result
      | Some id ->
          Hashtbl.add seen id ();
          StringSet.add token result
      | None -> StringSet.add token result)
    tokens StringSet.empty

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
  let productions = Hashtbl.create 512 in
  let intern_production text =
    match Hashtbl.find_opt productions text with
    | Some id -> id
    | None ->
        let id = Hashtbl.length productions in
        Hashtbl.add productions text id;
        id
  in
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
              let reduction =
                {
                  lhs;
                  width = List.length (words rhs);
                  prod = intern_production (lhs ^ " -> " ^ rhs);
                }
              in
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
  let terminal_class = compute_terminal_classes states terminals in
  let production_text = Hashtbl.create (Hashtbl.length productions) in
  Hashtbl.iter
    (fun text id -> Hashtbl.replace production_text id text)
    productions;
  let min_height = solve_min_height states in
  { states; terminals; aliases; terminal_class; production_text; min_height }

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
    let by_id = Hashtbl.create 16_384 in
    Hashtbl.add by_id 0 root;
    {
      by_edge = Hashtbl.create 16_384;
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

  let size pool = Hashtbl.length pool.by_id

  (* Drop every node not reachable from the root or from [iter_live]'s nodes.
     Ids keep increasing across compactions, so a swept node re-created later
     gets a fresh id and stale signatures in the dedup cache simply age out. *)
  let compact pool iter_live =
    let keep : (int, node) Hashtbl.t = Hashtbl.create 16_384 in
    let rec mark node =
      if not (Hashtbl.mem keep node.id) then begin
        Hashtbl.add keep node.id node;
        Option.iter mark node.parent
      end
    in
    mark pool.root;
    iter_live mark;
    Hashtbl.reset pool.by_edge;
    Hashtbl.reset pool.by_id;
    Hashtbl.iter
      (fun _ node ->
        Hashtbl.add pool.by_id node.id node;
        Option.iter
          (fun parent ->
            Hashtbl.add pool.by_edge (parent.id, node.state) node)
          node.parent)
      keep
end

type frontier = int IntMap.t
type signature = (int * int) list

let add_count stack_id count frontier =
  let old = Option.value (IntMap.find_opt stack_id frontier) ~default:0 in
  let updated = cap_add old count in
  (IntMap.add stack_id updated frontier, updated - old)

let signature frontier : signature = IntMap.bindings frontier

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

(* One sentence, parsed for real, keeping the frontier the recognizer stood on
   after each of its tokens.

   The abstract phase reasons about every sentence at once and has to
   approximate to do it. A single candidate is short enough to parse exactly,
   and the exact parse is the ground truth the abstraction is being measured
   against: what it accepts, and which stacks it was ever standing on. *)
let replay engine tokens =
  let initial = IntMap.singleton engine.stacks.root.id 1 in
  let collected =
    List.fold_left
      (fun frontiers token ->
        match frontiers with
        | [] -> assert false
        | current :: _ -> shift engine current token :: frontiers)
      [ initial ] tokens
  in
  Array.of_list (List.rev collected)

(* The top [depth] states of one concrete stack, deepest entry last, written
   the way an abstract suffix is. A stack with fewer entries than that returns
   all of them: it has reached the initial state, and a suffix that matches it
   there has matched the whole stack. *)
let concrete_suffix engine stack_id depth =
  let rec walk node remaining collected =
    if remaining <= 0 then List.rev collected
    else
      let collected = node.Stack_pool.state :: collected in
      match node.Stack_pool.parent with
      | None -> List.rev collected
      | Some parent -> walk parent (remaining - 1) collected
  in
  walk (Stack_pool.find engine.stacks stack_id) depth []

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
  Array.map
    (fun state ->
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

(* ----- Conservative unambiguity prover -----

   Abstract every GLR stack to its top-K states; a suffix shorter than K means
   the states below are unknown, which over-approximates every continuation,
   including the true stack bottom. Reductions that pop into the unknown part
   re-enter through every goto edge on the reduced nonterminal. The abstract
   configuration space is finite, so a pair search over runs that consume the
   same input terminates. Every concrete ambiguous sentence projects onto an
   abstract pair of runs that diverge in their actions and both accept, so if
   no such abstract pair exists, the grammar is unambiguous. The converse does
   not hold: an abstract diverging pair may be spurious, which is why a found
   candidate only downgrades the verdict to "not proven". *)

let rec drop_states count list =
  if count = 0 then list
  else match list with [] -> [] | _ :: tail -> drop_states (count - 1) tail

let truncate_suffix limit list =
  let rec take count = function
    | [] -> []
    | _ when count = 0 -> []
    | head :: tail -> head :: take (count - 1) tail
  in
  take limit list

(* How much stack to retain, as a property of the state on top rather than of
   the whole run. A uniform level pays for depth in every corner of the
   automaton to buy it in the one corner that needs it, and on a grammar this
   size that is the difference between a proof that finishes and one that does
   not. Keeping the depth per state lets a refinement deepen only the stacks
   that reach a blind spot.

   Soundness does not depend on the assignment. Truncation is the only thing
   that ever shortens a suffix and nothing ever invents one, so every concrete
   stack still projects onto the abstract stack its run carries, whatever
   depths are in force; a shallower entry admits more moves and a deeper one
   fewer, and only the second direction could lose a real parse. That is why
   refinement can be driven by a heuristic without putting the verdict at
   risk. *)
type precision = int array

(* An abstract stack: the suffix the abstraction retains, and how tall the
   real stack under it is.

   The suffix says which states are on top. It never says where the stack
   ends, and that is a separate fact with its own consequences: a reduction
   can only fire if there are entries for it to pop and a state left
   underneath to goto from. Without the height the abstraction has to assume
   there is always more stack below, so it admits reductions no parse could
   make and then guesses where they landed - and the guess is what keeps
   spurious pairs alive.

   The height is exact while it stays under [height_ceiling] and saturates
   there. Saturation is the safe direction: a stack that might be taller than
   any reduction is wide is a stack no reduction can be ruled out on, which is
   what the abstraction assumed everywhere before. The ceiling only has to
   clear the widest reduction in the grammar, because past that the answer to
   "are there enough entries" is yes regardless. *)
type stack = { suffix : int list; height : int }

(* Every stack the abstraction can still tell apart at this depth.

   A stack can be shorter than its state is entitled to keep, and the shortest
   ones come from the abstraction itself: a reduction that pops past what is
   retained rebuilds the stack as a goto target on a guessed source, two
   entries and nothing under them. Walking downward from the deepest entry
   recovers context wherever the automaton leaves no choice about what sits
   below.

   It stops at the first entry with more than one possible predecessor.
   Descending through a branch means carrying one stack per predecessor, and
   two stacks that differ only in how a split resolved are different possible
   worlds rather than two parses of one sentence, so the joint walk pairs each
   side's variants against the other's across every pair of distinct
   productions: the cost of a split is quadratic in it, while the depth it buys
   is not. That depth is also no longer worth buying here. A reduction chain
   keeps the entries its own pops leave behind, so the context a split would
   recover is context the chain never dropped, and on the real grammar
   descending through branches changes the explored pair count by well under a
   percent while making a refined run's stacks fan out far enough to exhaust
   memory. [AMBIGUITY_DESCENT_LIMIT] raises the bound for a grammar that wants
   the split; the descent then stops at whatever depth it has reached when the
   next level would cross it, and keeps the stacks it has.

   Most of the descent is free either way: the automaton forces the entry below
   for the large majority of its states, and a forced level adds depth without
   adding a variant, so stopping at the first branch still reaches a long way
   down a chain that never branches.

   The height steers the walk as well as ending it. Every stack starts at the
   initial state, so when the height is exact it says precisely how many
   entries are still missing, and a candidate for one of them is only real if
   the bottom is still that many predecessor steps below it. Candidates that
   cannot get there are dropped before they are ever carried, which is what
   makes the walk forced as often as it is: a chain that has to land on the
   initial state in three more entries has far fewer ways to do it than the
   automaton's shape alone suggests.

   Reaching the bottom is what the walk is for. A stack that descends to the
   initial state has nothing below it, and a reduction wider than it can pop is
   then not a move any parse can make - a conclusion the abstraction cannot
   draw while the stack is stranded above a branch. *)
(* Forced rather than read at module initialization: a top-level binding is
   evaluated before [main] is entered, so a rejected value would escape the
   handler around it and print a bare [Fatal error] instead of the tool's own
   [error:] line - and would skip [clear_progress]. *)
let descent_limit =
  lazy
    (match Sys.getenv_opt "AMBIGUITY_DESCENT_LIMIT" with
     | None | Some "" -> 1
     | Some value -> (
         match int_of_string_opt value with
         | Some chosen when chosen >= 1 -> chosen
         | _ -> invalid_arg "AMBIGUITY_DESCENT_LIMIT must be a positive integer"))

let cap_variants preds below (precision : precision) keep ceiling height states =
  match states with
  | [] -> [ { suffix = []; height } ]
  | top :: _ ->
      (* The suffix can never be longer than the stack it is a suffix of, so a
         known height bounds the retained depth as surely as the precision
         does, and a suffix that reaches the height has reached the bottom. *)
      (* [keep] is a floor the caller has already earned: entries this stack
         is demonstrably carrying, which cutting would only hand back to the
         descent to invent - through every predecessor the automaton allows
         rather than the one that was really there. It can never exceed the
         height, since it counts entries of a stack that tall. *)
      let limit =
        max keep
          (if height >= ceiling then precision.(top)
           else min precision.(top) height)
      in
      let kept = truncate_suffix limit states in
      let wrap suffix = { suffix; height } in
      (match List.rev kept with
      | [] -> [ wrap kept ]
      | deepest :: _ as reversed ->
          let finished = ref [] in
          let frontier = ref [ (reversed, List.length kept, deepest) ] in
          let stop = ref false in
          while (not !stop) && !frontier <> [] do
            let growing = ref [] in
            let held = ref [] in
            List.iter
              (fun ((below_first, length, deepest) as variant) ->
                if length >= limit then finished := below_first :: !finished
                else
                  let sources = preds.(deepest) in
                  if IntSet.is_empty sources then
                    finished := below_first :: !finished
                  else begin
                    held := variant :: !held;
                    IntSet.iter
                      (fun source ->
                        (* When the height is exact it says how many entries
                           are still missing, and every stack bottoms out at
                           the initial state, so a candidate that cannot reach
                           it in exactly that many more steps is not one. *)
                        if
                          height >= ceiling
                          || IntSet.mem 0 (below source (height - length - 1))
                        then
                          growing :=
                            (source :: below_first, length + 1, source)
                            :: !growing)
                      sources
                  end)
              !frontier;
            if
              List.length !growing + List.length !finished
              > Lazy.force descent_limit
            then begin
              (* One level too far. Keep every variant at the depth already
                 reached rather than the level that crossed the bound. *)
              List.iter
                (fun (below_first, _, _) -> finished := below_first :: !finished)
                !held;
              stop := true
            end
            else frontier := !growing
          done;
          List.rev_map (fun below_first -> wrap (List.rev below_first)) !finished)

let goto_edges automaton =
  let table = Hashtbl.create 256 in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun symbol target ->
          if not (StringSet.mem symbol automaton.terminals) then
            Hashtbl.replace table symbol
              ((source, target)
              :: Option.value (Hashtbl.find_opt table symbol) ~default:[]))
        state.transitions)
    automaton.states;
  table

(* The states that can sit directly below a given state on a parser stack:
   [p] is a predecessor of [s] exactly when some grammar symbol takes [p] to
   [s]. Every abstract suffix is a chain of adjacent states — each one is
   pushed onto the one below it by a shift or a goto, and truncation only
   drops entries from the bottom — so the state a suffix hides beneath its
   deepest entry is always one of that entry's predecessors. *)
let predecessors automaton =
  let table = Array.make (Array.length automaton.states) IntSet.empty in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun _ target -> table.(target) <- IntSet.add source table.(target))
        state.transitions)
    automaton.states;
  table

(* The states that can sit [steps] entries below [state] on a parser stack.
   One step is [predecessors]; further steps compose it, because a stack is a
   chain of adjacent states and each entry is pushed onto the one below by a
   shift or a goto.

   This is what a reduction popping past the retained stack lands on. Popping
   [width] entries off a suffix that only knows [depth] of them leaves the
   parser on the state [width - depth + 1] entries below the deepest one
   retained, so that is the set the goto source has to come from - never
   "anywhere", which is what the abstraction used to assume once the pop went
   further than one entry past the suffix. The set widens quickly with the
   number of steps and often saturates, but it starts out small, and it is
   empty exactly when the suffix reaches the bottom of the stack: nothing sits
   below the initial state, so a reduction that would pop past it is not a move
   any parse can make.

   Memoized because the same (state, steps) pair is asked for by every stack
   that ends there, and both arguments are small. *)
let below_steps preds =
  let cache = Hashtbl.create 1_024 in
  let rec walk state steps =
    if steps <= 0 then IntSet.singleton state
    else
      match Hashtbl.find_opt cache (state, steps) with
      | Some states -> states
      | None ->
          let nearer = walk state (steps - 1) in
          let states =
            IntSet.fold
              (fun state below -> IntSet.union below preds.(state))
              nearer IntSet.empty
          in
          Hashtbl.add cache (state, steps) states;
          states
  in
  walk

(* Deepen [state] to [depth].

   The request names one state, and one state is all this raises. That was not
   always enough: a suffix grew one entry at a time under the cap of whatever
   ended up on top, so a stack could only arrive at [state] holding [depth]
   entries if every state that could sit below it had been retaining
   [depth - 1] all along, and refinement had to walk a backward cone of
   predecessors to arrange it. The cone was the entire cost of a refinement,
   and its radius was the request: a radius-eleven cone reaches every state of
   a dense automaton at a depth close to the request, which is how a refinement
   aimed at four states ended up paying for the whole grammar and exhausting
   memory.

   Two things removed the need for it. A reduction chain keeps the entries its
   own pops leave behind, so depth survives a chain instead of being re-capped
   at every step; and where a stack does arrive short, the rebuilding descent
   walks it back down through the entries the automaton forces. Depth is
   therefore a property of the state on top and nothing else, and it can be
   granted where it is wanted without being bought everywhere behind it. *)
let deepen (precision : precision) state depth =
  if depth > precision.(state) then precision.(state) <- depth

let rec last_state = function
  | [] -> invalid_arg "last_state: empty suffix"
  | [ state ] -> state
  | _ :: tail -> last_state tail

(* One micro-step of a single run while consuming a token: apply one
   reduction, or terminate the chain by shifting the token (accepting, when
   the token is "#"). *)
(* How many moves the height test refused during the last abstract run, and how
   far the height was counted before it stopped deciding anything.

   Held beside the proof rather than carried through [prove_result], because
   every outcome wants them and none of them is a verdict. A test that silently
   removes moves is the same trap as a ceiling that silently clamps a request:
   the run looks like it explored a space it did not, and nothing in the output
   says which. Refinement re-runs the proof, so these describe its final round.
*)
let refused_stacks = ref 0
let tracked_height = ref 0

type side_move =
  | Reduce of int * stack (* production id, the stack afterwards *)
  | Terminate of stack (* the stack after the shift, or at acceptance *)

let side_moves automaton gotos below preds (precision : precision) ceiling cache
    stack token =
  match Hashtbl.find_opt cache (stack, token) with
  | Some moves -> moves
  | None ->
      let { suffix; height } = stack in
      let moves = ref [] in
      let depth = List.length suffix in
      let raise_height h = min ceiling (h + 1) in
      (* A stack too short to be carrying the state the move puts on top of it.
         The goto source of an imprecise reduction is guessed from the
         automaton's shape, which admits states that need a taller stack than
         this run has built; a state no path reaches at all needs more than any
         run can build. While the height is exact this rules the move out. *)
      let fits height top =
        let needed = automaton.min_height.(top) in
        if needed = max_int then begin
          incr refused_stacks;
          false
        end
        else if height >= ceiling || height >= needed then true
        else begin
          incr refused_stacks;
          false
        end
      in
      (match suffix with
      | [] -> ()
      | top :: _ ->
          let state = automaton.states.(top) in
          if token = "#" then begin
            if StringSet.mem "#" state.accepts then
              moves := Terminate stack :: !moves
          end
          else
            Option.iter
              (fun target ->
                if fits (raise_height height) target then
                  moves :=
                    List.rev_append
                      (List.rev_map
                         (fun variant -> Terminate variant)
                         (cap_variants preds below precision 0 ceiling
                            (raise_height height) (target :: suffix)))
                      !moves)
              (Hashtbl.find_opt state.transitions token);
          List.iter
            (fun reduction ->
              (* A reduction pops [width] entries and leaves the parser on the
                 state below the last of them, so a stack of exactly that many
                 entries has nothing left to goto from. While the height is
                 exact this rules the move out outright, which is the whole
                 point of carrying it: the abstraction used to assume more
                 stack below and guess where the pop landed. *)
              if height < ceiling && reduction.width >= height then ()
              else
                (* A saturated height is not a number, it is the absence of
                   one: subtracting a width from it would manufacture an exact
                   height smaller than the truth, and an under-counted height
                   rules out reductions a real parse can make. So it stays
                   saturated, which is the direction that only ever admits more
                   moves. *)
                let after =
                  if height >= ceiling then ceiling
                  else min ceiling (height - reduction.width + 1)
                in
                (* What is left after the pop is kept whole rather than cut
                   back to what the state on top is granted. A reduction chain
                   fires several times before it shifts, and re-truncating at
                   every step throws away entries the chain was demonstrably
                   holding a moment ago, only for the descent to invent them
                   back through every predecessor the automaton allows. That is
                   how a chain can walk to acceptance with every one of its
                   gotos exact and every stack it stood on made up. Keeping
                   them costs nothing that lasts: a pop never leaves more than
                   it was given, and the shift at the end of the chain cuts the
                   stack back to the retained depth before it becomes a node
                   the search stores. *)
                if reduction.width < depth then
                  match drop_states reduction.width suffix with
                  | [] -> assert false
                  | base :: _ as remaining ->
                      Option.iter
                        (fun target ->
                          if fits after target then
                            moves :=
                              List.rev_append
                                (List.rev_map
                                   (fun variant ->
                                     Reduce (reduction.prod, variant))
                                   (cap_variants preds below precision
                                      (depth - reduction.width + 1) ceiling
                                      after (target :: remaining)))
                                !moves)
                        (Hashtbl.find_opt
                           automaton.states.(base).transitions reduction.lhs)
                else
                  (* The reduction pops into the unknown part of the stack; the
                     goto source is the state left on top afterwards, which sits
                     one entry below the last one popped. Counting from the
                     deepest entry the suffix does know, that is
                     [width - depth + 1] entries further down, and the states
                     that can be there are exactly the ones that many predecessor
                     steps away. Popping exactly the suffix is the one-step case
                     of the same rule. *)
                  let deepest = last_state suffix in
                  let sources = below deepest (reduction.width - depth + 1) in
                  (* The goto source does not merely sit that far below the
                     suffix, it sits at a known height. The reduction leaves a
                     stack of [after] entries with the goto target on top, so
                     the source is the entry directly below it, and every stack
                     a parse builds starts at the initial state. A source the
                     initial state cannot reach in exactly that many steps is
                     therefore not standing on any stack, however well it fits
                     the automaton's shape read backwards. While the height is
                     exact this is what turns a guessed goto into the only one
                     available. *)
                  let grounded source =
                    if after >= ceiling then true
                    else if after < 2 then false
                    else if IntSet.mem 0 (below source (after - 2)) then true
                    else begin
                      incr refused_stacks;
                      false
                    end
                  in
                  List.iter
                    (fun (source, target) ->
                      if
                        IntSet.mem source sources && grounded source
                        && fits after target
                      then
                        moves :=
                          List.rev_append
                            (List.rev_map
                               (fun variant -> Reduce (reduction.prod, variant))
                               (cap_variants preds below precision 0 ceiling
                                  after [ target; source ]))
                            !moves)
                    (Option.value
                       (Hashtbl.find_opt gotos reduction.lhs)
                       ~default:[]))
            (reductions state token));
      Hashtbl.add cache (stack, token) !moves;
      !moves

type chain_status = Running of stack | Finished of stack

(* All (left result, right result, diverged) ways for both runs to consume
   [token]. The two reduction chains advance in lockstep: aligned identical
   productions carry no divergence, so a reduction cycle both runs share
   cancels out instead of poisoning the verdict, while any position where the
   chains first differ - two different productions, or one run reducing while
   the other shifts - is exactly where two distinct parses of one sentence
   must part ways, and marks the pair diverged. Goto and shift-target
   differences alone are abstraction artifacts, never a first divergence, so
   they are deliberately not compared. *)
let joint_outcomes moves (start_left, start_right) token =
  let seen = Hashtbl.create 64 in
  let results = Hashtbl.create 16 in
  let queue = Queue.create () in
  let push node =
    if not (Hashtbl.mem seen node) then begin
      Hashtbl.add seen node ();
      Queue.add node queue
    end
  in
  push (Running start_left, Running start_right, false);
  while not (Queue.is_empty queue) do
    let (left, right, diverged) = Queue.take queue in
    match (left, right) with
    | Finished result_left, Finished result_right ->
        Hashtbl.replace results (result_left, result_right, diverged) ()
    | Running suffix_left, Running suffix_right ->
        let paired move_left move_right =
          match (move_left, move_right) with
          | Reduce (p, l), Reduce (q, r) ->
              Some (Running l, Running r, diverged || p <> q)
          | Reduce (_, l), Terminate r -> Some (Running l, Finished r, true)
          | Terminate l, Reduce (_, r) -> Some (Finished l, Running r, true)
          | Terminate l, Terminate r -> Some (Finished l, Finished r, diverged)
        in
        if (not diverged) && suffix_left = suffix_right then
          (* The two runs are still the same run: same stack, so an
             unknown-base goto resolves identically on both sides. Identical
             moves pair diagonally; distinct moves pair only where two real
             parses can first part ways - different productions, or reducing
             against shifting. Same-production pairs with different gotos are
             different possible worlds, never two parses of one sentence. *)
          let all = moves suffix_left token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  let compatible =
                    match (move_left, move_right) with
                    | Reduce (p, _), Reduce (q, _) -> p <> q
                    | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
                    | Terminate _, Terminate _ -> false
                  in
                  if move_left == move_right || compatible then
                    Option.iter push (paired move_left move_right))
                all)
            all
        else
          let moves_left = moves suffix_left token in
          let moves_right = moves suffix_right token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  Option.iter push (paired move_left move_right))
                moves_right)
            moves_left
    | Running suffix_left, Finished _ ->
        List.iter
          (fun move ->
            match move with
            | Reduce (_, l) -> push (Running l, right, diverged)
            | Terminate l -> push (Finished l, right, diverged))
          (moves suffix_left token)
    | Finished _, Running suffix_right ->
        List.iter
          (fun move ->
            match move with
            | Reduce (_, r) -> push (left, Running r, diverged)
            | Terminate r -> push (left, Finished r, diverged))
          (moves suffix_right token)
  done;
  Hashtbl.fold (fun key () list -> key :: list) results []

(* Where in a chain two runs actually part ways, for a site the survey reports.

   The joint walk lets two runs differ only by taking different moves, and the
   step that does sets the divergence flag, so every pair still undiverged
   carries the same stack on both sides. A site is therefore one stack and one
   lookahead - and the conflict it names is usually not at that stack. The
   chain reduces in lockstep for as long as one move is on offer, and the
   competing moves appear a step or two down; reporting only the site's own top
   state shows a single shared reduction and says nothing.

   So follow the shared chain from the site until a stack admits two moves that
   two parses of one sentence could take: two different productions, or a
   reduction against a shift. Same-production moves that differ only in their
   goto are different possible worlds rather than a divergence, exactly as in
   the joint walk, so the chain continues through each of them.

   This is diagnostic only, and deliberately separate from [joint_outcomes]:
   carrying provenance through the hot path would multiply the outcome set it
   deduplicates on, and only the handful of sites a survey prints ever ask. *)
let conflicting_moves moves stack token =
  let seen = Hashtbl.create 16 in
  let queue = Queue.create () in
  let found = ref None in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  let rec pair_off = function
    | [] -> None
    | move :: rest -> (
        let partner =
          List.find_opt
            (fun other ->
              match (move, other) with
              | Reduce (p, _), Reduce (q, _) -> p <> q
              | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
              | Terminate _, Terminate _ -> false)
            rest
        in
        match partner with
        | Some other -> Some (move, other)
        | None -> pair_off rest)
  in
  push stack;
  while !found = None && not (Queue.is_empty queue) do
    let current = Queue.take queue in
    let available = moves current token in
    match pair_off available with
    | Some pair -> found := Some (current, pair)
    | None ->
        List.iter
          (function Reduce (_, next) -> push next | Terminate _ -> ())
          available
  done;
  !found

(* What a refinement would have to fix, at one stack under one lookahead.

   The abstraction is exact for a reduction exactly while the reduction pops
   less than the retained stack. At or past that boundary the goto source is a
   set rather than a state - the states the right number of predecessor steps
   below the deepest entry retained - and picking the wrong member of that set
   is the only way a pair of runs that no real sentence separates can stay
   alive. So the places worth deepening are the stacks where a reduction
   reaches or passes the retained depth, and the depth that would make it exact
   is one more than the reduction is wide.

   Walking the reduction chain, rather than only the stack it starts from, is
   what makes this useful: a chain reduces several times before it shifts, and
   the reduction that loses the context is rarely the first one.

   Like [conflicting_moves] this is diagnostic and runs only when a candidate
   has already been found, so it recomputes the chain instead of making the hot
   path carry provenance. The visit bound is a guard rather than a limit that
   is expected to bite: a refinement request this walk misses costs precision
   on the next round, never soundness. *)
let chain_imprecision automaton moves stack token =
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let requests = ref [] in
  let visits = ref 0 in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  push stack;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let current = Queue.take queue in
    (match current.suffix with
    | [] -> ()
    | top :: _ ->
        let depth = List.length current.suffix in
        List.iter
          (fun reduction ->
            if reduction.width >= depth then
              requests := (top, reduction.width + 1) :: !requests)
          (reductions automaton.states.(top) token));
    List.iter
      (function Reduce (_, next) -> push next | Terminate _ -> ())
      (moves current token)
  done;
  !requests

(* Where a chain leaving one stack is standing on a stack it has forgotten.

   [chain_imprecision] finds the one kind of guess a deeper stack removes by
   making a goto exact. It is not the only kind. A reduction chain truncates
   its stack at every step, under the cap of whatever state ends up on top, and
   a stack cut below its own height has thrown away entries it was demonstrably
   holding. The rebuilding descent then walks those entries back - through every
   predecessor the automaton allows, not just the one that was really there -
   so the chain continues on stacks no parse was ever standing on.

   Nothing about that reads as a guess at the goto: each goto along the way
   resolves exactly, off a suffix long enough to expose its source. The chain
   is exact and standing on an invention. That is how a candidate can survive
   with every step of its trace marked exact and refinement reporting that no
   retained stack rules it out.

   The depth that fixes it is the stack's own height, for the same reason the
   path-level widening asks for it: a stack retaining as many entries as it is
   tall is the whole stack, and the descent has nothing left to invent.

   Being cut short is not on its own a reason to ask, though, and asking on
   every cut would aim a refinement at most of the automaton at once. A
   truncated stack has lost nothing if walking it back down reconstructs the
   whole of it: every entry was forced, so the descent recovers the ones that
   were really there and no others, and depth would buy nothing the walk does
   not already give. So [descend] runs the walk to the stack's full height, and
   the depth is worth asking for whenever the walk comes back short of it -
   stopped at a branch, split into several, or given a height too saturated to
   pin anything down.

   The walk over the chain is the same one [chain_imprecision] makes, and
   carries the same visit bound for the same reason: a request it misses costs
   a round, never soundness. *)
let chain_truncations descend moves stack token =
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let requests = ref [] in
  let visits = ref 0 in
  let push stack =
    if not (Hashtbl.mem seen stack) then begin
      Hashtbl.add seen stack ();
      Queue.add stack queue
    end
  in
  push stack;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let current = Queue.take queue in
    (match current.suffix with
    | [] -> ()
    | top :: _ -> (
        if List.length current.suffix < current.height then
          match descend current with
          | [ rebuilt ] when List.length rebuilt.suffix >= rebuilt.height -> ()
          | _ -> requests := (top, current.height) :: !requests));
    List.iter
      (function Reduce (_, next) -> push next | Terminate _ -> ())
      (moves current token)
  done;
  !requests

(* The imprecise reductions on the joint step a recorded edge actually took.

   [chain_imprecision] explores every chain leaving one stack, which is what
   refinement wants: deepening a state the candidate did not go through costs
   precision it did not need, never a wrong verdict. A trace cannot be read that
   way, because it claims to say what happened on this pair's path, and a guess
   from a branch the pair never entered names the wrong state to sharpen.

   Filtering each side on its own by "can this chain reach one of the recorded
   child's stacks" is not enough either. It is a reachability test, so a chain
   that reaches the right stack for the wrong reason still passes, and it says
   nothing about whether the two sides' chains were taken *together* - which is
   the only sense in which a joint step has a provenance at all.

   So this replays the step the way [joint_outcomes] walks it, keeping both
   sides in lockstep and with the same pairing rules, and marks the joint nodes
   that can still reach an outcome matching the recorded child. A reduction is
   reported only when it fires on an edge between two marked nodes: taken on a
   path that demonstrably ends where this pair ended. Any deviation from
   [joint_outcomes]'s rules here would replay a different graph from the one the
   search walked, so the pairing logic is deliberately identical.

   The child is matched as an unordered pair, because [push] canonicalises by
   ordering the two sides and which side became which is not recoverable. That
   is the one place this stays an approximation: a step whose two sides ended on
   the same pair of stacks in the opposite arrangement is indistinguishable from
   the recorded one. It cannot admit a chain that ends somewhere else. *)
let joint_imprecision automaton moves pair token target =
  let matches (left, right) =
    match target with
    | None -> true
    | Some (child_left, child_right) ->
        (left = child_left && right = child_right)
        || (left = child_right && right = child_left)
  in
  let width_of stack prod =
    match stack.suffix with
    | [] -> None
    | top :: _ ->
        Option.map
          (fun reduction -> reduction.width)
          (List.find_opt
             (fun reduction -> reduction.prod = prod)
             (reductions automaton.states.(top) token))
  in
  (* A move is imprecise exactly where [side_moves] had to guess: the reduction
     reaches or passes the depth the stack retains. *)
  let imprecision stack move =
    match move with
    | Terminate _ -> None
    | Reduce (prod, _) -> (
        match width_of stack prod with
        | Some width when width >= List.length stack.suffix ->
            Some (List.hd stack.suffix, width + 1)
        | _ -> None)
  in
  let successors = Hashtbl.create 64 in
  let reaches = Hashtbl.create 64 in
  let visited = ref [] in
  let seen = Hashtbl.create 64 in
  let queue = Queue.create () in
  let visits = ref 0 in
  let push node =
    if not (Hashtbl.mem seen node) then begin
      Hashtbl.add seen node ();
      Queue.add node queue
    end
  in
  let record source target_node found =
    Hashtbl.replace successors source
      ((target_node, found)
      :: Option.value (Hashtbl.find_opt successors source) ~default:[]);
    push target_node
  in
  let start = (Running (fst pair), Running (snd pair), false) in
  push start;
  while (not (Queue.is_empty queue)) && !visits < 4096 do
    incr visits;
    let ((left, right, diverged) as current) = Queue.take queue in
    visited := current :: !visited;
    match (left, right) with
    | Finished result_left, Finished result_right ->
        if matches (result_left, result_right) then
          Hashtbl.replace reaches current ()
    | Running suffix_left, Running suffix_right ->
        let paired move_left move_right =
          let found =
            List.filter_map
              (fun (stack, move) -> imprecision stack move)
              [ (suffix_left, move_left); (suffix_right, move_right) ]
          in
          match (move_left, move_right) with
          | Reduce (p, l), Reduce (q, r) ->
              Some ((Running l, Running r, diverged || p <> q), found)
          | Reduce (_, l), Terminate r -> Some ((Running l, Finished r, true), found)
          | Terminate l, Reduce (_, r) -> Some ((Finished l, Running r, true), found)
          | Terminate l, Terminate r ->
              Some ((Finished l, Finished r, diverged), found)
        in
        if (not diverged) && suffix_left = suffix_right then
          let all = moves suffix_left token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  let compatible =
                    match (move_left, move_right) with
                    | Reduce (p, _), Reduce (q, _) -> p <> q
                    | Reduce _, Terminate _ | Terminate _, Reduce _ -> true
                    | Terminate _, Terminate _ -> false
                  in
                  if move_left == move_right || compatible then
                    Option.iter
                      (fun (next, found) -> record current next found)
                      (paired move_left move_right))
                all)
            all
        else
          let moves_left = moves suffix_left token in
          let moves_right = moves suffix_right token in
          List.iter
            (fun move_left ->
              List.iter
                (fun move_right ->
                  Option.iter
                    (fun (next, found) -> record current next found)
                    (paired move_left move_right))
                moves_right)
            moves_left
    | Running suffix_left, Finished _ ->
        List.iter
          (fun move ->
            let found =
              Option.to_list (imprecision suffix_left move)
            in
            match move with
            | Reduce (_, l) -> record current (Running l, right, diverged) found
            | Terminate l -> record current (Finished l, right, diverged) found)
          (moves suffix_left token)
    | Finished _, Running suffix_right ->
        List.iter
          (fun move ->
            let found =
              Option.to_list (imprecision suffix_right move)
            in
            match move with
            | Reduce (_, r) -> record current (left, Running r, diverged) found
            | Terminate r -> record current (left, Finished r, diverged) found)
          (moves suffix_right token)
  done;
  (* Backward from the matching outcomes: a node is on a path to the recorded
     child when one of its edges leads to a node that is. The joint graph can
     cycle, so this is a fixpoint rather than one sweep. *)
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun node ->
        if not (Hashtbl.mem reaches node) then
          if
            List.exists
              (fun (next, _) -> Hashtbl.mem reaches next)
              (Option.value (Hashtbl.find_opt successors node) ~default:[])
          then begin
            Hashtbl.replace reaches node ();
            changed := true
          end)
      !visited
  done;
  let requests = Hashtbl.create 16 in
  List.iter
    (fun node ->
      if Hashtbl.mem reaches node then
        List.iter
          (fun (next, found) ->
            if Hashtbl.mem reaches next then
              List.iter (fun request -> Hashtbl.replace requests request ()) found)
          (Option.value (Hashtbl.find_opt successors node) ~default:[]))
    !visited;
  List.sort compare
    (Hashtbl.fold (fun request () found -> request :: found) requests [])

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
  | Pair_overflow of int
  | Prove_timeout of int
  | Surveyed of prove_survey

(* Proof-mode exit statuses. A proof is a verdict rather than a success or a
   failure, so `ambiguity prove` reports which of the three it reached in its
   status: 0 proven, 1 a concrete ambiguous sentence, 3 neither. Status 2 stays
   what it is everywhere else in this tool - the run itself went wrong - so a
   caller can tell a verdict from a broken invocation. A plain search reports no
   verdict and keeps exiting 0 whether or not it found witnesses. *)
let ambiguous_status = 1
let not_proven_status = 3


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
let prove engine (precision : precision) pair_limit deadline survey_limit trace
    (retired : (int * int * string, unit) Hashtbl.t) =
  let automaton = engine.automaton in
  let gotos = goto_edges automaton in
  let preds = predecessors automaton in
  let below = below_steps preds in
  (* Past the widest reduction in the grammar the exact height stops deciding
     anything: every reduction has the entries it needs and one to spare, which
     is what the abstraction assumed before it counted at all. So that is where
     the count saturates, and the abstract stack space stays finite. *)
  refused_stacks := 0;
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
  (* Keyed by a single suffix rather than a pair, so this stays small and is
     read by every pair that reaches the same stack: worth keeping whole. *)
  let moves_cache = Hashtbl.create 100_003 in
  let moves =
    side_moves automaton gotos below preds precision height_ceiling
      moves_cache
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
  let joint pair token =
    match Hashtbl.find_opt joint_cache (pair, token) with
    | Some outcomes -> outcomes
    | None ->
        let outcomes = joint_outcomes moves pair token in
        if Hashtbl.length joint_cache >= joint_capacity then
          Hashtbl.reset joint_cache;
        Hashtbl.add joint_cache (pair, token) outcomes;
        outcomes
  in
  let parents :
      (stack * stack * bool, (string * (stack * stack * bool)) option) Hashtbl.t =
    Hashtbl.create 100_003
  in
  let queue = Queue.create () in
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
  let surveying = survey_limit > 0 in
  let canonical (left, right, diverged) =
    if compare left right <= 0 then (left, right, diverged)
    else (right, left, diverged)
  in
  let push origin node =
    let node = canonical node in
    if not (Hashtbl.mem parents node) then
      if Hashtbl.length parents >= pair_limit then overflow := true
      else begin
        Hashtbl.add parents node origin;
        Queue.add node queue
      end
  in
  let rec trail node =
    match Hashtbl.find parents node with
    | None -> []
    | Some (token, parent) -> token :: trail parent
  in
  (* Where the divergence was born, not where it was noticed. An accepting pair
     usually inherits its flag from an ancestor, and it is the ancestor's
     stacks and lookahead - the same triple the site table counts - that say
     why the abstraction could not separate the two parses. A pair that is not
     itself diverged reached acceptance by parting ways on end of input, so its
     own stacks under "#" are the site. *)
  let accepting_site ((left, right, _) as node) =
    let rec climb ((_, _, diverged) as node) =
      if not diverged then None
      else
        match Hashtbl.find parents node with
        | None -> None
        | Some (token, ((parent_left, parent_right, parent_diverged) as parent))
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
  let prune_subtree ((_, _, diverged) as node) = diverged && is_retired node in
  (* The node the divergence was born at, rather than the triple describing it:
     the forward walk has to start somewhere it can walk down from. *)
  let divergence_origin node =
    let rec climb ((_, _, diverged) as node) =
      if not diverged then None
      else
        match Hashtbl.find parents node with
        | None -> None
        | Some (_, ((_, _, parent_diverged) as parent)) ->
            if parent_diverged then climb parent else Some parent
    in
    climb node
  in
  (* Every step a pair took, root first, as the node standing before each token
     and the token it then consumed. [parents] points upward, so this is the
     same walk [trail] makes, keeping the nodes instead of discarding them. *)
  let path_steps node =
    let rec walk node collected =
      match Hashtbl.find parents node with
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
    let guesses (left, right, _) token child =
      let target =
        Option.map
          (fun (child_left, child_right, _) -> (child_left, child_right))
          child
      in
      List.map
        (fun (top, depth) ->
          Printf.sprintf "guessed at state %d (exact from %d)" top depth)
        (joint_imprecision automaton moves (left, right) token target)
    in
    let step index ((left, right, _) as node) token child =
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
    let scan (left, right, _) token =
      List.iter
        (fun stack -> List.iter record (chain_imprecision automaton moves stack token))
        (if left = right then [ left ] else [ left; right ])
    in
    let rec walk node =
      match Hashtbl.find parents node with
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
      let widen (left, right, _) token =
        List.iter
          (fun stack ->
            List.iter record (chain_truncations descend moves stack token))
          (if left = right then [ left ] else [ left; right ])
      in
      let rec walk node =
        match Hashtbl.find parents node with
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
  let start = { suffix = [ 0 ]; height = 1 } in
  push None (start, start, false);
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
           (compact_number (Hashtbl.length parents))
           (compact_number (Queue.length queue))
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
    (not (Queue.is_empty queue))
    && (surveying || !candidate = None)
    && (not !overflow)
    && Unix.gettimeofday () < deadline
  do
    let (left, right, diverged) as node = Queue.take queue in
    incr since_progress;
    if !since_progress >= 128 then begin
      since_progress := 0;
      report_progress ()
    end;
    (* EOF is a lookahead like any other, but it is not in [terminals] - it is
       the sentinel the joint outcomes take separately - so a pair that first
       parts ways on end of input would otherwise never have its site recorded
       while still counting as an accepting divergence. *)
    let eof_outcomes = joint (left, right) "#" in
    let accepts_diverged =
      List.exists
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
              push
                (Some (token, node))
                (next_left, next_right, diverged || chain_diverged))
            (joint (left, right) token))
        terminals
  done;
  clear_progress ();
  let explored = Hashtbl.length parents in
  (* A queue left with work in it is the only way past the loop other than a
     verdict, so it - not the clock - is what says the deadline cut the search
     short. Draining the queue exactly as time runs out is a completed proof,
     and is reported as one. *)
  let ran_out_of_time = not (Queue.is_empty queue) in
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
              let left, right, _ = pair_at index in
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
        let requests_at (left, right, _) token =
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
    | None ->
        if !overflow then Pair_overflow explored
        else if ran_out_of_time then Prove_timeout explored
        else Proven explored

type outcome = {
  witnesses : ((int * string) list * string list) list;
  explored : int;
  unique : int;
  deepest : int;
  stopped : string option;
}

type search_progress = {
  depth : int;
  ambiguities : ((int * string) list * int) list;
  explored : int;
  unique : int;
  rss_bytes : float;
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
      IntMap.fold
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
    read_lines "/proc/self/status"
    |> List.find_map (fun line ->
           if String.starts_with ~prefix:"VmRSS:" line then
             try Some (Scanf.sscanf line "VmRSS: %f kB" (fun kib -> kib *. 1024.))
             with _ -> None
           else None)
    |> Option.value ~default:(managed_heap_bytes ())
  with _ -> managed_heap_bytes ()

let memory_bar used budget =
  let width = 12 in
  let ratio = if budget <= 0. then 0. else min 1. (used /. budget) in
  let filled = int_of_float (floor ((ratio *. float_of_int width) +. 0.5)) in
  String.make filled '#' ^ String.make (width - filled) '-'

let render_progress ~started ~max_tokens ~memory_budget
    (entries : (bool * search_progress) list) =
  if entries <> [] && progress_due () then begin
    let has_active = List.exists fst entries in
    let depth =
      List.fold_left
        (fun current
             (is_active, (progress : search_progress)) ->
          if has_active && not is_active then current
          else max current progress.depth)
        0 entries
    in
    let profiles = Hashtbl.create 64 in
    let explored = ref 0 in
    let unique = ref 0 in
    let rss_bytes = ref 0. in
    List.iter
      (fun (_, (progress : search_progress)) ->
        explored := !explored + progress.explored;
        unique := !unique + progress.unique;
        rss_bytes := !rss_bytes +. progress.rss_bytes;
        List.iter
          (fun (profile, witness_depth) ->
            match Hashtbl.find_opt profiles profile with
            | Some previous when previous <= witness_depth -> ()
            | _ -> Hashtbl.replace profiles profile witness_depth)
          progress.ambiguities)
      entries;
    let at_depth =
      Hashtbl.fold
        (fun _ witness_depth count ->
          if witness_depth = depth then count + 1 else count)
        profiles 0
    in
    let elapsed = Unix.gettimeofday () -. started in
    show_progress_line
      (Printf.sprintf
         "● search %d/%d | amb %d | explored %s | unique %s | RAM [%s] \
          %.1f/%.1fG | %s"
         depth max_tokens at_depth (compact_number !explored)
         (compact_number !unique)
         (memory_bar !rss_bytes memory_budget)
         (!rss_bytes /. 1024. /. 1024. /. 1024.)
         (memory_budget /. 1024. /. 1024. /. 1024.)
         (elapsed_clock elapsed))
  end

let write_progress path (progress : search_progress) =
  let temporary = path ^ ".new" in
  let channel = open_out_bin temporary in
  Marshal.to_channel channel progress [];
  close_out channel;
  Sys.rename temporary path

let read_progress path : search_progress option =
  try
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
        Some (Marshal.from_channel channel : search_progress))
  with Sys_error _ | End_of_file | Failure _ -> None

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
      if derivations item.frontier >= 2 && accepted_count engine item.frontier >= 2
      then enqueue item
      else if not !admit_new then dropped := true
      else
        (* Before [min_tokens], revisiting the same parser frontier at a
           greater depth is useful rather than redundant: it can eventually
           produce a witness long enough to report. Once the minimum is met,
           the usual shortest-path deduplication applies. *)
        let progress = min item.depth min_tokens in
        let key = Seen_cache.digest item.branched progress item.frontier in
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
      if accepted_count engine item.frontier >= 2 then begin
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
  ]

let main () =
  Arg.parse options (fun value -> grammar := value)
    "ambiguity_search [options] GRAMMAR";
  if !grammar = "" then begin
    Arg.usage options "ambiguity_search [options] GRAMMAR";
    exit 2
  end;
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
        let rec attempt () =
          let result =
            prove engine precision prove_limits.max_frontiers deadline
              !survey_limit !trace_forward retired
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
          | Abstract_candidate candidate when !refine_max > 0 ->
              let tokens = candidate.candidate_tokens in
              let site = candidate.candidate_site in
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
              !refused_stacks !tracked_height
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
            printf
              "PROVEN UNAMBIGUOUS: no diverging pair of accepting parses \
               exists in the top-%d stack abstraction (%d abstract pairs \
               explored).\n"
              !prove_level pairs;
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
