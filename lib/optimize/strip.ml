(* A counted loop that indexes a small array with its counter,
   strip-mined.

   A hash of eight lanes keeps them in an `Array<I32, 8>` and updates the
   one at `bitAnd(i-1, 7)+1` for each byte (tests/perf `lanes`). LLVM
   unrolls the loop by four from wherever its range-check split leaves it,
   so the index is never a constant and the eight lanes stay in memory,
   each update a store and a load. Cut into runs of eight whose index is
   the run's own counter, the eight lanes are eight registers.

   A loop fits when its body ends by stepping a local counter `x` by one
   (`x = x + 1`, as `to` does), assigns `x` nowhere else, never has its
   address taken anywhere in the function (so nothing writes it through a
   pointer), indexes an array
   of N elements, N a power of two from 2 to 16, uses `bitAnd`, and holds
   no loop, scope, call or spawn, in at most [budget] nodes. It becomes

     c = count; start = x; blocks = c / N; b = 0
     repeat blocks { x = start + b*N; body (N copies); b = b + 1 }
     repeat c - blocks*N { body }

   Every copy steps `x` as the body did, so each runs as the iteration it
   stands for. Where `start` is known, LLVM then sees each copy's
   `bitAnd(x + k, N-1)` as a constant, as `start + b*N` has no low bits but
   `start`'s. Each copy's own locals and labels are renamed. *)

open Cgt.Nodes


let budget = 400

let size ss =
  let n = ref 0 in
  Cgt.Traverse.walk_stats (fun _ -> incr n) (fun _ -> incr n) ss;
  !n

(* The ids [ss] defines: its lets, and its expansions' labels and results. *)
let defined ss =
  let t = Hashtbl.create 16 in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Expand { label; result; _ } ->
          Hashtbl.replace t label ();
          Option.iter (fun r -> Hashtbl.replace t r ()) result
      | _ -> ())
    (function Stat.Let { id; _ } -> Hashtbl.replace t id () | _ -> ())
    ss;
  t

(* [ss] with every id in [own] renamed by [rename]. *)
let copy own rename ss =
  let r i = if Hashtbl.mem own i then rename i else i in
  let rec stats ss = List.concat_map stat ss
  and stat (s : Stat.t) : Stat.t list =
    match s with
    | Stat.Let { id; value } -> [ Stat.Let { id = r id; value = expr value } ]
    | Stat.Assign { place; value } -> [ Stat.Assign { place = { place with local = r place.local }; value = expr value } ]
    | Stat.Leave l -> [ Stat.Leave (r l) ]
    | s -> [ Cgt.Traverse.map_stat_parts expr stats s ]
  and expr (e : Expr.t) : Expr.t =
    match e.Expr.node with
    | Expr.Local i -> { e with node = Expr.Local (r i) }
    | Expr.Address i -> { e with node = Expr.Address (r i) }
    | Expr.Expand { label; body; result } ->
        { e with node = Expr.Expand { label = r label; body = stats body; result = Option.map r result } }
    | _ -> Cgt.Traverse.map_expr_parts expr stats e
  in
  stats ss

(* The locals whose address [f] takes anywhere. *)
let addressed (f : Func.t) =
  let seen = Hashtbl.create 8 in
  Cgt.Traverse.walk_stats
    (fun e -> match e.Expr.node with Expr.Address i -> Hashtbl.replace seen i () | _ -> ())
    (fun _ -> ())
    f.Func.body;
  seen

(* The counter the body steps last, if the loop fits, and N. [taken] holds
   the locals whose address the function takes. *)
let fits taken (body : Stat.t list) =
  match List.rev body with
  | Stat.Assign { place = { local = x; deref = false; path = []; ty = Ty.I64 }; value } :: before
    when not (Hashtbl.mem taken x) ->
      (* The step is x plus exactly one, however lowering wrapped it: the
         value, read through the lets of its own expansions, is x plus a
         constant, and that constant is one. *)
      let steps =
        let bound = Hashtbl.create 4 in
        let rec constant (e : Expr.t) =
          match e.Expr.node with
          | Expr.Int c -> Some c
          | Expr.Local l -> Option.bind (Hashtbl.find_opt bound l) constant
          | _ -> None
        and offset (e : Expr.t) =
          match e.Expr.node with
          | Expr.Local l when l = x -> Some 0L
          | Expr.Local l -> Option.bind (Hashtbl.find_opt bound l) offset
          | Expr.Binary { op = Expr.Add; left; right } -> (
              match (offset left, constant right, constant left, offset right) with
              | Some a, Some b, _, _ | _, _, Some b, Some a -> Some (Int64.add a b)
              | _ -> None)
          | Expr.Expand { body; result = Some r; _ } ->
              let lets =
                List.for_all
                  (function Stat.Let { id; value } -> Hashtbl.replace bound id value; true | _ -> false)
                  body
              in
              if lets then offset { e with node = Expr.Local r } else None
          | _ -> None
        in
        offset value = Some 1L
      in
      let n = ref None and masks = ref false and unfit = ref false in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.Array_at; args = [ _; _; { node = Expr.Int len; _ }; _ ] }
            when List.mem len [ 2L; 4L; 8L; 16L ] ->
              n := Some (Int64.to_int len)
          | Expr.Math { fn = Cgt.Math.Bit_and; _ } -> masks := true
          | Expr.Call _ | Expr.Call_value _ | Expr.Foreign_call _ | Expr.Box _ | Expr.Snapshot _ | Expr.Escape _ ->
              unfit := true
          | _ -> ())
        (function
          | Stat.Repeat _ | Stat.While _ | Stat.Scope _ | Stat.Hold _ | Stat.Reserve _ | Stat.Spawn _ | Stat.Join _ -> unfit := true
          | Stat.Assign { place; _ } when place.local = x -> unfit := true
          | _ -> ())
        (List.rev before);
      if steps && !masks && (not !unfit) && size body <= budget then Option.map (fun n -> (x, n)) !n else None
  | _ -> None

let largest = Peel.largest

let func (f : Func.t) : Func.t =
  let taken = addressed f in
  let next = ref (largest f) in
  let fresh () = incr next; !next in
  let added = ref [] in
  let stripped = ref 0 in
  let i64 n = { Expr.node = Expr.Int (Int64.of_int n); ty = Ty.I64 } in
  let local i = { Expr.node = Expr.Local i; ty = Ty.I64 } in
  let bin op l r = { Expr.node = Expr.Binary { op; left = l; right = r }; ty = Ty.I64 } in
  let fs (s : Stat.t) =
    match s with
    | Stat.Repeat { count; body } -> (
        match fits taken body with
        | None -> None
        | Some (x, n) ->
            incr stripped;
            let own = defined body in
            let instance () =
              let table = Hashtbl.create 16 in
              let rename i =
                match Hashtbl.find_opt table i with
                | Some j -> j
                | None ->
                    let j = fresh () in
                    Hashtbl.replace table i j;
                    if List.mem i f.Func.values then added := j :: !added;
                    j
              in
              copy own rename body
            in
            let c = fresh () and start = fresh () and blocks = fresh () and b = fresh () in
            let block =
              [ Stat.assign x (bin Expr.Add (local start) (bin Expr.Mul (local b) (i64 n))) ]
              @ List.concat (List.init n (fun _ -> instance ()))
              @ [ Stat.assign b (bin Expr.Add (local b) (i64 1)) ]
            in
            Some
              [
                Stat.Let { id = c; value = count };
                Stat.Let { id = start; value = local x };
                Stat.Let { id = blocks; value = bin Expr.Div (local c) (i64 n) };
                Stat.Let { id = b; value = i64 0 };
                Stat.Repeat { count = local blocks; body = block };
                Stat.Repeat { count = bin Expr.Add (local c) (bin Expr.Mul (local blocks) (i64 (-n))); body };
              ])
    | _ -> None
  in
  let body = Cgt.Traverse.map_stats (fun _ -> None) fs f.Func.body in
  { f with body; values = f.Func.values @ !added }

let program (p : Program.t) : Program.t =
  { p with Program.funcs = List.map func p.Program.funcs }
