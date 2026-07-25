type node =
  | Leaf     of string
  | Group    of { title: string; body: node }
  (* An association list rather than a map: field order is meaningful. A tree
     is read against the source it came from, so a conditional should render
     [if], [elif], [else] the way it is written, not sorted into [elif],
     [else], [if]. Callers therefore control the order by the order they build
     the list in. *)
  | Fields   of (string * node) list
  | Sequence of node list

(* Smart constructors *)
let group title body = Group { title; body }
let fields pairs     = Fields pairs
let seq xs           = Sequence xs
let map_seq f xs     = Sequence (List.map f xs)
