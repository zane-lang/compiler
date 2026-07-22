(* Bounded complete-ambiguity search for Menhir automata. The search retains
   unresolved LR actions as GLR branches, caps derivation counts at two, and
   accepts a witness only when two derivations recognize the start symbol. *)

module StringSet = Set.Make (String)
module IntMap = Map.Make (Int)
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

(* One micro-step of a single run while consuming a token: apply one
   reduction, or terminate the chain by shifting the token (accepting, when
   the token is "#"). *)
type side_move =
  | Reduce of int * int list (* production id, suffix afterwards *)
  | Terminate of int list (* suffix after the shift, or at acceptance *)

let side_moves automaton gotos limit cache suffix token =
  match Hashtbl.find_opt cache (suffix, token) with
  | Some moves -> moves
  | None ->
      let moves = ref [] in
      (match suffix with
      | [] -> ()
      | top :: _ ->
          let state = automaton.states.(top) in
          if token = "#" then begin
            if StringSet.mem "#" state.accepts then
              moves := Terminate suffix :: !moves
          end
          else
            Option.iter
              (fun target ->
                moves :=
                  Terminate (truncate_suffix limit (target :: suffix)) :: !moves)
              (Hashtbl.find_opt state.transitions token);
          List.iter
            (fun reduction ->
              if reduction.width < List.length suffix then
                match drop_states reduction.width suffix with
                | [] -> assert false
                | base :: _ as remaining ->
                    Option.iter
                      (fun target ->
                        moves :=
                          Reduce
                            ( reduction.prod,
                              truncate_suffix limit (target :: remaining) )
                          :: !moves)
                      (Hashtbl.find_opt
                         automaton.states.(base).transitions reduction.lhs)
              else
                (* The reduction pops into the unknown part of the stack; the
                   goto source is the state left on top afterwards. *)
                List.iter
                  (fun (source, target) ->
                    moves :=
                      Reduce
                        (reduction.prod, truncate_suffix limit [ target; source ])
                      :: !moves)
                  (Option.value
                     (Hashtbl.find_opt gotos reduction.lhs)
                     ~default:[]))
            (reductions state token));
      Hashtbl.add cache (suffix, token) !moves;
      !moves

type chain_status = Running of int list | Finished of int list

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

type prove_result =
  | Proven of int
  | Abstract_candidate of string list * int
  | Pair_overflow of int

let prove engine limit pair_limit =
  let automaton = engine.automaton in
  let gotos = goto_edges automaton in
  let moves_cache = Hashtbl.create 100_003 in
  let moves = side_moves automaton gotos limit moves_cache in
  let joint_cache = Hashtbl.create 100_003 in
  let joint pair token =
    match Hashtbl.find_opt joint_cache (pair, token) with
    | Some outcomes -> outcomes
    | None ->
        let outcomes = joint_outcomes moves pair token in
        Hashtbl.add joint_cache (pair, token) outcomes;
        outcomes
  in
  let parents :
      ( int list * int list * bool,
        (string * (int list * int list * bool)) option )
      Hashtbl.t =
    Hashtbl.create 100_003
  in
  let queue = Queue.create () in
  let overflow = ref false in
  let candidate = ref None in
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
  let terminals = StringSet.elements automaton.terminals in
  push None ([ 0 ], [ 0 ], false);
  while (not (Queue.is_empty queue)) && !candidate = None && not !overflow do
    let (left, right, diverged) as node = Queue.take queue in
    List.iter
      (fun (_, _, chain_diverged) ->
        if (diverged || chain_diverged) && !candidate = None then
          candidate := Some (List.rev (trail node)))
      (joint (left, right) "#");
    if !candidate = None then
      List.iter
        (fun token ->
          List.iter
            (fun (next_left, next_right, chain_diverged) ->
              push
                (Some (token, node))
                (next_left, next_right, diverged || chain_diverged))
            (joint (left, right) token))
        terminals
  done;
  let explored = Hashtbl.length parents in
  match !candidate with
  | Some tokens -> Abstract_candidate (tokens, explored)
  | None -> if !overflow then Pair_overflow explored else Proven explored

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
  let digest branched frontier =
    let lane seed =
      IntMap.fold
        (fun stack_id count hash -> mix (mix hash stack_id) count)
        frontier
        (mix seed (Bool.to_int branched))
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
  float_of_int (Gc.quick_stat ()).heap_words
  *. float_of_int (Sys.word_size / 8)

let unified_search engine initial ~max_tokens ~timeout ~max_frontiers
    ~max_queue ~max_witnesses ~soft_heap_bytes ~hard_heap_bytes
    conflict_distance accept_distance =
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
        let key = Seen_cache.digest item.branched item.frontier in
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
  let depth = ref 0 in
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
  (* soft and hard are 80% and 90% of the worker share respectively, so this
     is 75% of that share without passing a third threshold around. *)
  let resume_heap_bytes = 0.9375 *. soft_heap_bytes in
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
  while
    Hashtbl.length witnesses < max_witnesses
    && !depth <= max_tokens
    && Unix.gettimeofday () < deadline
  do
    if Queue.is_empty buckets.(!depth) then incr depth
    else begin
      maybe_compact_stacks ();
      if !admit_new then begin
        if !explored mod 4_096 = 0 then manage_memory ()
      end
      else manage_memory ();
      let item = Queue.take buckets.(!depth) in
      decr queued;
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
  if Unix.gettimeofday () >= deadline then
    stopped := Some "the timeout was reached"
  else if Hashtbl.length witnesses >= max_witnesses then
    stopped := Some "the witness limit was reached"
  else if !dropped then
    stopped := Some "the memory budget dropped part of the search space";
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
    ~max_queue ~max_witnesses ~soft_heap_bytes ~hard_heap_bytes
    conflict_distance accept_distance temporary =
  let partitions, prefix_explored, prefix_unique, prefix_seeds =
    initial_partitions engine (max 1 jobs) max_tokens
  in
  if Array.length partitions = 1 then
    let outcome, seeds =
      unified_search engine partitions.(0) ~max_tokens ~timeout ~max_frontiers
        ~max_queue ~max_witnesses ~soft_heap_bytes ~hard_heap_bytes
        conflict_distance accept_distance
    in
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
        match Unix.fork () with
        | 0 ->
            let result =
              unified_search engine initial ~max_tokens ~timeout ~max_frontiers
                ~max_queue ~max_witnesses ~soft_heap_bytes ~hard_heap_bytes
                conflict_distance accept_distance
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
          let rec wait () =
            try Unix.waitpid [] pid
            with Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
          in
          match wait () with
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
let timeout = ref None
let max_witnesses = ref None
let check_tokens = ref []
let prove_level = ref 0

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
       exit 0 proven unambiguous, 1 ambiguous, 3 not proven \
       (the derived dedup-frontier limit also bounds the abstract pair count)" );
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
  Option.iter
    (fun value ->
      if value < 0 then invalid_arg "--max-tokens must be at least 0")
    !max_tokens;
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
  let search_limits =
    if !check_tokens <> [] then None
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
  Fun.protect
    ~finally:(fun () -> remove_tree temporary)
    (fun () ->
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
      let max_tokens, timeout, max_witnesses = Option.get search_limits in
      let memory_limits =
        derive_memory_limits ~memory_mb ~max_frontier_ratio ~jobs ~max_tokens
      in
      Printf.printf
        "Memory budget: %d MiB total across %d worker(s); workers compact at %.0f MiB and stop admitting frontiers at %.0f MiB each (10%% reserved); per-worker limits are %d queued frontiers and %d retained dedup frontiers (ratio %g).\n"
        memory_mb jobs
        (memory_limits.soft_heap_bytes /. 1024. /. 1024.)
        (memory_limits.hard_heap_bytes /. 1024. /. 1024.)
        memory_limits.max_queue memory_limits.max_frontiers
        max_frontier_ratio;
      if !prove_level > 0 then begin
        match prove engine !prove_level memory_limits.max_frontiers with
        | Proven pairs ->
            Printf.printf
              "PROVEN UNAMBIGUOUS: no diverging pair of accepting parses \
               exists in the top-%d stack abstraction (%d abstract pairs \
               explored).\n"
              !prove_level pairs;
            exit 0
        | Pair_overflow pairs ->
            Printf.printf
              "NOT PROVEN: the abstract pair limit (%d) was reached at \
               abstraction level %d. Raise AMBIGUITY_MEMORY_MB or \
               AMBIGUITY_MAX_FRONTIER_RATIO, or lower --prove.\n"
              pairs !prove_level;
            exit 3
        | Abstract_candidate (tokens, pairs) ->
            Printf.printf
              "Abstract ambiguity candidate at level %d after %d pairs \
               (possibly spurious): %s\n"
              !prove_level pairs
              (String.concat " " tokens);
            Printf.printf
              "Attempting to concretize with the bounded search...\n\n"
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
        parallel_unified_search engine ~jobs ~max_tokens ~timeout
          ~max_frontiers:memory_limits.max_frontiers
          ~max_queue:memory_limits.max_queue ~max_witnesses
          ~soft_heap_bytes:memory_limits.soft_heap_bytes
          ~hard_heap_bytes:memory_limits.hard_heap_bytes conflict_distance
          accept_distance temporary
      in
      match outcome.witnesses with
      | [] ->
          (match outcome.stopped with
          | None ->
              Printf.printf
                "No complete ambiguity found through %d tokens after exploring %d frontiers (%d unique).\n"
                max_tokens outcome.explored outcome.unique
          | Some reason ->
              Printf.printf
                "Search stopped at depth %d because %s; no complete ambiguity was found in %d explored frontiers (%d unique).\n"
                outcome.deepest reason outcome.explored outcome.unique);
          if !prove_level > 0 then begin
            Printf.printf
              "NOT PROVEN: the abstract candidate could not be concretized \
               within the search bounds; the grammar is neither proven \
               unambiguous nor shown ambiguous. Raising --prove may remove \
               the spurious candidate.\n";
            exit 3
          end;
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
