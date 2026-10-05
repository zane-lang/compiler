(* What the grammar actually recognizes.

   The concrete side of the engine: GLR frontiers over exact stacks, the
   reduction closure and shift that move them, acceptance counting capped at
   two, and the lower bounds the bounded search prunes with. *)

type frontier = int Automaton.IntMap.t
type signature = (int * int) list

let add_count stack_id count frontier =
  let old = Option.value (Automaton.IntMap.find_opt stack_id frontier) ~default:0 in
  let updated = Automaton.cap_add old count in
  (Automaton.IntMap.add stack_id updated frontier, updated - old)

let signature frontier : signature = Automaton.IntMap.bindings frontier

let derivations frontier =
  Automaton.IntMap.fold (fun _ count total -> Automaton.cap_add total count) frontier 0

type engine = {
  automaton : Automaton.automaton;
  stacks : Stack_pool.t;
  closure_cache : ((int * string), frontier) Hashtbl.t;
}

let reductions state token =
  Option.value (Hashtbl.find_opt state.Automaton.reductions token) ~default:[]

let closure_one engine stack_id token =
  match Hashtbl.find_opt engine.closure_cache (stack_id, token) with
  | Some result -> result
  | None ->
      let closure = ref (Automaton.IntMap.singleton stack_id 1) in
      let propagated = Hashtbl.create 16 in
      let queue = Queue.create () in
      Queue.add stack_id queue;
      while not (Queue.is_empty queue) do
        let current_id = Queue.take queue in
        let count = Automaton.IntMap.find current_id !closure in
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
              match Stack_pool.pop current reduction.Automaton.width with
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
  Automaton.IntMap.fold
    (fun stack_id outer_count result ->
      Automaton.IntMap.fold
        (fun reduced_id inner_count result ->
          fst
            (add_count reduced_id
               (min 2 (outer_count * inner_count))
               result))
        (closure_one engine stack_id token) result)
    frontier Automaton.IntMap.empty

let shift engine frontier token =
  Automaton.IntMap.fold
    (fun stack_id count result ->
      let stack = Stack_pool.find engine.stacks stack_id in
      match
        Hashtbl.find_opt engine.automaton.states.(stack.state).transitions token
      with
      | None -> result
      | Some target ->
          let shifted = Stack_pool.push engine.stacks stack target in
          fst (add_count shifted.id count result))
    (closure engine frontier token) Automaton.IntMap.empty

let accepted_count engine frontier =
  Automaton.IntMap.fold
    (fun stack_id count total ->
      let stack = Stack_pool.find engine.stacks stack_id in
      if
        Automaton.StringSet.mem "#"
          engine.automaton.states.(stack.state).accepts
      then Automaton.cap_add total count
      else total)
    (closure engine frontier "#") 0

let possible_tokens engine frontier =
  Automaton.IntMap.fold
    (fun stack_id _ tokens ->
      let stack = Stack_pool.find engine.stacks stack_id in
      let state = engine.automaton.states.(stack.state) in
      let tokens =
        Hashtbl.fold
          (fun symbol _ tokens ->
            if Automaton.StringSet.mem symbol engine.automaton.terminals then
              Automaton.StringSet.add symbol tokens
            else tokens)
          state.transitions tokens
      in
      Hashtbl.fold
        (fun token _ tokens ->
          if token = "#" then tokens else Automaton.StringSet.add token tokens)
        state.reductions tokens)
    frontier Automaton.StringSet.empty

let conflict_states automaton =
  Array.map
    (fun state ->
      Hashtbl.fold
        (fun token reductions conflict ->
          conflict
          || List.length reductions > 1
          || Hashtbl.mem state.Automaton.transitions token)
        state.reductions false)
    automaton.Automaton.states

(* Build an optimistic state graph. Terminal shifts cost one token;
   nonterminal transitions and reductions cost zero. Reverse shortest paths on
   this graph are safe lower bounds, even though stack context is ignored. *)
let reverse_distances automaton targets =
  let count = Array.length automaton.Automaton.states in
  let reverse = Array.make count [] in
  let add_edge source target cost =
    reverse.(target) <- (source, cost) :: reverse.(target)
  in
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun symbol target ->
          let cost = if Automaton.StringSet.mem symbol automaton.terminals then 1 else 0 in
          add_edge source target cost)
        state.Automaton.transitions)
    automaton.states;
  let gotos = Hashtbl.create 128 in
  Array.iter
    (fun state ->
      Hashtbl.iter
        (fun symbol target ->
          if not (Automaton.StringSet.mem symbol automaton.terminals) then
            let previous =
              Option.value (Hashtbl.find_opt gotos symbol) ~default:[]
            in
            Hashtbl.replace gotos symbol (target :: previous))
        state.Automaton.transitions)
    automaton.states;
  Array.iteri
    (fun source state ->
      Hashtbl.iter
        (fun _ reductions ->
          List.iter
            (fun reduction ->
              List.iter (fun target -> add_edge source target 0)
                (Option.value (Hashtbl.find_opt gotos reduction.Automaton.lhs) ~default:[]))
            reductions)
        state.Automaton.reductions)
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
  Automaton.IntMap.fold
    (fun stack_id _ best ->
      let stack = Stack_pool.find engine.stacks stack_id in
      min best distances.(stack.state))
    frontier (max_int / 4)
