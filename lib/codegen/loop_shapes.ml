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

(* The local whose slot [e], an address made of offsets into a slot, is in. *)
let rec slot_of (e : Expr.t) =
  match e.Expr.node with
  | Expr.Address x -> Some x
  | Expr.Offset { base; _ } -> slot_of base
  | _ -> None

(* The locals of [body], a function's, that are lists only it reaches: no
   parameter's, and their address is never given a call, bound, stored,
   converted, spawned or returned, only read through, indexed, or pushed
   to, made room in or removed from. So no address but one made from the
   local's own reaches its slot, and changing it changes no other list
   (Loop_shapes.invariant_lists). *)
let own_lists params body =
  let escaped = Hashtbl.create 8 and seen = Hashtbl.create 8 and lists = Hashtbl.create 8 in
  List.iter (fun (id, _) -> Hashtbl.replace escaped id ()) params;
  (* Only a slot a scope holds a list's handle in itself: a reference
     reaches a list other references may reach too. *)
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Hold { id; value = { Expr.ty = Ty.Handle | Ty.Handle16; _ }; _ } | Stat.Reserve { id; ty = Ty.Handle | Ty.Handle16; _ } ->
          Hashtbl.replace lists id ()
      | _ -> ())
    body;
  (* A local bound once to the address of a slot or of a member in it, as
     an inlined verb binds its subject: each use of it is a use of the
     slot's address. *)
  let assigned = Hashtbl.create 8 and aliases = Hashtbl.create 8 in
  Cgt.Traverse.walk_stats ignore
    (function Stat.Assign { place; _ } -> Hashtbl.replace assigned place.Expr.local () | _ -> ())
    body;
  Cgt.Traverse.walk_stats ignore
    (function
      | Stat.Let { id; value } when not (Hashtbl.mem assigned id) ->
          Option.iter (Hashtbl.replace aliases id) (slot_of value)
      | _ -> ())
    body;
  let rec expr ~safe (e : Expr.t) =
    match e.Expr.node with
    | Expr.Address x ->
        Hashtbl.replace seen x ();
        if not safe then Hashtbl.replace escaped x ()
    | Expr.Local a when Hashtbl.mem aliases a ->
        let x = Hashtbl.find aliases a in
        Hashtbl.replace seen x ();
        if not safe then Hashtbl.replace escaped x ()
    | Expr.Offset { base; _ } -> expr ~safe base
    | Expr.Deref a -> expr ~safe:true a
    | Expr.Call { fn; args = list :: rest } when Hashtbl.mem Cgt.List_pure.pushers fn ->
        expr ~safe:true list;
        List.iter (expr ~safe:false) rest
    | Expr.Runtime
        {
          fn =
            ( Cgt.Runtime.List_at | List_push | List_room | List_reserve | List_remove _ | List_swap_remove _ ) as fn;
          args = list :: rest;
        } ->
        ignore fn;
        expr ~safe:true list;
        List.iter (expr ~safe:false) rest
    | _ ->
        let es, bodies = Cgt.Traverse.expr_parts e in
        List.iter (expr ~safe:false) es;
        List.iter (List.iter stat) bodies
  and stat (s : Stat.t) =
    let es, bodies = Cgt.Traverse.stat_parts s in
    (match s with
    | Stat.Store { address; value } | Stat.Place { address; value; _ } | Stat.Overwrite { address; value; _ } ->
        expr ~safe:true address;
        expr ~safe:false value
    | Stat.Let { id; value } when Hashtbl.mem aliases id -> expr ~safe:true value
    | _ -> List.iter (expr ~safe:false) es);
    List.iter (List.iter stat) bodies
  in
  List.iter stat body;
  fun x -> Hashtbl.mem lists x && Hashtbl.mem seen x && not (Hashtbl.mem escaped x)

(* How many elements deep the address [e] is: 0 for one made only of
   addresses and offsets of slots. *)
let rec depth (e : Expr.t) =
  match e.Expr.node with
  | Expr.Runtime { fn = Cgt.Runtime.List_at; args = l :: _ } -> 1 + depth l
  | Expr.Offset { base; _ } -> depth base
  | _ -> 0

(* Whether the address [e] is reached through an element of a list. *)
let through_element e = depth e > 0

let element (a : Expr.t) = match a.Expr.node with Expr.Runtime _ -> true | _ -> false

(* Whether the address [a] reaches no variant's payload: each offset in it
   goes through struct members only. A payload of a case that is not the
   variant's holds other bytes, so an element read through it before the
   loop would follow a pointer that is not one. *)
let rec members_only (a : Expr.t) =
  let rec path (t : Ty.t) = function
    | [] -> true
    | i :: rest -> (
        match t with
        | Ty.Struct ts | Ty.Packed (Ty.Struct ts) -> ( match List.nth_opt ts i with Some t -> path t rest | None -> false)
        | _ -> false)
  in
  match a.Expr.node with
  | Expr.Offset { base; within; path = p } -> path within p && members_only base
  | Expr.Runtime { fn = Cgt.Runtime.List_at; args = l :: _ } -> members_only l
  | _ -> true

(* Experimental (docs/experiments/goose-comparison): unless
   ZANE_HOIST_HANDLES=0, the lists a loop's [body] indexes when nothing in
   it can change their handles, each by the expression of its address,
   with the locals the body binds to such an expression. Nothing in the
   body changes a handle (Cgt.List_pure.changes): it calls only functions
   that cannot, calls into C only where C cannot call back, spawns
   nothing, writes only scalars through addresses, and calls the runtime
   only to index, or to push to, make room in or remove from a list of
   [own]'s, which reaches no other list's slot; such a list is not among
   those read. Each address is made of addresses and offsets of slots made
   before the loop, or, where the body pushes or calls, is an element of
   such a list at an index the loop does not change, so it can be computed,
   and the list's items and count read, before the loop: its checks then compare with a count the loop
   does not change, which IRCE needs. *)
let invariant_lists ?(own = fun _ -> false) body =
  if Sys.getenv_opt "ZANE_HOIST_HANDLES" = Some "0" then ([], Hashtbl.create 1)
  else
    let bound = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace bound id ()
        | Stat.Assign { place; _ } -> Hashtbl.replace bound place.Expr.local ()
        | _ -> ())
      body;
    (* The locals whose slot's address the body uses other than to read
       it, as a call of a verb that changes its subject does: the body may
       change them, so an index they hold may change too. *)
    let addressed = Hashtbl.create 8 in
    let rec expr ~read (e : Expr.t) =
      match e.Expr.node with
      | Expr.Address x -> if not read then Hashtbl.replace addressed x ()
      | Expr.Deref a -> expr ~read:true a
      | _ ->
          let es, bodies = Cgt.Traverse.expr_parts e in
          List.iter (expr ~read:false) es;
          List.iter (List.iter stat) bodies
    and stat (s : Stat.t) =
      let es, bodies = Cgt.Traverse.stat_parts s in
      List.iter (expr ~read:false) es;
      List.iter (List.iter stat) bodies
    in
    List.iter stat body;
    let fixed x = not (Hashtbl.mem bound x || Hashtbl.mem addressed x) in
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
      | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ list; index; ({ Expr.node = Expr.Int _; _ } as stride) ] } -> (
          let invariant =
            match index.Expr.node with
            | Expr.Int _ -> Some index
            | Expr.Local x -> (
                match Hashtbl.find_opt names x with
                | Some ({ Expr.node = Expr.Local y; _ } as a) when fixed y -> Some a
                | Some _ -> None
                | None -> if fixed x then Some index else None)
            | _ -> None
          in
          match (address list, invariant) with
          | Some list, Some index -> Some { e with Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ list; index; stride ] } }
          | _ -> None)
      (* An expansion that computes an address, as an inlined indexing
         verb does, and assigns it to its result. *)
      | Expr.Expand { body; result = Some r; _ } ->
          List.find_map
            (function
              | Stat.Assign { place; value } when place.Expr.local = r && not place.Expr.deref -> Some value
              | _ -> None)
            body
          |> Fun.flip Option.bind address
      | _ -> None
    in
    let assigned = Hashtbl.create 8 in
    Cgt.Traverse.walk_stats ignore
      (function Stat.Assign { place; _ } -> Hashtbl.replace assigned place.Expr.local () | _ -> ())
      body;
    (* A local can name an address made from locals bound inside its own
       value, so the names are gathered until none is added. *)
    let rec gather () =
      let before = Hashtbl.length names in
      Cgt.Traverse.walk_stats ignore
        (function
          | Stat.Let { id; value } when not (Hashtbl.mem assigned id || Hashtbl.mem names id) ->
              Option.iter (Hashtbl.replace names id) (address value)
          | _ -> ())
        body;
      if Hashtbl.length names > before then gather ()
    in
    gather ();
    let changed = Hashtbl.create 4 in
    let slot_of (e : Expr.t) =
      match e.Expr.node with
      | Expr.Local x -> Option.bind (Hashtbl.find_opt names x) slot_of
      | _ -> slot_of e
    in
    let allowed fn (args : Expr.t list) =
      match (fn, args) with
      | (Cgt.Runtime.List_push | List_room | List_reserve | List_remove { scalars = true } | List_swap_remove { scalars = true }), list :: _ -> (
          match slot_of list with
          | Some x when own x ->
              Hashtbl.replace changed x ();
              true
          | _ -> false)
      | _ -> false
    in
    let pushes_own (e : Expr.t) =
      match e.Expr.node with
      | Expr.Call { fn; args = list :: _ } when Hashtbl.mem Cgt.List_pure.pushers fn -> (
          match slot_of list with
          | Some x when own x ->
              Hashtbl.replace changed x ();
              true
          | _ -> false)
      | _ -> false
    in
    let changes =
      Cgt.Traverse.exists_in body
        ~expr:(fun e -> (not (pushes_own e)) && Cgt.List_pure.changes_expr ~allowed e)
        ~stat:Cgt.List_pure.changes_stat
    in
    (* Whether the body pushes or calls at all: where it does not, LLVM sees
       for itself that an element's handle stays, and reads it once. *)
    let acts =
      Cgt.Traverse.exists_in body
        ~expr:(fun e ->
          match e.Expr.node with
          | Expr.Call _ | Expr.Foreign_call _ -> true
          | Expr.Runtime { fn = Cgt.Runtime.List_at | Array_at | Out_of_range; _ } -> false
          | Expr.Runtime _ -> true
          | _ -> false)
        ~stat:(fun _ -> false)
    in
    if changes then ([], names)
    else begin
      let rec root (e : Expr.t) =
        match e.Expr.node with
        | Expr.Address x | Expr.Local x -> Some x
        | Expr.Offset { base; _ } -> root base
        | Expr.Runtime { fn = Cgt.Runtime.List_at; args = list :: _ } -> root list
        | _ -> None
      in
      let lists = ref [] in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at; args = l :: _ } -> (
              match address l with
              | Some a when not (List.mem a !lists || match root a with Some x -> Hashtbl.mem changed x | None -> true) ->
                  lists := a :: !lists
              | _ -> ())
          | _ -> ())
        ignore body;
      (* A list before the elements of it that are read, and an element
         before the members and elements of it; emitted before the loop
         without a check (an index out of range gives an empty element). *)
      let lists = List.rev !lists in
      let plain = List.filter (fun a -> depth a = 0) lists in
      let elements =
        List.filter (fun a -> depth a > 0 && members_only a && (acts || not (element a))) lists
        |> List.stable_sort (fun a b -> compare (depth a) (depth b))
      in
      (plain @ elements, names)
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

(* Whether a loop's [body] reads or writes an element at an index it steps
   itself, apart from the loop's counter: a local the body assigns once, to
   itself plus a constant, with a constant added or not. Such an index
   moves by a constant each time round, which IRCE needs to take a check
   out of a loop, while the counter only bounds the loop, the shape a scan
   whose real stop is a test has ([searches]). An index that halves or
   jumps, as a heap's sift moves, IRCE cannot use; one that is the counter
   walks the range the count names, where IRCE's split pays when the loop
   runs long. *)
let scans body =
  let f = facts body in
  let counter = Option.map fst (counter f body) in
  let steps y =
    Some y <> counter
    &&
    match Hashtbl.find_all f.assigns y with
    | [ ({ Expr.path = []; deref = false; _ }, value) ] when not (Hashtbl.mem f.defined y) -> (
        match affine f (Some (y, 0)) value with
        | Some
            ( 0,
              {
                Expr.node =
                  Expr.Binary
                    {
                      op = Expr.Add;
                      left = { Expr.node = Expr.Local x; _ };
                      right = { Expr.node = Expr.Int _ | Expr.Flip { Expr.node = Expr.Int _; _ }; _ };
                    };
                _;
              } )
          when x = y ->
            true
        | _ -> false)
    | _ -> false
  in
  let rec index (e : Expr.t) =
    match e.Expr.node with
    | Expr.Local y -> (
        match (Hashtbl.find_all f.assigns y, Hashtbl.find_opt f.lets y) with
        | [], Some v -> index v
        | [ _ ], None when Hashtbl.mem f.results y -> index (Hashtbl.find f.results y)
        | _ -> steps y)
    | Expr.Expand { result = Some r; _ } -> index { e with Expr.node = Expr.Local r }
    | Expr.Binary { op = Expr.Add; left; right = { Expr.node = Expr.Int _ | Expr.Flip { Expr.node = Expr.Int _; _ }; _ } } ->
        index left
    | _ -> false
  in
  Cgt.Traverse.exists_in body
    ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Runtime { fn = Cgt.Runtime.List_at | Cgt.Runtime.Array_at; args = _ :: i :: _ } -> index i
      | _ -> false)
    ~stat:(fun _ -> false)

(* Whether a loop with [body] is a search, which an optimized build weights
   as going round 4 times (Emit.short_trips) so IRCE leaves it whole: it
   can leave early, holds no loop, and reads or writes an element at an
   index it steps by a constant itself, apart from its counter ([scans]).
   Its count is then only a ceiling, as `core`'s `to` with a `return` or
   `guard` in it has (spec control-flow.md §3.5), and it usually stops long
   before. Unweighted, IRCE split it on LLVM's guess, and the split's
   setup, about 25 instructions on each entry, cost LangArena's
   Sort::Quick, whose partition scans stop after an element or two, 27%
   more instructions. Every other loop keeps its old shape. Weighting a
   loop IRCE cannot split only changes how LLVM lays it out: `tests/perf`
   `floats`' escape test, arithmetic alone, took 10.5% more estimated
   cycles, and LangArena's Graph::AStar, whose heap sift halves its index,
   4.3% more instructions. A loop indexed by its counter walks the range
   its count names, and IRCE's split pays when it runs long: weighted,
   Distance::Jaro's match-window search ran 2% more instructions. A loop
   around another may go round many times between the inner loop's exits.
   Unlike a versioned loop's short copy, a search still reads ahead
   (Lookahead). *)
let searches body =
  Cgt.Traverse.leaves body
  && (not (Cgt.Traverse.exists_in body ~expr:(fun _ -> false) ~stat:(function Stat.Repeat _ -> true | _ -> false)))
  && scans body

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
      | Expr.Call_value _ -> true
      | Expr.Foreign_call _ -> not !Cgt.List_pure.c_stays
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

