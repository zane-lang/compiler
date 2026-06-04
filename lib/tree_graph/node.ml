module StringMap = Map.Make(String) [@@deriving map]

type node =
  | Leaf of string
  | Group of { title: string; body: node }
  | Fields of node StringMap.t
  | Sequence of node list
