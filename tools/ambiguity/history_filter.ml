(* DFA for finitely many complete token histories. Prefix states stay unique;
   all histories that leave the trie enter an absorbing Other state. A blocked
   marker may coexist with children so a complete sentence can prefix another. *)
type node = { edges : (string, int) Hashtbl.t; mutable blocked : bool }
type t = { root : int; other : int; nodes : (int, node) Hashtbl.t }

let other = -1

let create sentences =
  if sentences = [] then { root = other; other; nodes = Hashtbl.create 0 }
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
  { root; other; nodes }

let root filter = filter.root

(* Once a token history leaves the finite exclusion trie, no continuation can
   turn it back into an excluded sentence. The Other state therefore carries
   an unrestricted continuation language. *)
let is_other filter state = state = filter.other

(* The first state must be the unrestricted, absorbing history. Its language
   includes every completion of a trie prefix, while the reverse inclusion
   fails. Divergence is also monotone: an already-diverged pair can cover an
   undiverged one, but not the reverse. *)
let other_history_subsumes ~covering_other ~covering_diverged ~covered_other
    ~covered_diverged =
  covering_other && not covered_other
  && (covering_diverged || not covered_diverged)

let history_subsumption_enabled ~surveying ~has_retired_sites =
  not surveying && not has_retired_sites

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
