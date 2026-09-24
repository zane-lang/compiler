(* The automaton a run proves or searches: how the grammar's tokens are
   declared, how Menhir is invoked and its dump parsed, and the derived facts
   the rest of the engine reads off the result -- minimum stack heights,
   terminal equivalence classes and production names. *)

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
  (* Production ids are unique to reduction occurrences in the automaton dump,
     even when Menhir printed the same lhs/rhs text for two alternatives. The
     search compares ids, while diagnostics need the text that gave each id a
     name, so the mapping is kept rather than discarded after parsing. *)
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
   reduction (lhs, width) multisets, nonterminal goto-target blocks, and
   accepts)
   collapses states that differ only in which production they carry - so
   [primary -> INT], [primary -> FLOAT] and [primary -> STRING] states become
   one block. The reduction entries are a multiset rather than a set: two
   identical-looking alternatives are two actions and must keep a state out of
   the same block as a state with only one such action. Then terminals are
   grouped by their action across every state,
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
        (* Keep multiplicity. Distinct reductions can have the same rendered
           [lhs] and width, and collapsing them makes a state with two
           reductions look like a state with one. Their unique [prod] ids are
           deliberately not part of this *state* bisimulation: swapping
           interchangeable terminals is allowed to carry corresponding
           grammar productions to one another, while the multiset still
           records how many reductions there are. *)
        List.sort compare
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
  (* Unlike the state partition above, a terminal's direct reduction action is
     compared with production identity as well as multiplicity. This keeps
     action signatures honest when two occurrences render identically; the
     state partition still gives ordinary interchangeable terminals (such as
     the A/B atoms in the tiny expression grammar) the same block. *)
  let reduction_signature state token =
    match Hashtbl.find_opt state.reductions token with
    | None -> []
    | Some reductions ->
        List.sort compare
          (List.map
             (fun reduction -> (reduction.prod, reduction.lhs, reduction.width))
             reductions)
  in
  let terminal_signature token =
    List.init count (fun index ->
        let state = states.(index) in
        let shift =
          match shift_target state token with
          | Some target -> Some block.(target)
          | None -> None
        in
        (shift, reduction_signature state token, StringSet.mem token state.accepts))
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
  (* The automaton dump does not expose Menhir's internal production number.
     A rendered [lhs -> rhs] is therefore only a label, not an identity: two
     alternatives with the same text still represent two derivation steps.
     Allocate one id for every reduction occurrence in the dump. Reusing a
     text-keyed id here turns a reduce/reduce conflict into two copies of the
     same move and lets the prover dismiss a real ambiguity. *)
  let production_text = Hashtbl.create 512 in
  let fresh_production text =
    let id = Hashtbl.length production_text in
    Hashtbl.add production_text id text;
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
                  prod = fresh_production (lhs ^ " -> " ^ rhs);
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
  let min_height = solve_min_height states in
  { states; terminals; aliases; terminal_class; production_text; min_height }
