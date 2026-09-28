module T = Nodes

(* Whether a run of statements ends on every path: some statement in it
   leaves for good. A call never counts -- which calls exit their caller is
   not something a signature says -- and neither does a `match`, whose arms
   `return` to it rather than out of the verb. *)
let ends ~resolve (stats : T.Stat.t list) =
  List.exists
    (fun (s : T.Stat.t) ->
      match s.T.Stat.node with
      | T.Stat.Return _ | T.Stat.Abort _ -> true
      | T.Stat.Resolve _ -> resolve
      | _ -> false)
    stats
