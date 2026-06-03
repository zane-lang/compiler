module StringMap = Map.Make(String) [@@deriving map]

type nodes =
  | Leaf of string
  | Fields of string * nodes StringMap.t
  | Children of string * nodes list
