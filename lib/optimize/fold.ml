(* Folding one function from the leaves up (docs/design/optimization.md O6).

   The walk goes through a body in the order it runs and keeps what it knows:
   each local whose value is a constant here. An expression whose inputs are
   all known is evaluated and replaced by its value, with any output it made
   and any local it wrote put back in front of it. Its parent is tried next,
   with the replacement as an input. A control statement whose reads are all
   known is run as a whole, so a loop over known values leaves only what it
   wrote. Whatever does not fold stays as it was, and what it may write is
   no longer known after it. A run of statements that makes a list or a box,
   changes it and is done with it, which no statement of it leaves known, is
   evaluated whole and replaced by what it left. *)

open Cgt.Nodes
module V = Value

(* ---------------------------------------------------------------------- *)
(* Walking the tree                                                       *)
(* ---------------------------------------------------------------------- *)

module Traverse = Cgt.Traverse

(* The expressions directly in an expression, in the order they run; an
   expansion's body is a statement list, which a walk reaches on its own. *)
let children e = fst (Traverse.expr_parts e)

(* Every expression and statement in a run of statements, nested ones
   included. *)
let iter_stats ~expr ~stat body = Traverse.walk_stats expr stat body
let iter_stat ~expr ~stat s = Traverse.walk_stat expr stat s
let iter_expr ~expr ~stat e = Traverse.walk_expr expr stat e

let nothing _ = ()

(* Each number a function uses for a local, a label, an arena or a task,
   which a new one must not take. *)
let largest (f : Func.t) =
  let n = ref 0 in
  let see i = n := max !n i in
  List.iter (fun (id, _) -> see id) f.Func.params;
  iter_stats f.Func.body
    ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Local i | Expr.Address i -> see i
      | Expr.Expand { label; result; _ } ->
          see label;
          Option.iter see result
      | Expr.Escape { exit = Some l; _ } -> see l
      | _ -> ())
    ~stat:(function
      | Stat.Let { id; _ } | Stat.Hold { id; _ } -> see id
      | Stat.Scope { id; _ } | Stat.Join id | Stat.Leave id -> see id
      | Stat.Reserve { id; scope; _ } ->
          see id;
          see scope
      | Stat.Spawn { task; scope; dest; _ } ->
          see task;
          see scope;
          Option.iter see dest
      | Stat.Assign { place; _ } -> see place.Expr.local
      | _ -> ());
  !n

(* The locals named outside the run of statements that binds them. Folding
   code removes the locals it binds, which is safe only when nothing outside
   that code names them: whatever binds a local and folds holds the whole
   run that binds it, and with it every name of a local not in this set. *)
let wide (f : Func.t) =
  let bound = Hashtbl.create 64 in
  let named = ref [] in
  let serial = ref 0 in
  let rec run chain body =
    incr serial;
    let chain = !serial :: chain in
    List.iter (stat chain) body
  and stat chain s =
    (match s with
    | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace bound id (List.hd chain)
    | Stat.Spawn { task; dest; _ } ->
        Hashtbl.replace bound task (List.hd chain);
        Option.iter (fun d -> Hashtbl.replace bound d (List.hd chain)) dest
    | Stat.Assign { place; _ } -> named := (place.Expr.local, chain) :: !named
    | Stat.Join task -> named := (task, chain) :: !named
    | _ -> ());
    let es, bodies = Traverse.stat_parts s in
    List.iter (expr chain) es;
    List.iter (run chain) bodies
  and expr chain (e : Expr.t) =
    (match e.Expr.node with
    | Expr.Local i | Expr.Address i -> named := (i, chain) :: !named
    | Expr.Expand { body; result; _ } ->
        incr serial;
        let inner = !serial :: chain in
        Option.iter (fun r -> Hashtbl.replace bound r (List.hd inner)) result;
        List.iter (stat inner) body
    | _ -> ());
    List.iter (expr chain) (children e)
  in
  run [] f.Func.body;
  let w = Hashtbl.create 16 in
  List.iter
    (fun (i, chain) ->
      match Hashtbl.find_opt bound i with
      | Some b when not (List.mem b chain) -> Hashtbl.replace w i ()
      | _ -> ())
    !named;
  w

(* What the addresses of a function's locals can reach: [escaped] is each
   local an address of which may be kept past the code that takes it, and
   [points] each pointer local bound to the address of one local, or of a
   member of it, by that local.

   A local of a value type that is not escaped is reached only where an
   address of it is taken and used at once: lent to a call, read, moved out
   of or stored through. No reference names it (memory.md §2.4), and a borrow
   ends with its call (§2.9), so code given no address of it cannot write it.
   Its address is kept when it is stored, returned, or held by a spawned call
   until the call is joined, and every address of a local of any other type
   counts as kept: a call it is lent to may make a reference to it and leave
   that where other code finds it. *)
type reach = { escaped : (int, unit) Hashtbl.t; points : (int, int) Hashtbl.t }

(* Whether a value of this type holds an address. *)
let rec addresses (t : Ty.t) =
  match t with
  | Ty.Ptr | Ty.Ref | Ty.Box32 -> true
  | Ty.Struct ts | Ty.Sum ts -> List.exists addresses ts
  | Ty.Array (t, _) | Ty.Packed t -> addresses t
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 | Ty.Handle | Ty.Handle32 | Ty.Handle16 -> false

let reach (f : Func.t) =
  let values = Hashtbl.create 16 in
  List.iter (fun i -> Hashtbl.replace values i ()) f.Func.values;
  (* A pointer local stands for the local it points into when one [Let]
     binds it and nothing else stores into it or takes its address. A store
     through it writes what it points into, which [writes] counts. *)
  let lets = Hashtbl.create 16 and barred = Hashtbl.create 16 in
  iter_stats f.Func.body
    ~expr:(fun e -> match e.Expr.node with Expr.Address i -> Hashtbl.replace barred i () | _ -> ())
    ~stat:(function
      | Stat.Let { id; _ } ->
          Hashtbl.replace lets id (1 + Option.value ~default:0 (Hashtbl.find_opt lets id))
      | Stat.Assign { place; _ } when not place.Expr.deref ->
          Hashtbl.replace barred place.Expr.local ()
      | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace barred id ()
      | _ -> ());
  let points = Hashtbl.create 16 in
  let rec target (e : Expr.t) =
    match e.Expr.node with
    | Expr.Address i -> Some i
    | Expr.Local p -> Hashtbl.find_opt points p
    | Expr.Offset { base; _ } -> target base
    | _ -> None
  in
  iter_stats f.Func.body ~expr:nothing ~stat:(function
    | Stat.Let { id; value }
      when value.Expr.ty = Ty.Ptr
           && Hashtbl.find_opt lets id = Some 1
           && not (Hashtbl.mem barred id) ->
        Option.iter (Hashtbl.replace points id) (target value)
    | _ -> ());
  let escaped = Hashtbl.create 16 and kept = Hashtbl.create 16 in
  (* [used] is whether an address in this position is used where it is
     made. An address a call gives, alone or in an aggregate, may be a
     member of one it was given, so it is used where the call's own value
     is. *)
  let rec expr used (e : Expr.t) =
    match e.Expr.node with
    | Expr.Address i ->
        Hashtbl.replace escaped i ();
        if not used then Hashtbl.replace kept i ()
    | Expr.Local p -> (
        match Hashtbl.find_opt points p with
        | Some i when not used -> Hashtbl.replace kept i ()
        | _ -> ())
    | Expr.Offset { base; _ } -> expr used base
    | Expr.Call { args; _ } | Expr.Runtime { args; _ } ->
        List.iter (expr (used || not (addresses e.Expr.ty))) args
    | Expr.Call_value { fn; args } ->
        expr false fn;
        List.iter (expr (used || not (addresses e.Expr.ty))) args
    | Expr.Deref x | Expr.Snapshot x | Expr.Take { address = x; _ } -> expr true x
    | _ ->
        let es, bodies = Traverse.expr_parts e in
        List.iter (expr false) es;
        List.iter (List.iter stat) bodies
  and stat (s : Stat.t) =
    match s with
    | Stat.Let { id; value } -> expr (Hashtbl.mem points id) value
    | Stat.Eval e -> expr true e
    | Stat.Store { address; value }
    | Stat.Overwrite { address; value; _ }
    | Stat.Place { address; value; _ } ->
        expr true address;
        expr false value
    | _ ->
        let es, bodies = Traverse.stat_parts s in
        List.iter (expr false) es;
        List.iter (List.iter stat) bodies
  in
  List.iter stat f.Func.body;
  Hashtbl.filter_map_inplace
    (fun i () -> if Hashtbl.mem values i && not (Hashtbl.mem kept i) then None else Some ())
    escaped;
  { escaped; points }

(* The locals a run of statements may change: those it stores in, whose
   address it takes, or that it binds, and the local each pointer it names
   points into. Through an address it may also change any escaped local. *)
let writes ~reach ?expr stats =
  let w = Hashtbl.create 16 in
  let through = ref false in
  let pointed p = Option.iter (fun i -> Hashtbl.replace w i ()) (Hashtbl.find_opt reach.points p) in
  let on_expr (e : Expr.t) =
    match e.Expr.node with
    | Expr.Address i -> Hashtbl.replace w i ()
    | Expr.Local p -> pointed p
    | Expr.Expand { result = Some r; _ } -> Hashtbl.replace w r ()
    | Expr.Call _ | Expr.Call_value _ | Expr.Runtime _ | Expr.Take _ -> through := true
    | _ -> ()
  in
  let on_stat = function
    | Stat.Assign { place; _ } ->
        Hashtbl.replace w place.Expr.local ();
        if place.Expr.deref then begin
          pointed place.Expr.local;
          through := true
        end
    | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace w id ()
    | Stat.Spawn { task; dest; _ } ->
        Hashtbl.replace w task ();
        Option.iter (fun d -> Hashtbl.replace w d ()) dest;
        through := true
    | Stat.Store _ | Stat.Overwrite _ | Stat.Place _ -> through := true
    | _ -> ()
  in
  Option.iter (iter_expr ~expr:on_expr ~stat:on_stat) expr;
  iter_stats ~expr:on_expr ~stat:on_stat stats;
  if !through then Hashtbl.iter (fun i () -> Hashtbl.replace w i ()) reach.escaped;
  w

let leaves label stats =
  let found = ref false in
  iter_stats stats ~expr:nothing ~stat:(function Stat.Leave l when l = label -> found := true | _ -> ());
  !found

(* ---------------------------------------------------------------------- *)
(* The fold                                                               *)
(* ---------------------------------------------------------------------- *)

type known = (int, V.const * Ty.t) Hashtbl.t

type fn = {
  prog : Eval.program;
  (* Calls with constant arguments that did not fold, which are not tried
     again. *)
  failed : unit V.Key.t;
  mutable next : int;
  (* Locals bound by a plain [Let] of a type that holds no handle or address
     anywhere, so owns nothing: an [Assign] can store a new value in them.
     An owner whose arena was folded away (Regions) is bound by a [Let] too,
     and an assignment would leave the blocks it owns behind. *)
  plain : (int, unit) Hashtbl.t;
  (* Locals of a value type held in a scope's arena whose address is never
     kept (reach), by layout: an [Overwrite] can store a new value in them. *)
  held : (int, Layout.t) Hashtbl.t;
  wide : (int, unit) Hashtbl.t;
  reach : reach;
}

let fresh fn =
  fn.next <- fn.next + 1;
  fn.next

let forget (env : known) ids = Hashtbl.iter (fun i () -> Hashtbl.remove env i) ids

(* The value an expression is known to have: a constant's, or that of an
   expansion the fold made, which outputs and then gives a constant. *)
let known_value (e : Expr.t) =
  match (Materialize.const e, e.Expr.node) with
  | Some c, _ -> Some c
  | None, Expr.Expand { label; body; result = Some r } -> (
      match List.rev body with
      | Stat.Assign { place = { local; deref = false; path = []; _ }; value } :: _
        when local = r && not (leaves label body) ->
          Materialize.const value
      | _ -> None)
  | None, _ -> None

(* Whether an expression is what [attempt] replaces code with: outputs and
   constants stored into locals, whose values the walk already knows. *)
let replayed (e : Expr.t) =
  match e.Expr.node with
  | Expr.Expand { label; body; _ } ->
      (not (leaves label body))
      && List.for_all
           (function
             | Stat.Eval { Expr.node = Expr.Runtime { fn; args }; _ } ->
                 Intrinsics.classify fn = Intrinsics.Output && List.for_all Materialize.literal args
             | Stat.Assign { place = { deref = false; path = []; _ }; value }
             | Stat.Overwrite { address = { Expr.node = Expr.Address _; _ }; value; _ } ->
                 Materialize.literal value
             | _ -> false)
           body
  | _ -> false

(* Whether an input of an expression is known: a constant, a local the walk
   knows, or an address made from them. A replacement that stores into a
   local is not: the walk already counts the store as done, so evaluating
   it again inside its parent would find nothing to store, and the parent's
   replacement would leave the store out. *)
let rec known_input (env : known) (e : Expr.t) =
  (match e.Expr.node with
  | Expr.Expand { body; _ } -> (
      known_value e <> None
      &&
      match List.rev body with
      | _ :: before -> List.for_all (function Stat.Eval _ -> true | _ -> false) before
      | [] -> true)
  | _ -> Materialize.literal e)
  ||
  match e.Expr.node with
  | Expr.Local i | Expr.Address i -> Hashtbl.mem env i
  | Expr.Global _ | Expr.Layout _ | Expr.Function _ -> true
  | Expr.Offset { base; _ } -> known_input env base
  | Expr.Call { args; _ } | Expr.Runtime { args; _ } when e.Expr.ty = Ty.Ptr ->
      List.for_all (known_input env) args
  | _ -> false

(* Whether a run of statements still calls or loops after it was folded,
   which is what makes evaluating it again cost more than a lookup. *)
let costly stats =
  let found = ref false in
  iter_stats stats
    ~expr:(fun e ->
      match e.Expr.node with Expr.Call _ | Expr.Call_value _ -> found := true | _ -> ())
    ~stat:(function Stat.Repeat _ | Stat.Spawn _ | Stat.Join _ -> found := true | _ -> ());
  !found

(* A known value stored back into a local that folded code wrote: assigned to
   a plain local, and overwritten in a held one, which returns the blocks
   its old value owned, as an assignment to it does when the program runs. *)
let store_back fn id ty c =
  Option.bind (Materialize.expr ~fresh:(fun () -> fresh fn) ty c) (fun value ->
      if Hashtbl.mem fn.plain id then Some (Stat.assign id value)
      else
        Option.map
          (fun layout ->
            let address = { Expr.node = Expr.Address id; ty = Ty.Ptr } in
            Stat.Overwrite { address; value; layout })
          (Hashtbl.find_opt fn.held id))

let storable fn id = Hashtbl.mem fn.plain id || Hashtbl.mem fn.held id

let call_key (e : Expr.t) =
  match e.Expr.node with
  | Expr.Call { fn; args } ->
      let consts = List.map Materialize.const args in
      if List.for_all Option.is_some consts then Some (fn, List.map Option.get consts) else None
  | _ -> None

(* What a run that finished did to the function being folded, as
   statements: its outputs, then each known local it wrote stored back. The
   locals it bound itself must not be named anywhere else, since the code
   that bound them is gone. [value] is the size of the value the
   replacement gives, which the size cap counts with the rest of it. *)
let effects ?(value = 0) fn (env : known) (run : Eval.run) (fr : Eval.frame) =
  if Eval.wrote_globals run then V.stop "a variable of the program written";
  let assigns = ref [] in
  Eval.Locals.iter
    (fun id (c : V.cell) ->
      match c.V.origin with
      | V.Outer _ -> (
          let before = Option.map fst (Hashtbl.find_opt env id) in
          match V.export c.V.value with
          | Some now when Option.fold ~none:false ~some:(V.same now) before -> ()
          | Some now when storable fn id -> (
              match store_back fn id c.V.ty now with
              | Some s -> assigns := (id, now, c.V.ty, s) :: !assigns
              | None -> V.stop "a written local whose value cannot be stored back")
          | _ -> V.stop "a written local that cannot be stored back")
      | _ -> if Hashtbl.mem fn.wide id then V.stop "a local bound here and named elsewhere")
    fr.Eval.locals;
  let outputs = List.rev run.Eval.outputs in
  let size =
    List.fold_left (fun n o -> n + Materialize.output_size o) value outputs
    + List.fold_left (fun n (_, now, _, _) -> n + V.size now) 0 !assigns
  in
  if size > Materialize.max_size then V.stop "a replacement larger than the size cap";
  let assigns = List.sort compare !assigns in
  (List.map Materialize.output outputs, assigns)

let commit (env : known) assigns =
  List.iter (fun (id, c, ty, _) -> Hashtbl.replace env id (c, ty)) assigns;
  List.map (fun (_, _, _, s) -> s) assigns

let frame (env : known) =
  { Eval.locals = Eval.Locals.create (); outer = Some (fun id -> Hashtbl.find_opt env id) }

(* An expression evaluated where it is, and what replaces it. *)
let attempt fn (env : known) (e : Expr.t) : Expr.t option =
  let run = Eval.start fn.prog in
  let fr = frame env in
  match
    let v = Eval.expr run fr e in
    let c = match V.export v with Some c -> c | None -> V.stop "a value that lives somewhere" in
    let size = V.size c in
    if size > Materialize.max_size then V.stop "a value larger than the size cap";
    (* A read is cheaper than a list or a box made again. *)
    (match e.Expr.node with
    | Expr.Local _ | Expr.Deref _ | Expr.Snapshot _ | Expr.Member _ | Expr.Payload _
      when V.owns_block c ->
        V.stop "a read of a value that owns a block"
    | _ -> ());
    let value =
      match Materialize.expr ~fresh:(fun () -> fresh fn) e.Expr.ty c with
      | Some value -> value
      | None -> V.stop "a value that cannot be written as code"
    in
    let outputs, assigns = effects ~value:size fn env run fr in
    (value, outputs, assigns)
  with
  | value, [], [] -> Some value
  | value, outputs, assigns ->
      let stores = commit env assigns in
      let label = fresh fn in
      let body, result =
        if e.Expr.ty = Ty.Void then (outputs @ stores, None)
        else
          let r = fresh fn in
          (outputs @ stores @ [ Stat.assign r value ], Some r)
      in
      Some { Expr.node = Expr.Expand { label; body; result }; ty = e.Expr.ty }
  | exception (V.Stop _ | Eval.Left _ | Eval.Returned _) ->
      Option.iter (fun k -> V.Key.replace fn.failed k ()) (call_key e);
      None

(* A statement run where it is, and the statements that replace it. *)
let attempt_stat fn (env : known) (s : Stat.t) : Stat.t list option =
  let run = Eval.start fn.prog in
  let fr = frame env in
  match
    Eval.stat run fr s;
    effects fn env run fr
  with
  | outputs, assigns -> Some (outputs @ commit env assigns)
  | exception (V.Stop _ | Eval.Left _ | Eval.Returned _) -> None

(* ---------------------------------------------------------------------- *)
(* A run of statements                                                    *)
(* ---------------------------------------------------------------------- *)

(* The last statement of a block that names each local, binding it,
   reading it, storing into it or taking its address, by the statement's
   index. *)
let last_named stats =
  let last = Hashtbl.create 32 in
  Array.iteri
    (fun i s ->
      let see id = Hashtbl.replace last id i in
      iter_stat s
        ~expr:(fun e ->
          match e.Expr.node with
          | Expr.Local id | Expr.Address id -> see id
          | Expr.Expand { result = Some r; _ } -> see r
          | _ -> ())
        ~stat:(function
          | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } | Stat.Join id ->
              see id
          | Stat.Assign { place; _ } -> see place.Expr.local
          | Stat.Spawn { task; dest; _ } ->
              see task;
              Option.iter see dest
          | _ -> ()))
    stats;
  last

(* Whether a type holds a handle or an address anywhere: a value of it
   lives in part somewhere a constant written as a [Let] does not say. *)
let rec holds_ref (t : Ty.t) =
  match t with
  | Ty.Handle | Ty.Handle32 | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> true
  | Ty.Struct ts | Ty.Sum ts -> List.exists holds_ref ts
  | Ty.Array (t, _) | Ty.Packed t -> holds_ref t
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> false

(* Whether a run of statements binds a local of such a type. *)
let binds_ref stats =
  let found = ref false in
  let see (t : Ty.t) = if holds_ref t then found := true in
  iter_stats stats
    ~expr:(fun e ->
      match e.Expr.node with Expr.Expand { result = Some _; _ } -> see e.Expr.ty | _ -> ())
    ~stat:(function
      | Stat.Let { value; _ } | Stat.Hold { value; _ } -> see value.Expr.ty
      | Stat.Reserve { ty; _ } -> see ty
      | _ -> ());
  !found

(* Whether a value owns a list or a box. *)
let rec holds_block (v : V.v) =
  match v with
  | V.VList _ | V.VPtr { owned = true; _ } -> true
  | V.VRecord a -> Array.exists holds_block a
  | V.VCase (_, p) -> holds_block p
  | _ -> false

(* Where a run of statements could end: how many statements it has, what it
   output, each known local it wrote, and each local it bound that a later
   statement names, with the value it holds there. *)
type mark = {
  length : int;
  outputs : Eval.output list;
  stores : (int * V.const * Ty.t) list;
  lets : (int * V.const * Ty.t) list;
}

(* The mark after the first [length] statements of a run, or [None] where
   the run cannot end. It ends only where the code it replaces dropped a
   list or a box it made: a run that does not is folded as well statement
   by statement. Each local the run bound that a later statement names must
   hold a value a [Let] can give, since the code that bound it is gone. *)
let mark fn (env : known) (run : Eval.run) (fr : Eval.frame) ~named_after ~length ~outputs_size =
  if Eval.wrote_globals run then None
  else
    match
      let stores = ref [] and lets = ref [] and drops = ref false in
      Eval.Locals.iter
        (fun id (c : V.cell) ->
          match c.V.origin with
          | V.Outer _ -> (
              Eval.bytes run (V.weight c.V.value);
              let before = Option.map fst (Hashtbl.find_opt env id) in
              match V.export c.V.value with
              | Some now when Option.fold ~none:false ~some:(V.same now) before -> ()
              | Some now when storable fn id -> stores := (id, now, c.V.ty) :: !stores
              | _ -> V.stop "a written local that cannot be stored back")
          | _ when Hashtbl.mem fn.wide id -> V.stop "a local bound here and named elsewhere"
          | _ when named_after id -> (
              if holds_ref c.V.ty then V.stop "a local named after the run that lives elsewhere";
              match V.export c.V.value with
              | Some now -> lets := (id, now, c.V.ty) :: !lets
              | None -> V.stop "a local named after the run with no constant value")
          | _ -> if holds_block c.V.value then drops := true)
        fr.Eval.locals;
      let size =
        List.fold_left (fun n (_, now, _) -> n + V.size now) outputs_size (!stores @ !lets)
      in
      if size > Materialize.max_size then V.stop "a replacement larger than the size cap";
      if not !drops then V.stop "a run that drops no list or box";
      let stores = List.sort compare !stores and lets = List.sort compare !lets in
      { length; outputs = run.Eval.outputs; stores; lets }
    with
    | m -> Some m
    | exception V.Stop _ -> None

(* Whether a statement can end somewhere other than after itself: it
   returns, or leaves an expansion it is not inside. A run stops before
   such a statement rather than evaluating it, since it cannot end after
   it. *)
let exits s =
  let inside = Hashtbl.create 8 and out = ref false in
  iter_stat s
    ~expr:(fun e ->
      match e.Expr.node with Expr.Expand { label; _ } -> Hashtbl.replace inside label () | _ -> ())
    ~stat:nothing;
  iter_stat s ~expr:nothing ~stat:(function
    | Stat.Return _ -> out := true
    | Stat.Leave l when not (Hashtbl.mem inside l) -> out := true
    | _ -> ());
  !out

(* A run of a block's statements evaluated from the one at [from], as far as
   it goes, with a mark after each statement that finished. [last] is the
   block's [last_named], made once for every run in it: a run's later
   statements are the block's. Gives the marks, longest first, and how many
   statements the run went through before the one it stopped in, or all
   that follow [from] when it finished. *)
let evaluate_run fn (env : known) ~last ~from stats =
  let run = Eval.start fn.prog in
  let fr = frame env in
  let marks = ref [] in
  let seen = ref [] and outputs_size = ref 0 in
  let rec go i =
    if i = Array.length stats || exits stats.(i) then i
    else
      match Eval.stat run fr stats.(i) with
      | () ->
          (* The outputs made since the last mark, which are the newest. *)
          let rec added n l =
            if l == !seen then n
            else match l with o :: r -> added (n + Materialize.output_size o) r | [] -> n
          in
          outputs_size := added !outputs_size run.Eval.outputs;
          seen := run.Eval.outputs;
          let named_after id = match Hashtbl.find_opt last id with Some j -> j > i | None -> false in
          Option.iter
            (fun m -> marks := m :: !marks)
            (mark fn env run fr ~named_after ~length:(i + 1 - from) ~outputs_size:!outputs_size);
          go (i + 1)
      | exception (V.Stop _ | Eval.Left _ | Eval.Returned _) -> i
  in
  let stopped = go from in
  (!marks, stopped - from)

(* The statements that replace the first [m.length] of a run: its outputs,
   then each known local it wrote stored back, then each local it bound
   that a later statement names bound to its value. *)
let replace_run fn (env : known) m =
  let written make (id, c, ty) =
    Option.map
      (fun value -> (id, c, ty, make id value))
      (Materialize.expr ~fresh:(fun () -> fresh fn) ty c)
  in
  let stores =
    List.map
      (fun (id, c, ty) -> Option.map (fun s -> (id, c, ty, s)) (store_back fn id ty c))
      m.stores
  and lets = List.map (written (fun id value -> Stat.Let { id; value })) m.lets in
  if List.exists Option.is_none (stores @ lets) then None
  else
    let outputs = List.rev_map Materialize.output m.outputs in
    let stores = commit env (List.filter_map Fun.id stores) in
    Some (outputs @ stores @ commit env (List.filter_map Fun.id lets))

(* Whether evaluating an expression is worth trying: it is not a constant
   already, and every input it has is known. *)
let candidate fn (env : known) (e : Expr.t) =
  e.Expr.ty <> Ty.Ptr
  && (not (Materialize.literal e))
  &&
  match e.Expr.node with
  | Expr.Local i -> Hashtbl.mem env i
  | Expr.Call _ -> (
      List.for_all (known_input env) (children e)
      && match call_key e with Some k -> not (V.Key.mem fn.failed k) | None -> true)
  (* Where a constant is made, the check whether this is its first read
     stays (Eval). *)
  | Expr.Runtime { fn = Cgt.Runtime.(Constant_begin | Constant_end); _ } -> false
  | Expr.Runtime { fn = f; _ } ->
      Intrinsics.classify f = Intrinsics.Computed && List.for_all (known_input env) (children e)
  | Expr.Math { fn = f; _ } ->
      Intrinsics.math f e.Expr.ty = Intrinsics.Computed && List.for_all (known_input env) (children e)
  (* A value on its way out of arenas keeps its way out: what it is made
     of folds inside it. *)
  | Expr.Address _ | Expr.Global _ | Expr.Layout _ | Expr.Function _ | Expr.Escape _ -> false
  | _ -> List.for_all (known_input env) (children e)

(* An expression left in the tree that calls or moves: what it writes is
   not known after it, to the rest of the expression it is in or to what
   runs next. An address taken writes nothing until something uses it, and
   an expansion's body has already been walked statement by statement. *)
let settle fn (env : known) (e : Expr.t) =
  let acts = ref false in
  iter_expr e ~stat:nothing ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Call _ | Expr.Call_value _ | Expr.Runtime _ | Expr.Take _ -> acts := true
      | _ -> ());
  match e.Expr.node with
  | Expr.Expand _ -> ()
  | _ when (not !acts) || Materialize.literal e || known_value e <> None -> ()
  | _ -> forget env (writes ~reach:fn.reach ~expr:e [])

let rec expr fn (env : known) (e : Expr.t) : Expr.t =
  match e.Expr.node with
  | Expr.Expand { label; body; result } -> (
      (* An expansion is tried as it was, and again once its body is folded,
         both times against what was known before it ran: its body's folds
         count its stores as done, and its replacement must still make
         them. *)
      let before = Hashtbl.copy env in
      let tried e =
        match attempt fn before e with
        | Some replaced ->
            Hashtbl.reset env;
            Hashtbl.iter (Hashtbl.replace env) before;
            Some replaced
        | None -> None
      in
      match if costly body then None else tried e with
      | Some replaced -> replaced
      | None -> (
          let body = block fn env body in
          (* A body that leaves early ends at more than one place, so what
             it may have written is not known after it. *)
          if leaves label body then forget env (writes ~reach:fn.reach body);
          let e = { e with Expr.node = Expr.Expand { label; body; result } } in
          match if costly body then None else tried e with Some replaced -> replaced | None -> e))
  | _ ->
      let e = map_children fn env e in
      if candidate fn env e then Option.value ~default:e (attempt fn env e) else e

(* The children folded in the order they run, each one's writes forgotten
   before the next is folded. *)
and map_children fn env (e : Expr.t) =
  let f x =
    let x = expr fn env x in
    settle fn env x;
    x
  in
  Traverse.map_expr_parts f Fun.id e

(* A run of statements, each folded in turn, except where a run of them
   evaluated whole ends at a mark: the run is replaced by what it left. A
   run that stopped in a statement is not started again at any statement
   it went through, which would stop in the same place. *)
and block fn env stats =
  (* Whether a run starting at each statement binds a local that can hold
     a list or a box, which a run must drop to end anywhere. *)
  let worth = Array.of_list (List.map (fun s -> binds_ref [ s ]) stats) in
  for i = Array.length worth - 2 downto 0 do
    worth.(i) <- worth.(i) || worth.(i + 1)
  done;
  (* The block's statements by index, and the last that names each local,
     made once for all its runs rather than once for each. *)
  let all = Array.of_list stats in
  let last = lazy (last_named all) in
  run_from fn env worth all last 0 0 stats

and run_from fn env worth all last at through stats =
  match stats with
  | [] -> []
  | s :: rest when through > 0 || not worth.(at) ->
      let s = stat fn env s in
      s @ run_from fn env worth all last (at + 1) (through - 1) rest
  | s :: rest -> (
      let marks, stopped = evaluate_run fn env ~last:(Lazy.force last) ~from:at all in
      match List.find_map (fun m -> Option.map (fun r -> (m, r)) (replace_run fn env m)) marks with
      | Some (m, replaced) ->
          let rest = List.filteri (fun i _ -> i >= m.length) stats in
          replaced @ run_from fn env worth all last (at + m.length) (stopped - m.length) rest
      | None ->
          let s = stat fn env s in
          s @ run_from fn env worth all last (at + 1) (stopped - 1) rest)

and stat fn (env : known) (s : Stat.t) : Stat.t list =
  let ex e =
    let e = expr fn env e in
    settle fn env e;
    e
  in
  (* What a statement left in the tree may change is not known after it:
     each local whose address it takes, and through an address any escaped
     local (reach). *)
  let residual (s : Stat.t) =
    let w = writes ~reach:fn.reach [ s ] in
    (match s with
    | Stat.Let { id; _ } | Stat.Hold { id; _ } -> Hashtbl.remove w id
    | Stat.Assign { place; _ } when not place.Expr.deref -> Hashtbl.remove w place.Expr.local
    | _ -> ());
    forget env w;
    [ s ]
  in
  (* What a known value's expansion outputs, which must still happen where
     it was. *)
  let before (e : Expr.t) = if Materialize.literal e then [] else [ Stat.Eval e ] in
  (* A control statement is run against what was known before its
     condition or count was folded: that fold counts the stores it made as
     done, and the statement's replacement must still make them. *)
  let control before s fallback =
    match attempt_stat fn before s with
    | Some replaced ->
        Hashtbl.reset env;
        Hashtbl.iter (Hashtbl.replace env) before;
        replaced
    | None -> fallback ()
  in
  match s with
  | Stat.Let { id; value } -> (
      let value = ex value in
      Hashtbl.remove env id;
      let s = Stat.Let { id; value } in
      match known_value value with
      | Some c ->
          Hashtbl.replace env id (c, value.Expr.ty);
          [ s ]
      | None -> residual s)
  | Stat.Hold h -> (
      let value = ex h.value in
      Hashtbl.remove env h.id;
      let s = Stat.Hold { h with value } in
      match known_value value with
      | Some c ->
          Hashtbl.replace env h.id (c, value.Expr.ty);
          [ s ]
      | None -> residual s)
  | Stat.Assign { place; value } -> (
      let value = ex value in
      let s = Stat.Assign { place; value } in
      let id = place.Expr.local in
      match (place.Expr.deref, known_value value, Hashtbl.find_opt env id) with
      | false, Some c, Some (old, ty) -> (
          (* A member of a known local is stored into the value the walk
             knows. *)
          match
            let base = { V.cell = V.cell ty (V.import old); path = []; owned = false } in
            let at = Eval.offset base ty place.Expr.path in
            V.store at value.Expr.ty (V.import c);
            V.export base.V.cell.V.value
          with
          | Some now ->
              Hashtbl.replace env id (now, ty);
              [ s ]
          | None | (exception V.Stop _) ->
              Hashtbl.remove env id;
              residual s)
      | false, Some c, None when place.Expr.path = [] ->
          Hashtbl.replace env id (c, value.Expr.ty);
          [ s ]
      | _ ->
          Hashtbl.remove env id;
          residual s)
  | Stat.Eval e -> (
      let e = ex e in
      match e.Expr.node with
      | _ when Materialize.literal e -> []
      (* Outputs with no value to give are statements of their own. *)
      | Expr.Expand { body; result = None; _ } when replayed e -> body
      | _ when replayed e -> [ Stat.Eval e ]
      | _ -> residual (Stat.Eval e))
  | Stat.Return e -> residual (Stat.Return (ex e))
  | Stat.If { cond; body } -> (
      let start = Hashtbl.copy env in
      let cond = ex cond in
      match known_value cond with
      | Some (V.Bool true) -> before cond @ block fn env body
      | Some (V.Bool false) -> before cond
      | _ ->
          control start (Stat.If { cond; body }) (fun () ->
              let body = block fn (Hashtbl.copy env) body in
              forget env (writes ~reach:fn.reach body);
              [ Stat.If { cond; body } ]))
  | Stat.Repeat { count; body } -> (
      let start = Hashtbl.copy env in
      let count = ex count in
      match known_value count with
      | Some (V.Int n) when Int64.compare n 1L < 0 -> before count
      | _ ->
          control start (Stat.Repeat { count; body }) (fun () ->
              (* What one pass writes is not known at the start of the
                 next. *)
              forget env (writes ~reach:fn.reach body);
              let body = block fn (Hashtbl.copy env) body in
              forget env (writes ~reach:fn.reach body);
              [ Stat.Repeat { count; body } ]))
  | Stat.Switch { value; cases } -> (
      let start = Hashtbl.copy env in
      let value = ex value in
      match known_value value with
      | Some (V.Case (tag, _)) when List.mem_assoc tag cases ->
          before value @ block fn env (List.assoc tag cases)
      | _ ->
          control start (Stat.Switch { value; cases }) (fun () ->
              let cases = List.map (fun (i, body) -> (i, block fn (Hashtbl.copy env) body)) cases in
              List.iter (fun (_, body) -> forget env (writes ~reach:fn.reach body)) cases;
              [ Stat.Switch { value; cases } ]))
  | Stat.Scope sc -> [ Stat.Scope { sc with body = block fn env sc.body } ]
  | Stat.Store { address; value } ->
      let address = ex address in
      residual (Stat.Store { address; value = ex value })
  | Stat.Overwrite o -> (
      let address = ex o.address in
      let value = ex o.value in
      let s = residual (Stat.Overwrite { o with address; value }) in
      (* A whole local replaced holds the replacement. *)
      match (address.Expr.node, known_value value) with
      | Expr.Address id, Some c ->
          Hashtbl.replace env id (c, value.Expr.ty);
          s
      | _ -> s)
  | Stat.Place p ->
      let address = ex p.address in
      residual (Stat.Place { p with address; value = ex p.value })
  | Stat.Spawn sp -> residual (Stat.Spawn { sp with args = List.map ex sp.args })
  | Stat.Reserve { id; _ } ->
      Hashtbl.remove env id;
      [ s ]
  | Stat.Leave _ | Stat.Join _ -> residual s

(* ---------------------------------------------------------------------- *)
(* A function                                                             *)
(* ---------------------------------------------------------------------- *)

let func prog failed (f : Func.t) =
  if f.Func.linkage = Linkage.Imported then f
  else
    let plain = Hashtbl.create 16 in
    iter_stats f.Func.body ~expr:nothing ~stat:(function
      | Stat.Let { id; value } when not (holds_ref value.Expr.ty) ->
          Hashtbl.replace plain id ()
      | _ -> ());
    let reach = reach f in
    let held = Hashtbl.create 16 in
    iter_stats f.Func.body ~expr:nothing ~stat:(function
      | Stat.Hold { id; layout; _ }
        when List.mem id f.Func.values && not (Hashtbl.mem reach.escaped id) ->
          Hashtbl.replace held id layout
      | _ -> ());
    let fn = { prog; failed; next = largest f; plain; held; wide = wide f; reach } in
    { f with Func.body = block fn (Hashtbl.create 16) f.Func.body }
