(* DFA for finitely many complete token histories. Prefix states stay unique;
   all histories that leave the trie enter an absorbing Other state. A blocked
   marker may coexist with children so a complete sentence can prefix another. *)
type node = { edges : (string, int) Hashtbl.t; mutable blocked : bool }
type t = { root : int; other : int; nodes : (int, node) Hashtbl.t }

let other = -1

let create sentences =
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
  { root; other; nodes }

let root filter = filter.root

let advance filter state token =
  if state = filter.other then filter.other
  else
    match Hashtbl.find_opt filter.nodes state with
    | None -> filter.other
    | Some node ->
        Option.value (Hashtbl.find_opt node.edges token) ~default:filter.other

let is_blocked filter state =
  match Hashtbl.find_opt filter.nodes state with
  | Some node -> node.blocked
  | None -> false

let state_count filter = Hashtbl.length filter.nodes + 1
