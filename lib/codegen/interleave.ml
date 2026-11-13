(* Experimental (docs/design/interleaving.md): a counted loop whose every
   iteration walks a chain, as a tree lookup or a short linked list does,
   made to run [ways] iterations' walks at once. Each walk takes one step,
   fetches what its next step reads, and gives way to the next, so the
   misses of [ways] chains overlap where the plain loop waits on each in
   turn.

   An iteration's body splits at its walk (I1, I2): the *walk half* is the
   statements before the walk and the walk itself, and writes only the
   iteration's own locals; the *retire half*, everything after the walk,
   runs strictly in iteration order (I4). A slot holds one iteration; the
   iterations in flight are always the [ways] after the oldest one not yet
   retired, iteration k in slot k mod [ways], so the slots themselves are
   the ring the design describes, with R = W. A walk that finishes early
   waits in its slot until the ones before it have retired. A retire half
   that only combines integers into accumulators with one wrapping
   operator each gives the same bits in any order, and retires as soon as
   its walk ends, freeing the slot at once (I1, "Which retire halves skip
   the ring").

   The loop runs interleaved when it has at least 2 x [ways] iterations
   and the lists its walks read hold [gate_bytes] or more, or, for one that
   retires in any order, its walks are long (a constant count of
   [long_walk] trips or more); otherwise, and in
   every build but an optimized one, it runs as it was written.

   The pass rewrites the CGT of a function (CGT to CGT), before Emit. Each
   slot gets a copy of the body with locals of its own, so a slot's state
   is a set of locals the copies share rather than an array: there are
   [ways] copies of the walk half and the retire half, each small, since
   the loop's body is (a written-out search, lowering.md L11). Every local
   the copies bind is given a slot before the loop and each [Let] of it in
   a copy becomes an [Assign], so the copies of one slot, emitted in
   different places, name the same storage; a local only one part names
   stays a [Let] of its copy.

   What qualifies, beyond the shape of I1 (a counted loop whose body holds
   a walk: a [Repeat] that assigns a local from an element it reads and
   reads an element at that local), is checked conservatively here:

   - the walk half writes nothing but locals the body binds, calls nothing,
     and reads only list elements, which stop the program on a bad index
     and nothing else;
   - the retire half calls nothing, prints nothing, writes locals and
     lists, and no local or list it writes is one the walk half reads
     (two lists are apart when they are two locals' own slots, or one is a
     slot of this function and the other a parameter's list, which was
     there before the slot);
   - nothing in the body leaves the loop or returns, so no abort can stop
     it part way, and every local more than one part of the body names is
     a scalar (a slot's state).

   A loop that fails a check is left as it was. *)

open Cgt.Nodes

(* The slots a loop runs at once: 32, or ZANE_INTERLEAVE_WAYS from 2 to 128,
   the widest the model measured; each slot is a copy of the body, so a
   wider setting is ignored rather than allowed to blow the build up. *)
let ways () =
  match Option.bind (Sys.getenv_opt "ZANE_INTERLEAVE_WAYS") int_of_string_opt with
  | Some w when w >= 2 && w <= 128 -> w
  | _ -> 32

(* The bytes of the lists a walk reads below which the loop runs plain:
   the I5 sweep's crossing for `chains` (docs/experiments/prefetch-reorder,
   round 8). A walk of a constant [long_walk] trips or more whose loop
   retires in any order runs interleaved at any size, as `tree` gained at
   every size swept; retiring in order costs too much in cache for that
   (round 9). *)
let gate_bytes = 1 lsl 19

let long_walk = 32

exception Refused of string

let refuse at = raise (Refused at)

let i64 k = { Expr.node = Expr.Int (Int64.of_int k); ty = Ty.I64 }
let local id ty = { Expr.node = Expr.Local id; ty }
let bin op left right ty = { Expr.node = Expr.Binary { op; left; right }; ty }
let add l r = bin Expr.Add l r Ty.I64
let mul l r = bin Expr.Mul l r Ty.I64
let eq l r = bin Expr.Eq l r Ty.I1
let less l r = bin Expr.Less l r Ty.I1
let both a b = bin Expr.Mul a b Ty.I1
let eval_expand label body = Stat.Eval { Expr.node = Expr.Expand { label; body; result = None }; ty = Ty.Void }

let zero (t : Ty.t) =
  match t with
  | Ty.I64 | Ty.I32 -> Some { Expr.node = Expr.Int 0L; ty = t }
  | Ty.F64 | Ty.F32 -> Some { Expr.node = Expr.Float 0.; ty = t }
  | Ty.I1 -> Some { Expr.node = Expr.Bool false; ty = t }
  | Ty.Void -> None
  | _ -> refuse __LOC__

(* Every id in a function, locals and labels alike, for fresh ones above. *)
let largest_id body =
  let top = ref 0 in
  let see i = if i > !top then top := i in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Local i | Expr.Address i -> see i
      | Expr.Expand { label; result; _ } ->
          see label;
          Option.iter see result
      | _ -> ())
    (function
      | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> see id
      | Stat.Assign { place; _ } -> see place.Expr.local
      | Stat.Leave l -> see l
      | Stat.Scope { id; _ } -> see id
      | Stat.Spawn { task; _ } -> see task
      | _ -> ())
    body;
  !top

(* Whether [e] reads a list's element, itself or through the [let]s in
   [lets] of the locals it names. *)
let reads_element lets e =
  let seen = Hashtbl.create 8 in
  let rec reads e =
    Cgt.Traverse.exists_in [ Stat.Eval e ] ~stat:(fun _ -> false) ~expr:(fun e ->
        match e.Expr.node with
        | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; _ } -> true
        | Expr.Local y when not (Hashtbl.mem seen y) ->
            Hashtbl.replace seen y ();
            List.exists reads (Hashtbl.find_all lets y)
        | _ -> false)
  in
  reads e

let mentions x e =
  Cgt.Traverse.exists_in [ Stat.Eval e ] ~stat:(fun _ -> false) ~expr:(fun e ->
      match e.Expr.node with Expr.Local y -> y = x | _ -> false)

(* Whether [count] and [body] are a walk: a loop with no loop inside it
   that assigns a local from an element it reads and reads an element at
   an index made of that local. *)
let is_walk body =
  (not (Cgt.Traverse.exists_in body ~expr:(fun _ -> false) ~stat:(function Stat.Repeat _ -> true | _ -> false)))
  &&
  let lets = Hashtbl.create 8 and cursors = ref [] in
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Let { id; value } -> Hashtbl.add lets id value
      | Stat.Assign { place = { Expr.local; path = []; deref = false; _ }; value } -> cursors := (local, value) :: !cursors
      | _ -> ())
    body;
  List.exists
    (fun (c, v) ->
      reads_element lets v
      && Cgt.Traverse.exists_in body ~stat:(fun _ -> false) ~expr:(fun e ->
             match e.Expr.node with
             | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ _; index; _ ] } -> mentions c index
             | _ -> false))
    !cursors

let holds_walk stats =
  Cgt.Traverse.exists_in stats ~expr:(fun _ -> false) ~stat:(function
    | Stat.Repeat { body; _ } -> is_walk body
    | _ -> false)

(* One level of the path from the loop's body down to its walk: the
   statements before and after the one the path goes through, and, for a
   level the path enters through an expansion, how that expansion's value
   was used ([wrap]), its label and its result. *)
type level = { before : Stat.t list; after : Stat.t list }

type opened = { label : int; result : int option; ty : Ty.t; wrap : Expr.t -> Stat.t list }

type path = { levels : level list; opened : opened list; walk_count : Expr.t; trip : Stat.t list }

let split stats =
  let rec go before = function
    | [] -> refuse __LOC__
    | s :: after when holds_walk [ s ] -> (List.rev before, s, after)
    | s :: rest -> go (s :: before) rest
  in
  go [] stats

let rec path_of stats =
  let before, s, after = split stats in
  let level = { before; after } in
  (* The expansion holding the walk, reached from [value] through nodes
     that are no expansion; the rest of [value] is then run after the walk
     rather than around it, so it must do nothing but compute. *)
  let enter (value : Expr.t) wrap =
    let rec find (e : Expr.t) =
      match e.Expr.node with
      | Expr.Expand { body; _ } when holds_walk body -> e
      | Expr.Expand _ -> refuse __LOC__
      | _ -> (
          let es, bodies = Cgt.Traverse.expr_parts e in
          if bodies <> [] then refuse __LOC__;
          match List.filter (fun x -> holds_walk [ Stat.Eval x ]) es with [ x ] -> find x | _ -> refuse __LOC__)
    in
    let hole = find value in
    let rest = Cgt.Traverse.map_expr (fun x -> if x == hole then Some { x with Expr.node = Expr.Unit } else None) (fun _ -> None) value in
    if Cgt.Traverse.exists_in [ Stat.Eval rest ] ~stat:(function Stat.Eval x when x == rest -> false | _ -> true) ~expr:(fun x ->
           match x.Expr.node with
           | Expr.Call _ | Expr.Call_value _ | Expr.Foreign_call _ | Expr.Expand _ | Expr.Take _ | Expr.Escape _ | Expr.Box _
           | Expr.Copy _ ->
               true
           | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; _ } -> false
           | Expr.Runtime _ -> true
           | _ -> false)
    then refuse __LOC__;
    let wrap v = wrap (Cgt.Traverse.map_expr (fun x -> if x == hole then Some v else None) (fun _ -> None) value) in
    match hole.Expr.node with
    | Expr.Expand { label; body; result } ->
        let p = path_of body in
        { p with levels = level :: p.levels; opened = { label; result; ty = hole.Expr.ty; wrap } :: p.opened }
    | _ -> refuse __LOC__
  in
  match s with
  | Stat.Repeat { count; body } when is_walk body -> { levels = [ level ]; opened = []; walk_count = count; trip = body }
  | Stat.Let { id; value } -> enter value (fun v -> [ Stat.Let { id; value = v } ])
  | Stat.Assign { place; value } -> enter value (fun v -> [ Stat.Assign { place; value = v } ])
  | Stat.Eval value -> enter value (fun _ -> [])
  | _ -> refuse __LOC__

(* [stats] with each [Leave] of a label [exits] maps to an exit code
   replaced by setting [exit] to it and leaving [label]. *)
let redirect exits exit label stats =
  Cgt.Traverse.map_stats
    (fun _ -> None)
    (function
      | Stat.Leave l when List.mem_assoc l exits -> Some [ Stat.assign exit (i64 (List.assoc l exits)); Stat.Leave label ]
      | _ -> None)
    stats

(* Whether every [Leave] in [stats] ends an expansion inside them. *)
let closed stats =
  let rec go open_ = function
    | [] -> true
    | s :: rest -> stat open_ s && go open_ rest
  and stat open_ s =
    match s with
    | Stat.Leave l -> List.mem l open_
    | Stat.Return _ -> false
    | _ ->
        let es, bodies = Cgt.Traverse.stat_parts s in
        List.for_all (expr open_) es && List.for_all (go open_) bodies
  and expr open_ e =
    let open_ = match e.Expr.node with Expr.Expand { label; _ } -> label :: open_ | _ -> open_ in
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.for_all (expr open_) es && List.for_all (go open_) bodies
  in
  go [] stats

(* Where an address's list lives: a local's own slot, or the place a
   pointer in a local names. *)
type root = Slot of int | Pointer of int

let rec root names (e : Expr.t) =
  match e.Expr.node with
  | Expr.Address y -> Slot y
  | Expr.Local y -> ( match Hashtbl.find_opt names y with Some a -> root names a | None -> Pointer y)
  | Expr.Offset { base; _ } -> root names base
  | _ -> refuse __LOC__

let fn_ok ~retire (fn : Cgt.Runtime.fn) =
  match fn with
  | Cgt.Runtime.List_at | Cgt.Runtime.Array_at -> true
  | Cgt.Runtime.List_push | Cgt.Runtime.List_reserve | Cgt.Runtime.List_room | Cgt.Runtime.Out_of_range -> retire
  | _ -> false

let plan ~symbol ~params ~fresh ~counter:(x, step) ~x_ty ~count original =
  let w = ways () in
  let body = List.rev (List.tl (List.rev original)) in
  let p = path_of body in
  let n = List.length p.opened in
  (* The locals the body binds, each with its type, and which of them are
     results of expansions not on the path. *)
  let bound = Hashtbl.create 32 and inner_results = Hashtbl.create 8 and labels = Hashtbl.create 16 in
  let path_labels = List.map (fun o -> o.label) p.opened in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Expand { label; result; _ } ->
          Hashtbl.replace labels label ();
          Option.iter
            (fun r ->
              if List.mem label path_labels then Hashtbl.replace bound r e.Expr.ty
              else Hashtbl.replace inner_results r label)
            result
      | Expr.Call _ | Expr.Call_value _ | Expr.Foreign_call _ | Expr.Take _ | Expr.Escape _ | Expr.Snapshot _
      | Expr.Box _ | Expr.Copy _ | Expr.Global _ ->
          refuse __LOC__
      | _ -> ())
    (function
      | Stat.Let { id; value } -> Hashtbl.replace bound id value.Expr.ty
      | Stat.Hold _ | Stat.Reserve _ | Stat.Scope _ | Stat.Spawn _ | Stat.Join _ | Stat.Return _ -> refuse __LOC__
      | _ -> ())
    body;
  Hashtbl.replace bound x x_ty;
  (* A result read outside its own expansion would be shared between copies. *)
  let rec outside_reads open_ (e : Expr.t) =
    (match e.Expr.node with
    | (Expr.Local y | Expr.Address y) when Hashtbl.mem inner_results y && not (List.mem (Hashtbl.find inner_results y) open_) ->
        refuse __LOC__
    | _ -> ());
    let open_ = match e.Expr.node with Expr.Expand { label; _ } -> label :: open_ | _ -> open_ in
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.iter (outside_reads open_) es;
    List.iter (List.iter (stat_reads open_)) bodies
  and stat_reads open_ s =
    (match s with
    | Stat.Assign { place; _ } when Hashtbl.mem inner_results place.Expr.local
                                    && not (List.mem (Hashtbl.find inner_results place.Expr.local) open_) ->
        refuse __LOC__
    | _ -> ());
    let es, bodies = Cgt.Traverse.stat_parts s in
    List.iter (outside_reads open_) es;
    List.iter (List.iter (stat_reads open_)) bodies
  in
  List.iter (stat_reads []) body;
  let mine y = Hashtbl.mem bound y || Hashtbl.mem inner_results y in
  let exit = fresh () and left = fresh () and stage = fresh () in
  List.iter (fun id -> Hashtbl.replace bound id Ty.I64) [ exit; left; stage ];
  (* Exit codes: leaving the path's [m]th expansion is m; the walk's count
     running out is n + 1. *)
  let exits_upto k = List.filteri (fun i _ -> i < k) (List.mapi (fun i o -> (o.label, i + 1)) p.opened) in
  let start_label = fresh () and trip_label = fresh () in
  let prefix =
    List.concat (List.mapi (fun k (l : level) -> redirect (exits_upto k) exit start_label l.before) p.levels)
  in
  let trip = redirect (exits_upto n) exit trip_label p.trip in
  let walk_half = prefix @ [ Stat.Eval p.walk_count ] @ trip in
  if not (closed [ eval_expand start_label prefix ] && closed [ eval_expand trip_label trip ]) then refuse __LOC__;
  (* The finish for each exit: the rest of each level the path is inside,
     from the one the exit lands in outward. *)
  let levels = Array.of_list p.levels and opened = Array.of_list p.opened in
  let rec outward k inner =
    (* [inner] are the statements of level [k], still inside its expansion. *)
    if k = 0 then inner
    else
      let o = opened.(k - 1) in
      let value = match o.result with Some r -> local r o.ty | None -> { Expr.node = Expr.Unit; ty = Ty.Void } in
      outward (k - 1) ((eval_expand o.label inner :: o.wrap value) @ levels.(k - 1).after)
  in
  let finish m =
    if m = n + 1 then outward n levels.(n).after
    else
      let o = opened.(m - 1) in
      let value = match o.result with Some r -> local r o.ty | None -> { Expr.node = Expr.Unit; ty = Ty.Void } in
      outward (m - 1) (o.wrap value @ levels.(m - 1).after)
  in
  let used = Hashtbl.create 4 in
  Hashtbl.replace used (n + 1) ();
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Assign { place = { Expr.local; _ }; value = { Expr.node = Expr.Int m; _ } } when local = exit ->
          Hashtbl.replace used (Int64.to_int m) ()
      | _ -> ())
    (prefix @ trip);
  let exit_codes = List.sort compare (Hashtbl.fold (fun m () a -> m :: a) used []) in
  let retire = List.map (fun m -> (m, finish m)) exit_codes in
  List.iter (fun (_, f) -> if not (closed f) then refuse __LOC__) retire;
  let retire_all = List.concat_map snd retire in
  (* Effects. *)
  let names = Hashtbl.create 8 in
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Let { id; value = { Expr.node = Expr.Address _ | Expr.Offset _; _ } as v } -> Hashtbl.replace names id v
      | Stat.Let
          { id; value = { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.List_push | Cgt.Runtime.Array_at; args = l :: _ }; _ } }
        ->
          Hashtbl.replace names id l
      | _ -> ())
    body;
  let reads = Hashtbl.create 8 and read_lists = ref [] in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | (Expr.Local y | Expr.Address y) when not (mine y) -> Hashtbl.replace reads y ()
      | Expr.Runtime { fn; args } ->
          if not (fn_ok ~retire:false fn) then refuse __LOC__;
          read_lists := root names (List.hd args) :: !read_lists
      | _ -> ())
    (function
      | Stat.Assign { place; _ } -> if place.Expr.deref || not (mine place.Expr.local) then refuse __LOC__
      | Stat.Store _ | Stat.Overwrite _ | Stat.Place _ -> refuse __LOC__
      | _ -> ())
    walk_half;
  let written_lists = ref [] in
  let writes_slot y = if (not (mine y)) && Hashtbl.mem reads y then refuse __LOC__ in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Runtime { fn; args } -> (
          if not (fn_ok ~retire:true fn) then refuse __LOC__;
          match fn with
          | Cgt.Runtime.List_push | Cgt.Runtime.List_reserve | Cgt.Runtime.List_room ->
              written_lists := root names (List.hd args) :: !written_lists
          | _ -> ())
      | _ -> ())
    (function
      | Stat.Assign { place; _ } when place.Expr.deref -> written_lists := Pointer place.Expr.local :: !written_lists
      | Stat.Assign { place; _ } -> writes_slot place.Expr.local
      | Stat.Store { address; _ } | Stat.Overwrite { address; _ } | Stat.Place { address; _ } -> (
          match address.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; args = l :: _ } ->
              written_lists := root names l :: !written_lists
          | _ -> written_lists := root names address :: !written_lists)
      | _ -> ())
    retire_all;
  let param y = List.mem_assoc y params in
  let apart a b =
    match (a, b) with
    | Slot a, Slot b -> a <> b
    | Slot a, Pointer q | Pointer q, Slot a -> (not (param a)) && param q
    | Pointer _, Pointer _ -> false
  in
  List.iter
    (fun wr ->
      (match wr with Slot y | Pointer y -> if (not (mine y)) && Hashtbl.mem reads y then refuse __LOC__);
      List.iter (fun rd -> if not (apart wr rd) then refuse __LOC__) !read_lists)
    !written_lists;
  (* Whether the retire half needs no order (I1, "Which retire halves skip
     the ring"): it writes no list, and each outer local it writes is an
     integer it only ever combines with one operator that wraps and so
     gives the same bits in any order of the same terms, `a = a + e` or, as
     an expansion leaves it, `t = a + e` then `a = t`. *)
  let combining (e : Expr.t) a =
    let of_a x = match x.Expr.node with Expr.Local y -> y = a | _ -> false in
    match e.Expr.node with
    | Expr.Binary { op = (Expr.Add | Expr.Mul) as op; left; right } when of_a left && not (mentions a right) -> Some (`B op)
    | Expr.Binary { op = (Expr.Add | Expr.Mul) as op; left; right } when of_a right && not (mentions a left) -> Some (`B op)
    | Expr.Math { fn = (Cgt.Math.Bit_and | Bit_or | Bit_xor | Min | Max) as fn; args = [ l; r ] }
      when (of_a l && not (mentions a r)) || (of_a r && not (mentions a l)) ->
        Some (`M fn)
    | _ -> None
  in
  let order_free =
    !written_lists = []
    &&
    let combined = Hashtbl.create 4 and ok = ref true in
    let accumulators = Hashtbl.create 4 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Assign { place = { Expr.local = a; deref = false; path = []; _ }; value } when not (mine a) ->
            if not (List.mem value.Expr.ty [ Ty.I64; Ty.I32 ]) then ok := false;
            Hashtbl.replace accumulators a ()
        | Stat.Assign { place = { Expr.local = a; _ }; _ } when not (mine a) -> ok := false
        | _ -> ())
      retire_all;
    (* A local that holds `a + e` on its way to `a`, mapped to that `a`. It
       must be read by nothing else, or it would show a running value. *)
    let temps = Hashtbl.create 4 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Assign { place = { Expr.local = t; _ }; value } when mine t ->
            Hashtbl.iter (fun a () -> if combining value a <> None then Hashtbl.replace temps t a) accumulators
        | _ -> ())
      retire_all;
    let rec visit (e : Expr.t) =
      let checked =
        Hashtbl.fold
          (fun a () found ->
            match combining e a with
            | Some op ->
                (match Hashtbl.find_opt combined a with
                | Some op' when op' <> op -> ok := false
                | _ -> Hashtbl.replace combined a op);
                Some a
            | None -> found)
          accumulators None
      in
      (match (checked, e.Expr.node) with
      | None, (Expr.Local y | Expr.Address y) when Hashtbl.mem accumulators y -> ok := false
      | _ -> ());
      let es, bodies = Cgt.Traverse.expr_parts e in
      List.iter
        (fun (x : Expr.t) ->
          match (checked, x.Expr.node) with
          | Some a, Expr.Local y when y = a -> ()
          | _ -> visit x)
        es;
      List.iter (List.iter stat) bodies
    and stat s =
      (match s with
      | Stat.Assign { place = { Expr.local = a; _ }; value } when Hashtbl.mem accumulators a -> (
          match value.Expr.node with
          (* Only through a temp that combines `a` itself: `a = t` with `t`
             a walk's result is an overwrite, which needs iteration order. *)
          | Expr.Local t when Hashtbl.find_opt temps t = Some a -> ()
          | _ -> if combining value a = None then ok := false)
      | _ -> ());
      let es, bodies = Cgt.Traverse.stat_parts s in
      List.iter visit es;
      List.iter (List.iter stat) bodies
    in
    List.iter stat retire_all;
    let rec reads_temp = function
      | [] -> ()
      | Stat.Assign { place = { Expr.local = a; _ }; value = { Expr.node = Expr.Local t; _ } } :: rest
        when Hashtbl.mem accumulators a && Hashtbl.mem temps t ->
          reads_temp rest
      | s :: rest ->
          let es, bodies = Cgt.Traverse.stat_parts s in
          List.iter (fun e -> if List.exists (fun t -> mentions t e) (List.of_seq (Hashtbl.to_seq_keys temps)) then ok := false) es;
          List.iter reads_temp bodies;
          reads_temp rest
    in
    reads_temp retire_all;
    !ok
  in
  (* What the walk reads at its cursor, fetched when it moves. *)
  let fetches = ref [] in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Runtime
          { fn = Cgt.Runtime.List_at; args = [ l; ({ Expr.node = Expr.Local c; _ } as i); ({ Expr.node = Expr.Int _; _ } as s) ] }
        when Hashtbl.mem bound c && not (List.exists (fun (l', i', s') -> l' = l && i' = i && s' = s) !fetches) ->
          fetches := (l, i, s) :: !fetches
      | _ -> ())
    ignore p.trip;
  let fetched = List.rev !fetches in
  if fetched = [] then refuse __LOC__;
  (* Copies. A local more than one part of the body names (the walk half
     before the walk, the walk, the retire half) is the slot's, fresh for
     each slot and given its storage before the loop; the rest, and labels,
     are fresh for each copy. *)
  let named_in stats =
    let t = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats
      (fun e -> match e.Expr.node with Expr.Local y | Expr.Address y -> Hashtbl.replace t y () | _ -> ())
      (function
        | Stat.Let { id; _ } -> Hashtbl.replace t id ()
        | Stat.Assign { place; _ } -> Hashtbl.replace t place.Expr.local ()
        | _ -> ())
      stats;
    t
  in
  let parts = [ named_in prefix; named_in (Stat.Eval p.walk_count :: trip); named_in retire_all ] in
  let per_slot = Hashtbl.create 16 in
  Hashtbl.iter
    (fun y t ->
      let n = List.length (List.filter (fun part -> Hashtbl.mem part y) parts) in
      if n > 1 || y = x || List.mem y [ exit; left; stage ] || List.exists (fun o -> o.result = Some y) p.opened then begin
        ignore (zero t);
        Hashtbl.replace per_slot y t
      end)
    bound;
  let slots =
    Array.init w (fun _ ->
        let m = Hashtbl.create 32 in
        Hashtbl.iter (fun id _ -> Hashtbl.replace m id (fresh ())) per_slot;
        m)
  in
  let copy s stats =
    let locals = slots.(s) and own = Hashtbl.create 8 in
    let id y =
      match Hashtbl.find_opt locals y with
      | Some z -> z
      | None -> (
          if not (Hashtbl.mem labels y || mine y || y = start_label || y = trip_label) then y
          else match Hashtbl.find_opt own y with
            | Some z -> z
            | None ->
                let z = fresh () in
                Hashtbl.replace own y z;
                z)
    in
    let rec ex (e : Expr.t) =
      let e = Cgt.Traverse.map_expr_parts ex sts e in
      match e.Expr.node with
      | Expr.Local y -> { e with Expr.node = Expr.Local (id y) }
      | Expr.Address y -> { e with Expr.node = Expr.Address (id y) }
      | Expr.Expand x -> { e with Expr.node = Expr.Expand { x with label = id x.label; result = Option.map id x.result } }
      | _ -> e
    and sts stats = List.map st stats
    and st s =
      match Cgt.Traverse.map_stat_parts ex sts s with
      | Stat.Let { id = y; value } when Hashtbl.mem locals y -> Stat.assign (id y) value
      | Stat.Let { id = y; value } -> Stat.Let { id = id y; value }
      | Stat.Assign { place; value } -> Stat.Assign { place = { place with Expr.local = id place.Expr.local }; value }
      | Stat.Leave l -> Stat.Leave (id l)
      | s -> s
    in
    sts stats
  in
  let v s y = local (Hashtbl.find slots.(s) y) (Hashtbl.find bound y) in
  let set s y e = Stat.assign (Hashtbl.find slots.(s) y) e in
  let total = fresh () and x0 = fresh () and next = fresh () and oldest = fresh () and turn = fresh () in
  let gate = fresh () and driver = fresh () in
  let g y = local y Ty.I64 in
  let copy_expr s e = match copy s [ Stat.Eval e ] with [ Stat.Eval e ] -> e | _ -> refuse __LOC__ in
  let prefetch s =
    List.map
      (fun (l, i, stride) ->
        Stat.Eval
          { Expr.node = Expr.Runtime { fn = Cgt.Runtime.Prefetch; args = [ copy_expr s l; copy_expr s i; stride ] }; ty = Ty.Void })
      fetched
  in
  let count_s s = copy_expr s p.walk_count in
  let start s =
    [ set s x (add (local x0 x_ty) (mul (g next) (i64 step))); set s exit (i64 0) ]
    @ copy s [ eval_expand start_label prefix ]
    @ [
        Stat.If { cond = eq (v s exit) (i64 0); body = [ set s left (count_s s); Stat.If { cond = less (v s left) (i64 1); body = [ set s exit (i64 (n + 1)) ] } ] };
        set s stage (i64 2);
        Stat.If { cond = eq (v s exit) (i64 0); body = set s stage (i64 1) :: prefetch s };
        Stat.assign next (add (g next) (i64 1));
      ]
  in
  let turn_of s =
    [
      Stat.If
        {
          cond = eq (v s stage) (i64 1);
          body =
            copy s [ eval_expand trip_label trip ]
            @ [
                Stat.If
                  {
                    cond = eq (v s exit) (i64 0);
                    body = [ set s left (add (v s left) (i64 (-1))); Stat.If { cond = less (v s left) (i64 1); body = [ set s exit (i64 (n + 1)) ] } ];
                  };
                Stat.If { cond = eq (v s exit) (i64 0); body = prefetch s };
                Stat.If { cond = { Expr.node = Expr.Flip (eq (v s exit) (i64 0)); ty = Ty.I1 }; body = [ set s stage (i64 2) ] };
              ];
        };
      Stat.If
        {
          cond = (if order_free then eq (v s stage) (i64 2) else both (eq (v s stage) (i64 2)) (eq (g turn) (i64 s)));
          body =
            List.map (fun (m, f) -> Stat.If { cond = eq (v s exit) (i64 m); body = copy s f }) retire
            @ [
                Stat.assign oldest (add (g oldest) (i64 1));
                Stat.assign turn (add (g turn) (i64 1));
                Stat.If { cond = eq (g turn) (i64 w); body = [ Stat.assign turn (i64 0) ] };
                Stat.If { cond = eq (g oldest) (g total); body = [ Stat.Leave driver ] };
                set s stage (i64 0);
                Stat.If { cond = less (g next) (g total); body = start s };
              ];
        };
    ]
  in
  let declare =
    List.concat
      (List.init w (fun s ->
           Hashtbl.fold (fun y t acc -> match zero t with Some z -> set s y z :: acc | None -> acc) per_slot []
           |> List.map (function Stat.Assign { place; value } -> Stat.Let { id = place.Expr.local; value } | s -> s)))
  in
  (* The gate: enough iterations to fill the slots, and enough data for
     the walks to miss. *)
  let walked =
    List.sort_uniq compare
      (List.map (fun (l, _, s) -> (l, match s.Expr.node with Expr.Int k -> Int64.to_int k | _ -> 0)) fetched)
  in
  let count_of l =
    let h = Ty.list_handle () in
    let handle = { Expr.node = Expr.Deref l; ty = h } in
    if h = Ty.Handle16 then { Expr.node = Expr.Convert { Expr.node = Expr.Member { value = handle; index = 1 }; ty = Ty.I32 }; ty = Ty.I64 }
    else { Expr.node = Expr.Member { value = handle; index = 1 }; ty = Ty.I64 }
  in
  let bytes = List.fold_left (fun acc (l, stride) -> add acc (mul (count_of l) (i64 stride))) (i64 0) walked in
  let long = order_free && match p.walk_count.Expr.node with Expr.Int k -> Int64.to_int k >= long_walk | _ -> false in
  let big = if long then { Expr.node = Expr.Bool true; ty = Ty.I1 } else { Expr.node = Expr.Flip (less bytes (i64 gate_bytes)); ty = Ty.I1 } in
  let cond = both { Expr.node = Expr.Flip (less (g total) (i64 (2 * w))); ty = Ty.I1 } big in
  let interleaved =
    [ Stat.Let { id = x0; value = local x x_ty } ]
    @ declare
    @ [ Stat.Let { id = next; value = i64 0 }; Stat.Let { id = oldest; value = i64 0 }; Stat.Let { id = turn; value = i64 0 } ]
    @ List.concat (List.init w start)
    @ [
        eval_expand driver [ Stat.Repeat { count = i64 max_int; body = List.concat (List.init w turn_of) } ];
        Stat.assign x (add (local x0 x_ty) (mul (g total) (i64 step)));
        Stat.Leave gate;
      ]
  in
  if Sys.getenv_opt "ZANE_INTERLEAVE_REPORT" = Some "1" then
    prerr_endline (Printf.sprintf "interleaved %s, retired %s" symbol (if order_free then "in any order" else "in order"));
  [
    eval_expand gate
      [ Stat.Let { id = total; value = count }; Stat.If { cond; body = interleaved }; Stat.Repeat { count = g total; body = original } ];
  ]

let reporting () = Sys.getenv_opt "ZANE_INTERLEAVE_REPORT" = Some "1"

(* The interleaved form of the loop [Repeat { count; body }] in [f], when
   it qualifies. ZANE_INTERLEAVE_REPORT=1 says which loops holding a walk
   were interleaved and, for the rest, which check refused them. *)
let attempt (f : Func.t) ~fresh count body =
  match (Loop_shapes.counter (Loop_shapes.facts body) body, List.rev body) with
  | Some counter, Stat.Assign { value; _ } :: _ -> (
      try Some (plan ~symbol:f.Func.symbol ~params:f.Func.params ~fresh ~counter ~x_ty:value.Expr.ty ~count body)
      with Refused at ->
        if reporting () && holds_walk body then prerr_endline (Printf.sprintf "left alone %s (%s)" f.Func.symbol at);
        None)
  | _ -> None

(* [f] with each counted loop that qualifies made to interleave, unless
   ZANE_INTERLEAVE=0. *)
let func (f : Func.t) =
  if Sys.getenv_opt "ZANE_INTERLEAVE" = Some "0" then f
  else
    let next = ref (largest_id f.Func.body) in
    let fresh () =
      incr next;
      !next
    in
    let rec stats ss = List.concat_map stat ss
    and stat (s : Stat.t) =
      match s with
      | Stat.Repeat { count; body } -> (
          match attempt f ~fresh count body with
          | Some ss -> ss
          | None -> [ Stat.Repeat { count; body = stats body } ])
      | _ -> [ Cgt.Traverse.map_stat_parts expr stats s ]
    and expr e = Cgt.Traverse.map_expr_parts expr stats e in
    { f with Func.body = stats f.Func.body }
