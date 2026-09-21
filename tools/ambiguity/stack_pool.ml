(* How exact GLR stacks are represented and shared.

   One node per (parent, state) pair, hash-consed so that two frontiers
   standing on the same stack point at the same node rather than at equal
   copies of it. *)

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
