module StringMap = Map.Make(String) [@@deriving map]

type node =
  | Leaf     of string
  | Group    of { title: string; body: node }
  | Fields   of node StringMap.t
  | Sequence of node list

(* Smart constructors *)
let group title body = Group { title; body }
let fields pairs     = Fields (StringMap.of_list pairs)
let seq xs           = Sequence xs
let map_seq f xs     = Sequence (List.map f xs)
