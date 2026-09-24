(* DFA for finitely many complete token histories. Prefix states stay unique;
   all histories that leave the trie enter an absorbing Other state. A blocked
   marker may coexist with children so a complete sentence can prefix another. *)
type node = { edges : (string, int) Hashtbl.t; mutable blocked : bool }
type t = {
  root : int;
  other : int;
  nodes : (int, node) Hashtbl.t;
  paren_limit : int;
}

let other = -1

let create ?(paren_limit = 0) sentences =
  if paren_limit < 0 then invalid_arg "paren_limit must be non-negative";
  if sentences = [] then
    { root = other; other; nodes = Hashtbl.create 0; paren_limit }
  else
  let nodes = Hashtbl.create 32 in
  let next_id = ref 0 in
  let add_node () =
    let id = !next_id in
    incr next_id;
    Hashtbl.add nodes id { edges = Hashtbl.create 4; blocked = false };
    id
  in
  let root = add_node () in
  let insert sentence =
    let rec walk state = function
      | [] -> (Hashtbl.find nodes state).blocked <- true
      | token :: rest ->
          let current = Hashtbl.find nodes state in
          let target =
            match Hashtbl.find_opt current.edges token with
            | Some target -> target
            | None ->
                let target = add_node () in
                Hashtbl.add current.edges token target;
                target
          in
          walk target rest
    in
    walk root sentence
  in
  List.iter insert sentences;
  { root; other; nodes; paren_limit }

(* In proof mode the trie state also carries a bounded exact count of open
   parentheses. Once it exceeds the bound it becomes unknown forever: treating
   it as an exact count after a closing parenthesis could reject a real parse.
   The default zero limit preserves the plain trie used by existing callers. *)
let stride filter = filter.paren_limit + 2
let encode filter trie depth = (trie + 1) * stride filter + depth
let decode filter state = (state / stride filter - 1, state mod stride filter)
let dead = -1

let root filter =
  if filter.paren_limit = 0 then filter.root
  else encode filter filter.root 0

let advance_trie filter state token =
  if state = filter.other then filter.other
  else
    match Hashtbl.find_opt filter.nodes state with
    | None -> filter.other
    | Some node ->
        Option.value (Hashtbl.find_opt node.edges token) ~default:filter.other

let advance filter state token =
  if filter.paren_limit = 0 then advance_trie filter state token
  else if state = dead then dead
  else
    let trie, depth = decode filter state in
    let next_depth =
      if depth > filter.paren_limit then depth
      else if token = "LPAREN" then depth + 1
      else if token = "RPAREN" then depth - 1
      else depth
    in
    if next_depth < 0 then dead
    else encode filter (advance_trie filter trie token) next_depth

let is_dead filter state = filter.paren_limit > 0 && state = dead

let is_blocked_trie filter state =
  match Hashtbl.find_opt filter.nodes state with
  | Some node -> node.blocked
  | None -> false

let is_blocked filter state =
  if filter.paren_limit = 0 then is_blocked_trie filter state
  else if state = dead then true
  else
    let trie, depth = decode filter state in
    (depth > 0 && depth <= filter.paren_limit)
    || is_blocked_trie filter trie

let state_count filter =
  (Hashtbl.length filter.nodes + 1)
  * (if filter.paren_limit = 0 then 1 else stride filter)
