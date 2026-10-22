(* Calls remembered while the program runs (`--memoize`, an experiment; see
   issue #262). A function is remembered when nothing it does can be seen but
   its result, every argument and its result is a few scalars, and its body
   calls back into its own cycle of calls more than once, which is where
   remembering can turn work that doubles at each level into work linear in
   the depth.

   Each such function becomes three. Codegen emits a dispatcher under its
   own symbol, which looks the arguments up in a table of the function's
   own; [body] is the function as it was, run on a miss, whose calls back
   into the cycle go through the dispatchers again; [plain] is the function
   with every call into its cycle made to the other [plain] copies, which
   look nothing up. A dispatcher whose lookups miss too often stops looking
   and calls [plain], so a function whose arguments rarely repeat pays for
   a bounded number of lookups and then runs as it would have. *)

open Nodes

type t = {
  (* The function as lowering made it: its symbol, linkage and signature
     are the dispatcher's. *)
  func : Func.t;
  body : string;
  plain : string;
  (* What a lookup is charged, in sixteenths of one of the function's
     calls (see [charge]). *)
  charge : int;
}

(* The 8-byte words a value of [t] is remembered in: its bytes, rounded
   up. [None] for a type that owns a block or holds an address anywhere in
   it, whose value is more than its bytes. *)
let rec fixed (t : Ty.t) =
  match t with
  | Ty.Handle | Ty.Ptr -> false
  | Ty.Struct ts | Ty.Sum ts -> List.for_all fixed ts
  | Ty.Array (t, _) -> fixed t
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true

let rec scalars (t : Ty.t) =
  match t with
  | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
  | Ty.Struct ts -> List.for_all scalars ts
  | _ -> false

(* A value of scalars only takes a word for each; any other its bytes. *)
let words (t : Ty.t) =
  if scalars t then
    let rec count (t : Ty.t) = match t with Ty.Void -> 0 | Ty.Struct ts -> List.fold_left (fun n t -> n + count t) 0 ts | _ -> 1 in
    Some (count t)
  else if fixed t then Some ((fst (Ty.size_align t) + 7) / 8)
  else None

(* At most 64 bytes of arguments and 64 of result, so a lookup reads and
   compares a few words. *)
let most_key_words = 8
let most_result_words = 8

let fits (f : Func.t) =
  let key = List.fold_left (fun acc (_, t) -> match (acc, words t) with Some a, Some b -> Some (a + b) | _ -> None) (Some 0) f.Func.params in
  match (key, words f.Func.ret) with
  | Some k, Some r -> k >= 1 && k <= most_key_words && r >= 1 && r <= most_result_words
  | _ -> false

(* A runtime function a remembered body may call: one that computes, and
   neither outputs, reads the program's arguments, makes a package
   constant, nor spawns. *)
let computes : Runtime.fn -> bool = function
  | Runtime.Print | Runtime.Set_threads | Runtime.Set_threads_auto | Runtime.Arguments
  | Runtime.Constant_begin | Runtime.Constant_end | Runtime.Writeback | Runtime.Spawn | Runtime.Join
  | Runtime.Defer | Runtime.Defer_return ->
      false
  | _ -> true

(* Whether [f]'s own body reaches nothing but its parameters, its own
   locals and the functions it calls, which [calls] lists. *)
let alone (f : Func.t) =
  not
    (Traverse.exists_in f.Func.body
       ~expr:(fun e ->
         match e.Expr.node with
         | Expr.Global _ | Expr.Function _ | Expr.Call_value _ -> true
         | Expr.Runtime { fn; _ } -> not (computes fn)
         | _ -> false)
       ~stat:(function Stat.Spawn _ | Stat.Join _ -> true | _ -> false))

(* Each call site in [f], with a call inside a loop counted twice, since it
   runs at least as often as two calls side by side. *)
let calls (f : Func.t) =
  let found = ref [] in
  let rec stats weight ss = List.iter (stat weight) ss
  and stat weight (s : Stat.t) =
    let es, bodies = Traverse.stat_parts s in
    let inner = match s with Stat.Repeat _ -> 2 | _ -> weight in
    List.iter (expr weight) es;
    List.iter (stats inner) bodies
  and expr weight (e : Expr.t) =
    (match e.Expr.node with Expr.Call { fn; _ } -> found := (fn, weight) :: !found | _ -> ());
    let es, bodies = Traverse.expr_parts e in
    List.iter (expr weight) es;
    List.iter (stats weight) bodies
  in
  stats 1 f.Func.body;
  !found

(* The strongly connected components of the call graph, by Tarjan's
   algorithm: each function's component, as a number. *)
let components (funcs : (string, Func.t) Hashtbl.t) edges =
  let index = Hashtbl.create 64 and low = Hashtbl.create 64 and on = Hashtbl.create 64 in
  let comp = Hashtbl.create 64 in
  let stack = ref [] and next = ref 0 and comps = ref 0 in
  let rec visit v =
    Hashtbl.replace index v !next;
    Hashtbl.replace low v !next;
    incr next;
    stack := v :: !stack;
    Hashtbl.replace on v ();
    List.iter
      (fun w ->
        if Hashtbl.mem funcs w then
          if not (Hashtbl.mem index w) then (
            visit w;
            Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w)))
          else if Hashtbl.mem on w then Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (edges v);
    if Hashtbl.find low v = Hashtbl.find index v then (
      let rec pop () =
        match !stack with
        | w :: rest ->
            stack := rest;
            Hashtbl.remove on w;
            Hashtbl.replace comp w !comps;
            if w <> v then pop ()
        | [] -> ()
      in
      pop ();
      incr comps)
  in
  Hashtbl.iter (fun v _ -> if not (Hashtbl.mem index v) then visit v) funcs;
  comp

let suffix_body = ".memo"
let suffix_plain = ".plain"

(* A dispatcher's state: how far its lookups have cost more than its hits
   saved, in sixteenths of a call. At [limit], 128 calls, it has stopped
   looking. *)
let state_symbol s = s ^ ".memo.state"
let scale = 16
let limit = 128 * scale

(* The weight of one call to [f], for comparing a lookup with it: a node
   each, a loop's body eight times over, and the weight of each function
   it calls that is not remembered, whose work a call to [f] includes. A
   remembered callee weighs one node: its own work is counted by the
   calls a hit saves. *)
let weight funcs remembered =
  let known = Hashtbl.create 16 in
  let rec of_func s =
    match Hashtbl.find_opt known s with
    | Some w -> w
    | None -> (
        Hashtbl.replace known s 1;
        match Hashtbl.find_opt funcs s with
        | None -> 1
        | Some (f : Func.t) ->
            let w = min 100_000 (stats 1 f.Func.body) in
            Hashtbl.replace known s w;
            w)
  and stats times ss = List.fold_left (fun n st -> n + stat times st) 0 ss
  and stat times (st : Stat.t) =
    let es, bodies = Traverse.stat_parts st in
    let inner = match st with Stat.Repeat _ -> min 100_000 (times * 8) | _ -> times in
    times + List.fold_left (fun n e -> n + expr times e) 0 es + List.fold_left (fun n b -> n + stats inner b) 0 bodies
  and expr times (e : Expr.t) =
    let own =
      match e.Expr.node with
      | Expr.Call { fn; _ } when not (Hashtbl.mem remembered fn) -> times * of_func fn
      | _ -> times
    in
    let es, bodies = Traverse.expr_parts e in
    min 100_000 (own + List.fold_left (fun n e -> n + expr times e) 0 es + List.fold_left (fun n b -> n + stats times b) 0 bodies)
  in
  of_func

(* What a lookup of [f] is charged, in sixteenths of a call: its own cost,
   a few dozen instructions and a few more for each word of the key,
   against the weight of a call. A function whose calls are heavy pays
   little for each lookup, so it can look up for long before its hits
   start to pay; one whose calls are light pays up to four calls. *)
let charge weigh (f : Func.t) =
  let key = List.fold_left (fun n (_, t) -> n + Option.value ~default:0 (words t)) 0 f.Func.params in
  let lookup = 24 + (6 * key) in
  let w = max 1 (weigh f.Func.symbol) in
  max 1 (min (4 * scale) (((scale * lookup) + (w / 2)) / w))

(* Every id a function names: one numbering covers locals, scopes, labels
   and tasks (lower.ml's [fresh]). *)
let largest_id (f : Func.t) =
  let m = ref 0 in
  let see i = if i > !m then m := i in
  List.iter (fun (i, _) -> see i) f.Func.params;
  Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Local i | Expr.Address i -> see i
      | Expr.Expand { label; result; _ } -> see label; Option.iter see result
      | Expr.Escape { exit; _ } -> Option.iter see exit
      | _ -> ())
    (fun st ->
      match st with
      | Stat.Let { id; _ } -> see id
      | Stat.Hold { id; scope; _ } | Stat.Reserve { id; scope; _ } -> see id; see scope
      | Stat.Scope { id; _ } -> see id
      | Stat.Assign { place; _ } -> see place.Expr.local
      | Stat.Leave l | Stat.Join l -> see l
      | Stat.Spawn { task; scope; dest; _ } -> see task; see scope; Option.iter see dest
      | _ -> ())
    f.Func.body;
  !m

(* [body] with every id it defines given a new number from [next], and every
   use of one of them changed to match; ids defined outside it are kept. *)
let renumber next body =
  let map = Hashtbl.create 16 in
  let define i =
    let j = !next in
    incr next;
    Hashtbl.replace map i j
  in
  Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Expand { label; result; _ } -> define label; Option.iter define result
      | _ -> ())
    (fun st ->
      match st with
      | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } | Stat.Scope { id; _ } -> define id
      | Stat.Spawn { task; dest; _ } -> define task; Option.iter define dest
      | _ -> ())
    body;
  let r i = Option.value ~default:i (Hashtbl.find_opt map i) in
  let rec expr (e : Expr.t) =
    let e = Traverse.map_expr_parts expr stats e in
    let node =
      match e.Expr.node with
      | Expr.Local i -> Expr.Local (r i)
      | Expr.Address i -> Expr.Address (r i)
      | Expr.Expand x -> Expr.Expand { x with label = r x.label; result = Option.map r x.result }
      | Expr.Escape x -> Expr.Escape { x with exit = Option.map r x.exit }
      | n -> n
    in
    { e with Expr.node }
  and stats ss = List.map stat ss
  and stat st =
    match Traverse.map_stat_parts expr stats st with
    | Stat.Let x -> Stat.Let { x with id = r x.id }
    | Stat.Hold x -> Stat.Hold { x with id = r x.id; scope = r x.scope }
    | Stat.Reserve x -> Stat.Reserve { x with id = r x.id; scope = r x.scope }
    | Stat.Scope x -> Stat.Scope { x with id = r x.id }
    | Stat.Assign x -> Stat.Assign { x with place = { x.place with Expr.local = r x.place.Expr.local } }
    | Stat.Leave l -> Stat.Leave (r l)
    | Stat.Join t -> Stat.Join (r t)
    | Stat.Spawn x -> Stat.Spawn { x with task = r x.task; scope = r x.scope; dest = Option.map r x.dest }
    | st -> st
  in
  stats body

(* The functions remembered that [body] calls, by symbol, for which [outside]
   holds: those whose cycle the caller is not in. *)
let called_in remembered outside body =
  let found = ref [] in
  Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Call { fn; _ } when Hashtbl.mem remembered fn && outside fn && not (List.mem fn !found) ->
          found := fn :: !found
      | _ -> ())
    (fun _ -> ())
    body;
  !found

(* Each loop of [body] that calls remembered functions from outside their
   cycle, run in two versions (#262). The decision is made once, before the
   loop: when every dispatcher it calls has stopped looking, the loop runs
   as written, with each of those calls made to the plain copy, so nothing
   in it checks a dispatcher and LLVM may optimize it as it would the
   original. Otherwise a second copy runs, calling through the dispatchers
   and checking before each round whether they have all stopped; if they
   have, it leaves, and the first version runs the rounds left. *)
let version remembered outside next body =
  let i64 n = { Expr.node = Expr.Int (Int64.of_int n); ty = Ty.I64 } in
  let local id t = { Expr.node = Expr.Local id; ty = t } in
  let stopped h =
    let state = { Expr.node = Expr.Deref { Expr.node = Expr.Global (state_symbol h); ty = Ty.Ptr }; ty = Ty.I64 } in
    { Expr.node = Expr.Flip { Expr.node = Expr.Binary { op = Expr.Less; left = state; right = i64 limit }; ty = Ty.I1 }; ty = Ty.I1 }
  in
  let all = function
    | [] -> { Expr.node = Expr.Bool true; ty = Ty.I1 }
    | h :: rest ->
        List.fold_left
          (fun acc h -> { Expr.node = Expr.Binary { op = Expr.Mul; left = acc; right = stopped h }; ty = Ty.I1 })
          (stopped h) rest
  in
  let rec plain hs (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call { fn; args } when List.mem fn hs ->
        Some { e with Expr.node = Expr.Call { fn = fn ^ suffix_plain; args = List.map (Traverse.map_expr (plain hs) (fun _ -> None)) args } }
    | _ -> None
  in
  let rec stats body = Traverse.map_stats (fun _ -> None) loop body
  and loop (st : Stat.t) =
    match st with
    | Stat.Repeat { count; body } -> (
        match called_in remembered outside body with
        | [] -> None
        | hs ->
            let n = !next and d = !next + 1 and leave = !next + 2 in
            next := !next + 3;
            let on = stats body in
            let off = Traverse.map_stats (plain hs) (fun _ -> None) (renumber next body) in
            let stopped_all = all hs in
            let ty = count.Expr.ty in
            let checked =
              Stat.If { cond = stopped_all; body = [ Stat.Leave leave ] }
              :: Stat.assign d { Expr.node = Expr.Binary { op = Expr.Add; left = local d ty; right = { (i64 1) with ty } }; ty }
              :: on
            in
            Some
              [
                Stat.Let { id = n; value = count };
                Stat.Let { id = d; value = { (i64 0) with ty } };
                Stat.If
                  {
                    cond = { Expr.node = Expr.Flip stopped_all; ty = Ty.I1 };
                    body =
                      [
                        Stat.Eval
                          {
                            Expr.node = Expr.Expand { label = leave; body = [ Stat.Repeat { count = local n ty; body = checked } ]; result = None };
                            ty = Ty.Void;
                          };
                      ];
                  };
                Stat.Repeat
                  {
                    count = { Expr.node = Expr.Binary { op = Expr.Add; left = local n ty; right = { Expr.node = Expr.Flip (local d ty); ty } }; ty };
                    body = off;
                  };
              ])
    | _ -> None
  in
  stats body

(* The program with each remembered function replaced by its two copies,
   and the functions remembered, whose dispatchers codegen emits. Only a
   function [keep] admits is remembered. A program
   that spawns remembers nothing: the tables are not shared safely between
   threads. *)
let plan ?(keep = fun _ -> true) (p : Program.t) =
  let spawns =
    List.exists
      (fun (f : Func.t) -> Traverse.exists_in f.Func.body ~expr:(fun _ -> false) ~stat:(function Stat.Spawn _ -> true | _ -> false))
      p.Program.funcs
  in
  if spawns then (p, [])
  else
    let funcs = Hashtbl.create 64 in
    List.iter
      (fun (f : Func.t) -> if f.Func.linkage <> Linkage.Imported then Hashtbl.replace funcs f.Func.symbol f)
      p.Program.funcs;
    let sites = Hashtbl.create 64 in
    Hashtbl.iter (fun s f -> Hashtbl.replace sites s (calls f)) funcs;
    let callees s = List.map fst (Hashtbl.find sites s) in
    (* Pure: alone, and calling only pure functions with bodies here. The
       greatest such set, so a cycle of pure functions is pure. *)
    let pure = Hashtbl.create 64 in
    Hashtbl.iter (fun s f -> if alone f then Hashtbl.replace pure s ()) funcs;
    let changed = ref true in
    while !changed do
      changed := false;
      Hashtbl.iter
        (fun s _ ->
          if Hashtbl.mem pure s && not (List.for_all (fun c -> Hashtbl.mem pure c) (callees s)) then (
            Hashtbl.remove pure s;
            changed := true))
        (Hashtbl.copy pure)
    done;
    let comp = components funcs callees in
    let same a b = Hashtbl.find_opt comp a = Some (Hashtbl.find comp b) in
    let chosen (f : Func.t) =
      let s = f.Func.symbol in
      Hashtbl.mem pure s
      && keep s
      && Some s <> p.Program.entry
      && (match f.Func.linkage with Linkage.Local | Linkage.Exported | Linkage.Shared -> true | _ -> false)
      && fits f
      && List.fold_left (fun n (c, w) -> if same c s then n + w else n) 0 (Hashtbl.find sites s) >= 2
    in
    let memos = List.filter chosen p.Program.funcs in
    let remembered = Hashtbl.create 8 in
    List.iter (fun (f : Func.t) -> Hashtbl.replace remembered f.Func.symbol ()) memos;
    (* Each call into [s]'s own cycle made to the callee's plain copy, its
       arguments rewritten the same way. *)
    let rec plain_expr s (e : Expr.t) =
      match e.Expr.node with
      | Expr.Call { fn; args } when Hashtbl.mem remembered fn && same fn s ->
          Some { e with Expr.node = Expr.Call { fn = fn ^ suffix_plain; args = List.map (Traverse.map_expr (plain_expr s) (fun _ -> None)) args } }
      | _ -> None
    in
    let plain_of s body = Traverse.map_stats (plain_expr s) (fun _ -> None) body in
    let versioned s (f : Func.t) =
      if f.Func.linkage = Linkage.Imported then f
      else
        let next = ref (largest_id f + 1) in
        let outside h = not (Hashtbl.mem comp s && same h s) in
        { f with Func.body = version remembered outside next f.Func.body }
    in
    let funcs' =
      List.concat_map
        (fun (f : Func.t) ->
          let s = f.Func.symbol in
          if Hashtbl.mem remembered s then
            [
              versioned s { f with Func.symbol = s ^ suffix_body; linkage = Linkage.Local };
              versioned s { f with Func.symbol = s ^ suffix_plain; linkage = Linkage.Local; body = plain_of s f.Func.body };
            ]
          else [ versioned s f ])
        p.Program.funcs
    in
    let states =
      List.map (fun (f : Func.t) -> { Global.symbol = state_symbol f.Func.symbol; linkage = Linkage.Local; ty = Ty.I64 }) memos
    in
    let weigh = weight funcs remembered in
    ( { p with Program.funcs = funcs'; globals = p.Program.globals @ states },
      List.map
        (fun (f : Func.t) ->
          { func = f; body = f.Func.symbol ^ suffix_body; plain = f.Func.symbol ^ suffix_plain; charge = charge weigh f })
        memos )
