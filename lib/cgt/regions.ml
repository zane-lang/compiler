(* Where a scope's blocks go, decided once every function is lowered
   (docs/design/lowering.md L8, §9). Lowering gives a block an arena when it
   holds something, and notes each fresh owner a block moves into a callee's
   `^T` parameter. This pass sees every function at once, and so knows which
   callees keep what they are given:

   - A `^T` parameter is kept when every way out of its function has moved
     it on: into the result, into a place the caller lent, or into a callee
     that keeps it in turn.
   - A value parameter that the body copies once into what it keeps is
     taken instead: a fresh argument is moved in, and any other is copied
     where the call is.
   - A block keeps the arena lowering noted for a fresh owner only when the
     callee can drop it, so the owner's blocks go when the block drains
     rather than piling up in an enclosing region. An arena nothing is held
     in any more goes.
   - A function whose arena holds only owners that every way out moves on
     needs none: it holds them in slots of its own, and what it makes is
     made in its caller's innermost region, where its result goes anyway
     (memory.md §3.1, §3.5). *)

open Nodes
open Traverse

(* ---------------------------------------------------------------------- *)
(* Where an owner goes                                                    *)
(* ---------------------------------------------------------------------- *)

(* Whether one owner the function has, from where it is first had, reaches
   on every way out something that keeps it: the function's result, a place
   the caller lent it, or a callee that keeps what it is given. On its way
   there it may sit in locals of the function's own, its carriers. Anything
   this does not follow, such as an owner dropped or given to a callee that
   may drop it, makes the answer no. *)

exception Unknown

type state = Dead | Live of { started : bool; consumed : bool; carriers : int list }

let merge a b =
  match (a, b) with
  | Dead, s | s, Dead -> s
  | Live a, Live b ->
      let done_ (started, consumed) = (not started) || consumed in
      Live
        {
          started = a.started || b.started;
          consumed = done_ (a.started, a.consumed) && done_ (b.started, b.consumed);
          carriers = List.sort_uniq compare (a.carriers @ b.carriers);
        }

(* Every way out must have moved the owner on, once it was had. *)
let check = function Live { started = true; consumed = false; _ } -> raise Unknown | _ -> ()

let consume = function Live l -> Live { l with consumed = true } | Dead -> Dead

let carry id = function
  | Live l -> Live { l with carriers = id :: l.carriers }
  | Dead -> Dead

let carried id = function Live l -> List.mem id l.carriers | Dead -> false

(* A place written whole with a new owner, which is followed from here on.
   The owner it had must have gone on already: one still in the place is
   dropped by the write, and one in a carrier would be a second owner to
   follow at once. *)
let refill = function
  | Live { started = true; consumed = false; _ } -> raise Unknown
  | Live _ -> Live { started = true; consumed = false; carriers = [] }
  | Dead -> Dead

let drop id = function
  | Live l -> Live { l with carriers = List.filter (( <> ) id) l.carriers }
  | Dead -> Dead

type follow = {
  (* The statement where the owner is first had, and the expression that
     first gives it up: its move out of its slot, or its copy. *)
  start : Stat.t -> bool;
  event : Expr.t -> bool;
  (* A place written whole with a new owner, which is then followed anew. *)
  refills : Expr.t -> bool;
  keeps : string -> int -> bool;
  (* Each local's value, where a `let` gave it one, and the parameters that
     are addresses the caller lent. *)
  defs : (int, Expr.t) Hashtbl.t;
  lent : int list;
  exits : (int, state) Hashtbl.t;
}

(* Whether an address is inside a place the caller lent: a lent parameter,
   a member of one, or an element of a list or array reached through one. *)
let rec lent_place a (e : Expr.t) =
  match e.Expr.node with
  | Expr.Local x when List.mem x a.lent -> true
  | Expr.Local x -> (
      match Hashtbl.find_opt a.defs x with Some d -> lent_place a d | None -> false)
  | Expr.Offset { base; _ } -> lent_place a base
  | Expr.Runtime { fn = Runtime.List_push | Runtime.List_at | Runtime.Array_at; args = l :: _ }
    ->
      lent_place a l
  | _ -> false

(* An expression evaluated in [st]: the state after it, and whether its value
   is the owner, or holds it. [moving] is whether the value goes somewhere,
   rather than being read where it is. *)
let rec ex a st ~moving (e : Expr.t) =
  match st with
  | Dead -> (Dead, false)
  | Live _ when a.event e -> if moving then (st, true) else raise Unknown
  | Live _ -> (
      let read st x = fst (ex a st ~moving:false x) in
      match e.Expr.node with
      | Expr.Local c when carried c st -> if moving then (drop c st, true) else (st, false)
      | Expr.Int _ | Expr.Float _ | Expr.Bool _ | Expr.Text _ | Expr.Unit | Expr.Local _
      | Expr.Address _ | Expr.Layout _ | Expr.Function _ | Expr.Global _ ->
          (st, false)
      | Expr.Take { address = { Expr.node = Expr.Address c; _ }; _ } when carried c st ->
          if moving then (drop c st, true) else raise Unknown
      | Expr.Take { address; _ } -> (read st address, false)
      | Expr.Deref x | Expr.Flip x | Expr.Convert x | Expr.Snapshot x
      | Expr.Offset { base = x; _ } | Expr.Member { value = x; _ } | Expr.Copy { value = x; _ } ->
          (read st x, false)
      | Expr.Binary { left; right; _ } -> (read (read st left) right, false)
      | Expr.Math { args; _ } | Expr.Foreign_call { args; _ } -> (List.fold_left read st args, false)
      | Expr.Record ms ->
          List.fold_left
            (fun (st, any) (_, x) ->
              let st, f = ex a st ~moving x in
              (st, any || f))
            (st, false) ms
      | Expr.Case { payload = x; _ } | Expr.Box { value = x; _ } | Expr.Escape { value = x; _ }
      | Expr.Payload { value = x; _ } ->
          ex a st ~moving x
      | Expr.Call { fn; args } ->
          let st, given =
            List.fold_left
              (fun (st, given) (j, x) ->
                let st, f = ex a st ~moving:true x in
                if f && not (a.keeps fn j) then raise Unknown;
                (st, given || f))
              (st, false)
              (List.mapi (fun j x -> (j, x)) args)
          in
          (* A callee that keeps the owner keeps it in its result, unless it
             has none, or in a place its caller lent it, which must then be
             one this function's caller lent in turn: an owner kept in a
             local of this function goes when the local does. *)
          if
            given
            && List.exists
                 (fun (x : Expr.t) -> x.Expr.ty = Ty.Ptr && not (lent_place a x))
                 args
          then raise Unknown;
          if not given then (st, false)
          else if e.Expr.ty = Ty.Void then (consume st, false)
          else if moving then (st, true)
          else raise Unknown
      | Expr.Call_value { fn; args } ->
          let st = read st fn in
          List.fold_left
            (fun st x ->
              let st, f = ex a st ~moving:true x in
              if f then raise Unknown;
              st)
            st args
          |> fun st -> (st, false)
      | Expr.Runtime { args; _ } ->
          ( List.fold_left
              (fun st x ->
                let st, f = ex a st ~moving:true x in
                if f then raise Unknown;
                st)
              st args,
            false )
      | Expr.Expand { label; body; result } -> (
          Hashtbl.remove a.exits label;
          let ended = run a st body in
          let st = merge ended (Option.value ~default:Dead (Hashtbl.find_opt a.exits label)) in
          match result with
          | Some r when carried r st -> if moving then (drop r st, true) else (st, false)
          | _ -> (st, false)))

and run a st ss = List.fold_left (stat a) st ss

and stat a st (s : Stat.t) =
  match st with
  | Dead -> Dead
  | Live _ -> (
      let read st x = fst (ex a st ~moving:false x) in
      let move st x = ex a st ~moving:true x in
      match s with
      | Stat.Let { id; value } ->
          let st, f = move st value in
          Hashtbl.replace a.defs id value;
          if f then carry id st else st
      | Stat.Hold { id; value; _ } -> (
          let st, f = move st value in
          let st = if f then carry id st else st in
          match st with
          | Live l when a.start s -> Live { l with started = true; consumed = false }
          | st -> st)
      | Stat.Assign { place; value } ->
          let st, f = move st value in
          if not f then st
          else if place.Expr.path = [] && not place.Expr.deref then carry place.Expr.local st
          else raise Unknown
      | Stat.Eval e ->
          let st, f = move st e in
          if f then raise Unknown;
          st
      | Stat.Return e ->
          let st, f = move st e in
          check (if f then consume st else st);
          Dead
      | Stat.If { cond; body } ->
          let st = read st cond in
          merge st (run a st body)
      | Stat.Repeat { count; body } ->
          let st = read st count in
          let ended = run a st body in
          if exists_in body ~expr:(fun _ -> false) ~stat:a.start then check ended;
          merge st ended
      | Stat.Switch { value; cases } ->
          let st = read st value in
          List.fold_left (fun acc (_, b) -> merge acc (run a st b)) Dead cases
      | Stat.Leave l ->
          let prior = Option.value ~default:Dead (Hashtbl.find_opt a.exits l) in
          Hashtbl.replace a.exits l (merge prior st);
          Dead
      | Stat.Scope { body; _ } -> run a st body
      | Stat.Store { address; value }
      | Stat.Place { address; value; _ }
      | Stat.Overwrite { address; value; _ } ->
          let st = read st address in
          let st, f = move st value in
          if a.refills address then if f then raise Unknown else refill st
          else if not f then st
          else if lent_place a address then consume st
          else raise Unknown
      | Stat.Reserve _ | Stat.Join _ -> st
      | Stat.Spawn { args; _ } ->
          List.fold_left
            (fun st x ->
              let st, f = move st x in
              if f then raise Unknown;
              st)
            st args)

(* Whether the owner [follow] describes is moved on, on every way out of
   [f]. [entry] is whether it is had from the function's start. *)
let followed (f : Func.t) ~entry ~start ~event ~refills ~keeps =
  let a =
    {
      start;
      event;
      refills;
      keeps;
      defs = Hashtbl.create 16;
      lent = List.filter_map (fun (id, t) -> if t = Ty.Ptr then Some id else None) f.Func.params;
      exits = Hashtbl.create 16;
    }
  in
  try
    let st = run a (Live { started = entry; consumed = false; carriers = [] }) f.Func.body in
    check st;
    true
  with Unknown -> false

(* Whether the owner held in slot [h] is moved on. *)
let moved_on f h ~keeps =
  let is_h (e : Expr.t) = match e.Expr.node with Expr.Address x -> x = h | _ -> false in
  followed f ~entry:false
    ~start:(function Stat.Hold { id; _ } -> id = h | _ -> false)
    ~event:(function { Expr.node = Expr.Take { address; _ }; _ } -> is_h address | _ -> false)
    ~refills:is_h ~keeps

(* ---------------------------------------------------------------------- *)
(* The pass                                                               *)
(* ---------------------------------------------------------------------- *)

let has_body (f : Func.t) = f.Func.linkage <> Linkage.Imported

(* Each `^T` parameter's slot: the parameter's position, and the slot the
   body holds it in. *)
let held_params (f : Func.t) =
  let found = ref [] in
  walk_stats
    (fun _ -> ())
    (function
      | Stat.Hold { id; value = { Expr.node = Expr.Local p; _ }; _ } -> (
          match List.find_index (fun (q, _) -> q = p) f.Func.params with
          | Some j -> found := (j, id) :: !found
          | None -> ())
      | _ -> ())
    f.Func.body;
  List.rev !found

let holds_in body =
  let found = ref [] in
  walk_stats (fun _ -> ()) (function Stat.Hold { id; _ } -> found := id :: !found | _ -> ()) body;
  List.rev !found

(* Which callees keep which `^T` parameters: the greatest answer that holds
   of every function, so that a recursive call keeps what it is given when
   nothing else drops it. A callee without a body here can drop anything. *)
let keeping funcs =
  let table = Hashtbl.create 64 in
  List.iter
    (fun f ->
      if has_body f then
        List.iter (fun (j, _) -> Hashtbl.replace table (f.Func.symbol, j) true) (held_params f))
    funcs;
  let keeps fn j = Option.value ~default:false (Hashtbl.find_opt table (fn, j)) in
  let changed = ref true in
  (* [f]'s parameter [j] stops being kept once its body can drop it. *)
  let settle f (j, h) =
    if keeps f.Func.symbol j && not (moved_on f h ~keeps) then begin
      Hashtbl.replace table (f.Func.symbol, j) false;
      changed := true
    end
  in
  while !changed do
    changed := false;
    List.iter (fun f -> if has_body f then List.iter (settle f) (held_params f)) funcs
  done;
  keeps

(* A value parameter the body only copies, once, into what it keeps: the
   copy is the body's only read of it. Such a parameter takes its argument,
   so a fresh one is moved in rather than held by the caller and copied. A
   function other objects call, or that is called through its address,
   keeps the calls it was compiled for. *)
let taken_params funcs ~keeps =
  let addressed = Hashtbl.create 16 in
  List.iter
    (fun (f : Func.t) ->
      walk_stats
        (fun e ->
          match e.Expr.node with Expr.Function s -> Hashtbl.replace addressed s () | _ -> ())
        (fun _ -> ())
        f.Func.body)
    funcs;
  let table = Hashtbl.create 16 in
  (* Every read of [p] in [f]'s body, in order. *)
  let reads_of (f : Func.t) p =
    let reads = ref [] in
    walk_stats
      (fun e ->
        match e.Expr.node with
        | Expr.Local x when x = p -> reads := e :: !reads
        | Expr.Copy { value = { Expr.node = Expr.Local x; _ }; _ } when x = p ->
            reads := e :: !reads
        | _ -> ())
      (fun _ -> ())
      f.Func.body;
    List.rev !reads
  in
  let take (f : Func.t) held j (p, t) =
    if t <> Ty.Ptr then
      (* The copy is found before the read inside it. *)
      match reads_of f p with
      | [ ({ Expr.node = Expr.Copy { layout; _ }; _ } as copy); _ ] when not (List.mem j held) ->
          if
            followed f ~entry:true
              ~start:(fun _ -> false)
              ~event:(fun e -> e == copy)
              ~refills:(fun _ -> false)
              ~keeps
          then Hashtbl.replace table (f.Func.symbol, j) (copy, layout)
      | _ -> ()
  in
  List.iter
    (fun (f : Func.t) ->
      if f.Func.linkage = Linkage.Local && not (Hashtbl.mem addressed f.Func.symbol) then
        let held = List.map fst (held_params f) in
        List.iteri (take f held) f.Func.params)
    funcs;
  table

(* The argument a borrowed fresh value was held in by its caller, before
   the call read it (Lower.borrow): the value itself. *)
let borrowed (e : Expr.t) =
  match e.Expr.node with
  | Expr.Expand
      {
        body =
          [
            Stat.Hold { id; value; _ };
            Stat.Assign
              {
                place = { Expr.local; deref = false; path = []; _ };
                value = { Expr.node = Expr.Local x; _ };
              };
          ];
        result = Some r;
        _;
      }
    when x = id && local = r ->
      Some value
  | _ -> None

let take_params funcs table =
  if Hashtbl.length table = 0 then funcs
  else
    let copies = Hashtbl.fold (fun _ (copy, _) acc -> copy :: acc) table [] in
    let fe (e : Expr.t) =
      if List.exists (fun c -> c == e) copies then
        match e.Expr.node with Expr.Copy { value; _ } -> Some value | _ -> None
      else None
    in
    (* Argument [j] of a call to [fn], passed as the parameter takes it: a
       borrowed fresh value as itself, anything else copied in. *)
    let rec argument fn j (x : Expr.t) =
      let x = map_expr call_site (fun _ -> None) x in
      match (Hashtbl.find_opt table (fn, j), borrowed x) with
      | None, _ -> x
      | Some _, Some v -> v
      | Some (_, layout), None -> { x with Expr.node = Expr.Copy { value = x; layout } }
    and call_site (e : Expr.t) =
      match e.Expr.node with
      | Expr.Call { fn; args } ->
          Some { e with Expr.node = Expr.Call { fn; args = List.mapi (argument fn) args } }
      | _ -> fe e
    in
    List.map
      (fun (f : Func.t) -> { f with Func.body = map_stats call_site (fun _ -> None) f.Func.body })
      funcs

(* An arena is needed while something is held, reserved or spawned in it,
   or while a fresh owner moved into a callee that can drop it would
   otherwise go to an enclosing region. *)
let needed ~wants ~keeps symbol id body =
  let wanted =
    match Hashtbl.find_opt wants (symbol, id) with
    | Some ws -> List.exists (fun (g, j) -> not (keeps g j)) ws
    | None -> false
  in
  wanted
  || exists_in body ~expr:(fun _ -> false) ~stat:(function
       | Stat.Hold { scope; _ } | Stat.Reserve { scope; _ } | Stat.Spawn { scope; _ } -> scope = id
       | _ -> false)

let prune ~wants ~keeps (f : Func.t) =
  let rec fs (s : Stat.t) =
    match s with
    | Stat.Scope { id; body } when not (needed ~wants ~keeps f.Func.symbol id body) ->
        Some (map_stats (fun _ -> None) fs body)
    | _ -> None
  in
  { f with Func.body = map_stats (fun _ -> None) fs f.Func.body }

(* A function whose whole body is one arena, which holds only owners that
   every way out moves on, needs no arena when nothing else does: no spawn,
   no reservation, no arena nested in it, no fresh owner it must keep for a
   callee, and no callee lent one of its slots that opens an arena of its
   own, since a slot outside every arena is taken to be in the innermost
   one's region (runtime/arena.c). *)
let foldable ~wants ~keeps ~arenaless (f : Func.t) =
  match f.Func.body with
  | [ Stat.Scope { id; body } ] when has_body f ->
      let holds = holds_in body in
      let nested =
        exists_in body ~expr:(fun _ -> false) ~stat:(function
          | Stat.Scope _ | Stat.Spawn _ | Stat.Reserve _ | Stat.Join _ -> true
          | _ -> false)
      in
      let wanted =
        match Hashtbl.find_opt wants (f.Func.symbol, id) with
        | Some ws -> List.exists (fun (g, j) -> not (keeps g j)) ws
        | None -> false
      in
      (* The slots whose address a callee must not be lent, the locals
         that hold such an address, and whether a callee is lent one. A
         slot's value moved out is not its address. *)
      let slots = ref holds and pointers = ref [] in
      let rec names (e : Expr.t) =
        match e.Expr.node with
        | Expr.Take _ -> false
        | Expr.Address v -> List.mem v !slots || List.mem v !pointers
        | Expr.Local v -> List.mem v !pointers
        | _ ->
            let es, bodies = expr_parts e in
            List.exists names es || List.exists (List.exists stat_names) bodies
      and stat_names s =
        let es, bodies = stat_parts s in
        List.exists names es || List.exists (List.exists stat_names) bodies
      in
      walk_stats
        (fun _ -> ())
        (function
          | Stat.Let { id; value } | Stat.Assign { place = { Expr.local = id; _ }; value } ->
              if names value then pointers := id :: !pointers
          | Stat.Hold { id; value; _ } -> if names value then slots := id :: !slots
          | _ -> ())
        body;
      let lent_out = ref false in
      walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Call { fn; args } ->
              if List.exists names args && not (arenaless fn) then lent_out := true
          | Expr.Call_value { args; _ } -> if List.exists names args then lent_out := true
          | _ -> ())
        (fun _ -> ())
        body;
      (not nested) && (not wanted) && (not !lent_out)
      && List.for_all (fun h -> moved_on f h ~keeps) holds
  | _ -> false

(* The function's owners held in slots of its own: a hold is a `let`, and a
   move out of it reads it. *)
let fold (f : Func.t) =
  match f.Func.body with
  | [ Stat.Scope { body; _ } ] ->
      let holds = holds_in body in
      let rec fe (e : Expr.t) =
        match e.Expr.node with
        | Expr.Take { address = { Expr.node = Expr.Address h; _ }; _ } when List.mem h holds ->
            Some { e with Expr.node = Expr.Local h }
        | _ -> None
      and fs (s : Stat.t) =
        match s with
        | Stat.Hold { id; value; _ } -> Some [ Stat.Let { id; value = map_expr fe fs value } ]
        | _ -> None
      in
      { f with Func.body = map_stats fe fs body }
  | _ -> f

(* Whether a function, and everything it calls, opens no arena: the
   greatest such answer, so that functions calling one another and opening
   none are arenaless together. *)
let arenaless_of funcs =
  let table = Hashtbl.create 64 in
  List.iter
    (fun (f : Func.t) ->
      let opens =
        exists_in f.Func.body
          ~expr:(fun e -> match e.Expr.node with Expr.Call_value _ -> true | _ -> false)
          ~stat:(function Stat.Scope _ | Stat.Spawn _ -> true | _ -> false)
      in
      Hashtbl.replace table f.Func.symbol (has_body f && not opens))
    funcs;
  let get s = Option.value ~default:false (Hashtbl.find_opt table s) in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter
      (fun (f : Func.t) ->
        if get f.Func.symbol
           && exists_in f.Func.body
                ~expr:(fun e ->
                  match e.Expr.node with Expr.Call { fn; _ } -> not (get fn) | _ -> false)
                ~stat:(fun _ -> false)
        then begin
          Hashtbl.replace table f.Func.symbol false;
          changed := true
        end)
      funcs
  done;
  get

(* Every hold, reservation and spawn is inside the arena it names, which
   the pass relies on when it takes an arena away. *)
let checked (f : Func.t) =
  let rec stat opened (s : Stat.t) =
    (match s with
    | Stat.Hold { scope; _ } | Stat.Reserve { scope; _ } | Stat.Spawn { scope; _ }
      when not (List.mem scope opened) ->
        Diagnostic.bug
          (Printf.sprintf "regions: `%s` uses arena %%%d outside it" f.Func.symbol scope)
    | _ -> ());
    let opened = match s with Stat.Scope { id; _ } -> id :: opened | _ -> opened in
    let es, bodies = stat_parts s in
    List.iter (expr opened) es;
    List.iter (List.iter (stat opened)) bodies
  and expr opened (e : Expr.t) =
    let es, bodies = expr_parts e in
    List.iter (expr opened) es;
    List.iter (List.iter (stat opened)) bodies
  in
  List.iter (stat []) f.Func.body;
  f

let run ~wants (p : Nodes.Program.t) =
  let funcs = p.Nodes.Program.funcs in
  let keeps = keeping funcs in
  let funcs = take_params funcs (taken_params funcs ~keeps) in
  let funcs = List.map (prune ~wants ~keeps) funcs in
  let rec folding funcs =
    let arenaless = arenaless_of funcs in
    let changed = ref false in
    let funcs =
      List.map
        (fun f ->
          if foldable ~wants ~keeps ~arenaless f then begin
            changed := true;
            fold f
          end
          else f)
        funcs
    in
    if !changed then folding funcs else funcs
  in
  { p with Nodes.Program.funcs = List.map checked (folding funcs) }
