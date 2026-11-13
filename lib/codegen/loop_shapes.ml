(* Experimental (docs/experiments/goose-comparison): the shapes of loop
   and scope bodies that Emit lays out differently: scopes it opens without
   an arena, lists whose handles a loop holds in registers, and the pushes
   whose room is made once. Each reads the CGT only. *)

open Cgt.Nodes


(* Whether [s] names the local [id] anywhere in it, a spawned call's result
   coming home to it included. *)
let names id s =
  Cgt.Traverse.exists_in [ s ]
    ~expr:(fun e -> match e.Expr.node with Expr.Local l | Expr.Address l -> l = id | _ -> false)
    ~stat:(function
      | Stat.Assign { place; _ } -> place.Expr.local = id
      | Stat.Let { id = l; _ } | Stat.Hold { id = l; _ } | Stat.Reserve { id = l; _ } -> l = id
      | Stat.Spawn { dest; _ } -> dest = Some id
      | _ -> false)

let new_list (e : Expr.t) =
  match e.Expr.node with Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] } -> true | _ -> false

(* Whether [e] makes a new list: the runtime's call, or an expansion that
   assigns it to its result and does nothing else. *)
let fresh_list (e : Expr.t) =
  match e.Expr.node with
  | Expr.Expand
      {
        body = [ Stat.Assign { place = { Expr.local; path = []; deref = false; _ }; value } ];
        result = Some r;
        _;
      } ->
      local = r && new_list value
  | _ -> new_list e

(* Experimental (docs/experiments/goose-comparison): unless
   ZANE_LIGHT_SCOPES=0, a scope nothing can put a block in -- every slot it
   places holds scalars, and nothing in its body boxes, copies, makes a list
   or a string, spawns, or calls a function or the runtime in a way that
   could leave a block in the innermost region, or, with frame references,
   gives a call an address -- opens no region: its frame, when it is no
   larger than 4 KiB, is a slot on the machine stack. *)
let light id body =
  Sys.getenv_opt "ZANE_LIGHT_SCOPES" <> Some "0"
  &&
  let rec scalar (t : Ty.t) =
    match t with
    | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
    | Ty.Struct ts | Ty.Sum ts -> List.for_all scalar ts
    | Ty.Array (t, _) | Ty.Packed t -> scalar t
    | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> false
  in
  let quiet = function
    | Cgt.Runtime.List_push | List_room | List_reserve | List_at | Array_at | Out_of_range | Text_equal
    | Parse_i64 | Parse_f64 | List_remove { scalars = true } | List_swap_remove { scalars = true } ->
        true
    | _ -> false
  in
  (* With frame references, an address a call is given may be stored as a
     32-bit offset from the image (Build.stored_ref), which a slot on the
     machine stack is out of reach of, whether the call is given it alone
     or inside a value; the body may itself store one, which is a
     conversion to a reference. *)
  let rec holds_address (t : Ty.t) =
    match t with
    | Ty.Ptr | Ty.Ref -> true
    | Ty.Struct ts | Ty.Sum ts -> List.exists holds_address ts
    | Ty.Array (t, _) | Ty.Packed t -> holds_address t
    | _ -> false
  in
  let addressed (a : Expr.t) = holds_address a.Expr.ty in
  not
    (Cgt.Traverse.exists_in body
       ~expr:(fun e ->
         match e.Expr.node with
         | Expr.Box _ | Expr.Text _ -> true
         | Expr.Runtime { fn; _ } -> not (quiet fn)
         | Expr.Call { args; _ } | Expr.Call_value { args; _ } ->
             (not (scalar e.Expr.ty)) || (Cgt.Ref32.frames () && List.exists addressed args)
         | Expr.Copy _ | Expr.Take _ | Expr.Escape _ -> not (scalar e.Expr.ty)
         | Expr.Convert _ -> Cgt.Ref32.frames () && e.Expr.ty = Ty.Ref
         | _ -> false)
       ~stat:(function
         | Stat.Spawn _ | Stat.Join _ -> true
         | Stat.Hold { scope; value; _ } -> scope = id && not (scalar value.Expr.ty)
         | Stat.Reserve { scope; ty; _ } -> scope = id && not (scalar ty)
         | _ -> false))

(* Experimental (docs/experiments/goose-comparison): unless
   ZANE_HOIST_HANDLES=0, the lists a loop's [body] indexes when nothing in
   it can change a list's handle -- it calls no function, calls the runtime
   only to index, spawns nothing, and writes only scalars -- each by the
   expression of its address, with the locals the body binds to such an
   expression. Each address is made of addresses and offsets of slots made
   before the loop, so it can be computed, and the list's items and count
   read, before the loop: its checks then compare with a count the loop does
   not change, which IRCE needs. *)
let invariant_lists body =
  if Sys.getenv_opt "ZANE_HOIST_HANDLES" = Some "0" then ([], Hashtbl.create 1)
  else
    let rec scalar (t : Ty.t) =
      match t with
      | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
      | Ty.Struct ts | Ty.Sum ts -> List.for_all scalar ts
      | Ty.Array (t, _) | Ty.Packed t -> scalar t
      | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> false
    in
    let bound = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace bound id ()
        | Stat.Assign { place; _ } -> Hashtbl.replace bound place.Expr.local ()
        | _ -> ())
      body;
    let names = Hashtbl.create 8 in
    let rec address (e : Expr.t) =
      match e.Expr.node with
      | Expr.Address x -> if Hashtbl.mem bound x then None else Some e
      | Expr.Local x -> (
          match Hashtbl.find_opt names x with
          | Some a -> Some a
          | None -> if Hashtbl.mem bound x then None else Some e)
      | Expr.Offset ({ base; _ } as o) ->
          Option.map (fun base -> { e with Expr.node = Expr.Offset { o with base } }) (address base)
      | _ -> None
    in
    let assigned = Hashtbl.create 8 in
    Cgt.Traverse.walk_stats ignore
      (function Stat.Assign { place; _ } -> Hashtbl.replace assigned place.Expr.local () | _ -> ())
      body;
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; value } when not (Hashtbl.mem assigned id) ->
            Option.iter (Hashtbl.replace names id) (address value)
        | _ -> ())
      body;
    let changes =
      Cgt.Traverse.exists_in body
        ~expr:(fun e ->
          match e.Expr.node with
          | Expr.Call _ | Expr.Call_value _ | Expr.Box _ | Expr.Escape _ | Expr.Take _ | Expr.Copy _ -> true
          | Expr.Runtime { fn; _ } -> (
              match fn with Cgt.Runtime.List_at | Array_at | Out_of_range -> false | _ -> true)
          | _ -> false)
        ~stat:(function
          | Stat.Spawn _ | Stat.Join _ -> true
          (* A local assigned is never part of a hoisted address ([bound]). *)
          | Stat.Assign { place; value } -> place.Expr.deref && not (scalar value.Expr.ty)
          | Stat.Store { value; _ } | Stat.Place { value; _ } | Stat.Overwrite { value; _ } -> not (scalar value.Expr.ty)
          | Stat.Hold { value; _ } -> not (scalar value.Expr.ty)
          | Stat.Reserve { ty; _ } -> not (scalar ty)
          | _ -> false)
    in
    if changes then ([], names)
    else begin
      let lists = ref [] in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at; args = l :: _ } -> (
              match address l with Some a when not (List.mem a !lists) -> lists := a :: !lists | _ -> ())
          | _ -> ())
        ignore body;
      (List.rev !lists, names)
    end

(* What a loop's [body] binds, which an index is read through: each
   local's [let] value, every assignment to each local, each local the body
   defines, and an expansion's result assigned once among the first
   statements of its body, with that value. *)
type facts = {
  lets : (int, Expr.t) Hashtbl.t;
  assigns : (int, Expr.place * Expr.t) Hashtbl.t;
  defined : (int, unit) Hashtbl.t;
  results : (int, Expr.t) Hashtbl.t;
}

let facts body =
  let lets = Hashtbl.create 16 and assigns = Hashtbl.create 16 and defined = Hashtbl.create 16 in
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Let { id; value } ->
          Hashtbl.replace lets id value;
          Hashtbl.replace defined id ()
      | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace defined id ()
      | Stat.Assign { place; value } -> Hashtbl.add assigns place.Expr.local (place, value)
      | _ -> ())
    body;
  let results = Hashtbl.create 16 in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Expand { body = eb; result = Some r; _ } ->
          let rec first = function
            | Stat.Let _ :: rest -> first rest
            | Stat.Assign { place = { Expr.local; path = []; deref = false; _ }; value } :: _ when local = r ->
                Hashtbl.replace results r value
            | _ -> ()
          in
          first eb
      | _ -> ())
    ignore body;
  { lets; assigns; defined; results }

(* [e] as a constant times the counter's step count plus an expression of
   what is known before the loop, when it is one: the constant, and the
   expression, which names the counter [x] itself where [e] does. *)
let rec affine f counter (e : Expr.t) =
  let i64 node = { Expr.node; ty = Ty.I64 } in
  match e.Expr.node with
  | Expr.Int _ -> Some (0, e)
  | Expr.Local y -> (
      match counter with
      | Some (x, step) when x = y -> Some (step, e)
      | _ -> (
          match (Hashtbl.find_all f.assigns y, Hashtbl.find_opt f.lets y) with
          | [], None -> if Hashtbl.mem f.defined y then None else Some (0, e)
          | [], Some v -> affine f counter v
          | [ _ ], None when Hashtbl.mem f.results y -> affine f counter (Hashtbl.find f.results y)
          | _ -> None))
  | Expr.Expand { result = Some r; _ } -> affine f counter (i64 (Expr.Local r))
  | Expr.Binary { op = Expr.Add; left; right } -> (
      match (affine f counter left, affine f counter right) with
      | Some (a, l), Some (c, r) -> Some (a + c, i64 (Expr.Binary { op = Expr.Add; left = l; right = r }))
      | _ -> None)
  | Expr.Binary { op = Expr.Mul; left; right } -> (
      match (affine f counter left, affine f counter right) with
      | Some (a, l), Some (0, ({ Expr.node = Expr.Int k; _ } as r))
      | Some (0, ({ Expr.node = Expr.Int k; _ } as r)), Some (a, l) ->
          Some (a * Int64.to_int k, i64 (Expr.Binary { op = Expr.Mul; left = l; right = r }))
      | _ -> None)
  | Expr.Flip v -> Option.map (fun (a, base) -> (-a, i64 (Expr.Flip base))) (affine f counter v)
  | _ -> None

(* The loop's counter and how far it moves each time round: the local its
   [body]'s last statement assigns its own value plus a constant ([Repeat]
   of `to`), assigned nowhere else in the body. *)
let counter f body =
  match List.rev body with
  | Stat.Assign { place = { Expr.local = x; path = []; deref = false; _ }; value } :: _
    when List.length (Hashtbl.find_all f.assigns x) = 1 && not (Hashtbl.mem f.defined x) -> (
      match affine f (Some (x, 0)) value with
      | Some (0, { Expr.node = Expr.Binary { op = Expr.Add; left = { Expr.node = Expr.Local y; _ }; right = { Expr.node = Expr.Int c; _ } }; _ })
        when y = x ->
          Some (x, Int64.to_int c)
      | _ -> None)
  | _ -> None

(* Experimental (docs/experiments/goose-comparison): with
   ZANE_LOOP_RANGES=1 as well, the element reads and writes of a loop's
   [body] whose list [invariant_lists] found and whose index moves by a
   constant -1, 0 or 1 each time round: each with that step and its index's
   value on the first time round, as an expression of what is known before
   the loop. The index's last value is then its first plus the step times
   one less than the count, and between them it passes through every value
   once, so the loop checks the two ends before it starts and, when both are
   in range, runs a copy of itself that checks none of these. The step is
   found from the loop's [counter]. *)
let ranged_accesses body lists names =
  let f = facts body in
  let counter = counter f body in
  match counter with
  | Some (_, step) when abs step <= 1 ->
      let found = ref [] in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ l; index; _ ] } -> (
              let key = match l.Expr.node with Expr.Local x -> Option.value ~default:l (Hashtbl.find_opt names x) | _ -> l in
              match affine f counter index with
              | Some (a, first) when abs a <= 1 && List.mem key lists -> found := (e, key, a, first) :: !found
              | _ -> ())
          | _ -> ())
        ignore body;
      !found
  | _ -> []

let ranged body lists names =
  if Sys.getenv_opt "ZANE_LOOP_RANGES" <> Some "1" || lists = [] then [] else ranged_accesses body lists names

(* Whether statements can end other than after their last, an expansion's
   own [Leave] inside them not counting (Cgt.Traverse.leaves). *)
let leaving = Cgt.Traverse.leaves

(* The stride of [s] when it is one push onto the list in [id]: an
   expansion whose own body makes the push, after nothing that may leave
   it, and names the list nowhere else. *)
let push_of id (s : Stat.t) =
  match s with
  | Stat.Eval { Expr.node = Expr.Expand { body; _ }; _ } ->
      let rec go before = function
        | Stat.Let
            {
              value =
                {
                  Expr.node =
                    Expr.Runtime
                      {
                        fn = Cgt.Runtime.List_push;
                        args = [ { Expr.node = Expr.Address l; _ }; { Expr.node = Expr.Int stride; _ } ];
                      };
                  _;
                };
              _;
            }
          :: after
          when l = id ->
            if List.exists (names id) (before @ after) || leaving before then None else Some stride
        | s :: rest -> go (s :: before) rest
        | [] -> None
      in
      go [] body
  | _ -> None

(* The runs of pushes in [body], each as the list's local and the pushes in
   it, when they are two or more: a new list's statement, then the pushes
   onto it that follow in [body] up to the first other statement that names
   it or may leave. Nothing else can reach a new list, so only those pushes add to it
   in the run, each at most once, and the run's first push, which comes
   before every other, can make room for all of them. *)
let runs body =
  let rec length id n = function
    | s :: rest -> (
        match push_of id s with
        | Some _ -> length id (n + 1) rest
        | None -> if names id s || leaving [ s ] then n else length id n rest)
    | [] -> n
  in
  let rec scan acc = function
    | (Stat.Hold { id; value; _ } | Stat.Let { id; value }) :: rest when fresh_list value ->
        let n = length id 0 rest in
        scan (if n >= 2 then (id, n) :: acc else acc) rest
    | _ :: rest -> scan acc rest
    | [] -> acc
  in
  scan [] body

(* Experimental (Loop_pushes, unless ZANE_LOOP_PUSHES=0): the lists a loop's
   [body] pushes onto once each time round, each with its stride: a push
   among [body]'s statements, unconditional, onto a list no other
   statement of [body] names. Room for every time round is made before the
   loop, and each push is then a plain store. *)
(* Whether [s] may change some list's count other than through its own
   local: a call of a function that may (Cgt.List_pure), which may be handed
   a reference to it, a spawned call, or the runtime pushing, making room in
   or removing from a list, which may be the same list reached through a
   reference. Room made for a loop's pushes would be taken by any of them. *)
let may_grow s =
  Cgt.Traverse.exists_in [ s ]
    ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Call { fn; _ } -> not (Hashtbl.mem Cgt.List_pure.functions fn)
      | Expr.Call_value _ | Expr.Foreign_call _ -> true
      | Expr.Runtime { fn; _ } -> (
          match fn with
          | Cgt.Runtime.List_push | List_room | List_reserve | List_remove _ | List_swap_remove _ | Overwrite | Copy
          | Promote | Arrive ->
              true
          | _ -> false)
      | _ -> false)
    ~stat:(function Stat.Spawn _ | Stat.Join _ | Stat.Overwrite _ -> true | _ -> false)

(* The statements of [s]'s expansion other than its push onto [id]: where
   the pushed value is made and moved in, which may grow the list through a
   reference as any other statement may. *)
let around id (s : Stat.t) =
  match s with
  | Stat.Eval { Expr.node = Expr.Expand { body; _ }; _ } ->
      List.filter
        (function
          | Stat.Let { value = { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_push; args = { Expr.node = Expr.Address l; _ } :: _ }; _ }; _ } ->
              l <> id
          | _ -> true)
        body
  | _ -> []

let looped_pushes body =
  if Sys.getenv_opt "ZANE_LOOP_PUSHES" = Some "0" then []
  else
    let lists =
      List.sort_uniq compare
        (List.filter_map
           (function
             | Stat.Eval { Expr.node = Expr.Expand { body; _ }; _ } ->
                 List.find_map
                   (function
                     | Stat.Let
                         {
                           value =
                             {
                               Expr.node =
                                 Expr.Runtime { fn = Cgt.Runtime.List_push; args = { Expr.node = Expr.Address l; _ } :: _ };
                               _;
                             };
                           _;
                         } ->
                         Some l
                     | _ -> None)
                   body
             | _ -> None)
           body)
    in
    List.filter_map
      (fun id ->
        match List.partition (fun s -> Option.is_some (push_of id s)) body with
        (* A loop that may leave early may push far fewer times than it
           could run, so room is made only for one that runs to the end. *)
        | [ s ], rest
          when not (List.exists (names id) rest || List.exists may_grow (rest @ around id s) || leaving body) ->
            Option.map (fun stride -> (id, stride)) (push_of id s)
        | _ -> None)
      lists

