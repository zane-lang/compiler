(* Calls remembered while the program runs, unless `--no-memoize`
   (docs/design/memoization.md): which functions get a table (M1), each one
   split into a body copy and a plain copy beside the dispatcher codegen
   emits (M2), what a lookup is charged and a hit credited (M3), and the
   loops that decide once whether their calls look (M4). *)

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
  (* The weight of its cheapest call, which each miss adds to the work
     counted (see [least]). *)
  cheapest : int;
  (* What a hit is credited for each unit of the work it saved, in
     sixteenths of a call, shifted left by [credit_shift] (see [credit]). *)
  credit : int;
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

(* At most eight words of arguments and eight of result, so a lookup reads
   and compares a few words. *)
let most_key_words = 8
let most_result_words = 8

let fits (f : Func.t) =
  let key = List.fold_left (fun acc (_, t) -> match (acc, words t) with Some a, Some b -> Some (a + b) | _ -> None) (Some 0) f.Func.params in
  match (key, words f.Func.ret) with
  | Some k, Some r -> k >= 1 && k <= most_key_words && r >= 1 && r <= most_result_words
  | _ -> false

(* A runtime function a remembered body may call: one that computes or
   makes a package constant, and neither outputs, reads the program's
   arguments, nor spawns. A constant is made by its first read, so the miss
   that computes a result has made every constant the result depends on. *)
let computes : Runtime.fn -> bool = function
  | Runtime.Print | Runtime.Set_threads | Runtime.Set_threads_auto | Runtime.Arguments
  | Runtime.Writeback | Runtime.Spawn | Runtime.Join | Runtime.Defer | Runtime.Defer_return ->
      false
  | _ -> true

(* What the program has, `@program$console` and `@program$runtime`, which
   only the root package reaches, and without an argument (lower.ml). *)
let program_value symbol = String.starts_with ~prefix:"zane.value." symbol

(* Whether [f]'s own body reaches nothing but its parameters, its own
   locals, package constants and the functions it calls, which [calls]
   lists. A package constant is the same on every call; a global in
   [outside], a foreign variable's C global, is state outside the program
   (lower.ml), and a C function can read and change state of its own, so
   a call to one is not. *)
let alone ~outside (f : Func.t) =
  not
    (Traverse.exists_in f.Func.body
       ~expr:(fun e ->
         match e.Expr.node with
         | Expr.Global symbol -> program_value symbol || Hashtbl.mem outside symbol
         | Expr.Function _ | Expr.Call_value _ | Expr.Foreign_call _ -> true
         | Expr.Runtime { fn; _ } -> not (computes fn)
         | _ -> false)
       ~stat:(function Stat.Spawn _ | Stat.Join _ -> true | _ -> false))

(* Each function [f] calls, with whether the call is inside a loop. A loop
   whose count is a constant below one never runs its body, so a call there
   is not in a loop. *)
let calls (f : Func.t) =
  let found = ref [] in
  let rec stats looped ss = List.iter (stat looped) ss
  and stat looped (s : Stat.t) =
    let es, bodies = Traverse.stat_parts s in
    List.iter (expr looped) es;
    let inner =
      match s with
      | Stat.Repeat { count = { Expr.node = Expr.Int n; _ }; _ } -> Int64.compare n 0L > 0
      | Stat.Repeat _ -> true
      | _ -> looped
    in
    List.iter (stats inner) bodies
  and expr looped (e : Expr.t) =
    (match e.Expr.node with Expr.Call { fn; _ } -> found := (fn, looped) :: !found | _ -> ());
    let es, bodies = Traverse.expr_parts e in
    List.iter (expr looped) es;
    List.iter (stats looped) bodies
  in
  stats false f.Func.body;
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

(* The operations one call to [f] runs, roughly the instructions an
   optimized build gives it: what computes or touches memory counts one, a
   branch one, a loop's body eight times over or as many times as a
   constant count says, a switch its dearest case, and a call one and the
   operations of the function called. What only names a value, a local, a constant or a verb's
   expansion, counts nothing, since an optimized build keeps it in a
   register or folds it away. *)
let operations funcs =
  let known = Hashtbl.create 16 in
  let cap n = min 100_000 n in
  let rec of_func s =
    match Hashtbl.find_opt known s with
    | Some w -> w
    | None -> (
        Hashtbl.replace known s 1;
        match Hashtbl.find_opt funcs s with
        | None -> 1
        | Some (f : Func.t) ->
            let w = stats 1 f.Func.body in
            Hashtbl.replace known s w;
            w)
  and stats times ss = cap (List.fold_left (fun n st -> n + stat times st) 0 ss)
  and stat times (st : Stat.t) =
    let es, bodies = Traverse.stat_parts st in
    let inner =
      match st with
      | Stat.Repeat { count = { Expr.node = Expr.Int n; _ }; _ } -> cap (times * Int64.to_int (Int64.max 0L (Int64.min n 100_000L)))
      | Stat.Repeat _ -> cap (times * 8)
      | _ -> times
    in
    let own =
      match st with
      | Stat.Let _ | Stat.Scope _ | Stat.Eval _ | Stat.Return _ | Stat.Leave _ -> 0
      | Stat.Assign { place; _ } when not place.Expr.deref -> 0
      | _ -> times
    in
    (* A switch runs one of its cases: the dearest, at most. *)
    let within = List.map (stats inner) bodies in
    let body = match st with Stat.Switch _ -> List.fold_left max 0 within | _ -> List.fold_left ( + ) 0 within in
    cap (own + List.fold_left (fun n e -> n + expr times e) 0 es + body)
  and expr times (e : Expr.t) =
    let own =
      match e.Expr.node with
      | Expr.Int _ | Expr.Float _ | Expr.Bool _ | Expr.Text _ | Expr.Unit | Expr.Local _ | Expr.Address _ | Expr.Expand _
      | Expr.Record _ | Expr.Member _ | Expr.Case _ | Expr.Payload _ | Expr.Function _ | Expr.Global _ | Expr.Layout _ ->
          0
      | Expr.Call { fn; _ } -> cap (times * (1 + of_func fn))
      | _ -> times
    in
    let es, bodies = Traverse.expr_parts e in
    cap (own + List.fold_left (fun n e -> n + expr times e) 0 es + List.fold_left (fun n b -> n + stats times b) 0 bodies)
  in
  of_func

(* The weight of the cheapest call to [f]: the fewest nodes a call can run
   before it returns, counted as [weight] counts them, with a loop whose
   count is not a constant run no times. A hit saves at least this much for
   each call it saves, whichever path those calls would have taken. Where a
   path is unclear the count is too small, never too large: an exit inside
   an expression is taken as soon as the expression starts. *)
let least funcs remembered =
  let known = Hashtbl.create 16 in
  let inf = max_int / 4 in
  let ( +. ) a b = min inf (a + b) in
  (* A part's exits: for each place it may leave to, the function's return
     ([None]) or the end of the expansion a label names, the cheapest cost
     to get there. *)
  let join a b =
    List.fold_left
      (fun acc (k, c) -> match List.assoc_opt k acc with Some d when d <= c -> acc | _ -> (k, c) :: List.remove_assoc k acc)
      a b
  in
  let after n ex = List.map (fun (k, c) -> (k, n +. c)) ex in
  let cheapest ex = List.fold_left (fun n (_, c) -> min n c) inf ex in
  let rec of_func s =
    match Hashtbl.find_opt known s with
    | Some w -> w
    | None -> (
        Hashtbl.replace known s 1;
        match Hashtbl.find_opt funcs s with
        | None -> 1
        | Some (f : Func.t) ->
            let fall, exit = stats f.Func.body in
            let w = max 1 (min 100_000 (min fall (cheapest exit))) in
            Hashtbl.replace known s w;
            w)
  (* Each part's cheapest cost to run to its end, and its exits. *)
  and stats ss =
    List.fold_left
      (fun (fall, exit) st ->
        let f, x = stat st in
        (fall +. f, join exit (after fall x)))
      (0, []) ss
  and parts es bodies =
    let fall = List.fold_left (fun n e -> n +. fst (expr e)) 0 es in
    let fall = List.fold_left (fun n b -> n +. fst (stats b)) fall bodies in
    let exit = List.fold_left (fun n e -> join n (snd (expr e))) [] es in
    let exit = List.fold_left (fun n b -> join n (snd (stats b))) exit bodies in
    (fall, exit)
  and stat (st : Stat.t) =
    match st with
    | Stat.Return e ->
        let v, vx = expr e in
        (inf, join vx [ (None, 1 +. v) ])
    | Stat.Leave l -> (inf, [ (Some l, 1) ])
    | Stat.Repeat { count = { Expr.node = Expr.Int n; _ } as cond; body } when Int64.compare n 0L > 0 ->
        let c, cx = expr cond in
        let f, x = stats body in
        let n = Int64.to_int (Int64.min n 100_000L) in
        let all = if f >= inf / n then inf else n * f in
        (1 +. c +. all, join cx (after (1 +. c) x))
    | Stat.If { cond; body } | Stat.Repeat { count = cond; body } ->
        let c, cx = expr cond in
        let _, x = stats body in
        (1 +. c, join cx (after (1 +. c) x))
    | Stat.Switch { value; cases } ->
        let v, vx = expr value in
        let each = List.map (fun (_, b) -> stats b) cases in
        let fall = List.fold_left (fun n (f, _) -> min n f) inf each in
        let exit = List.fold_left (fun n (_, x) -> join n x) [] each in
        ((1 +. v) +. (if each = [] then 0 else fall), join vx (after (1 +. v) exit))
    | _ ->
        let es, bodies = Traverse.stat_parts st in
        let fall, exit = parts es bodies in
        (1 +. fall, exit)
  and expr (e : Expr.t) =
    match e.Expr.node with
    | Expr.Expand { label; body; _ } ->
        let fall, exit = stats body in
        let ended = match List.assoc_opt (Some label) exit with Some c -> min fall c | None -> fall in
        (1 +. ended, List.remove_assoc (Some label) exit)
    | _ ->
        let es, bodies = Traverse.expr_parts e in
        let fall, exit = parts es bodies in
        let own =
          match e.Expr.node with
          | Expr.Call { fn; _ } when not (Hashtbl.mem remembered fn) -> of_func fn
          | _ -> 1
        in
        (own +. fall, exit)
  in
  of_func

(* What a lookup of [f] costs: a few dozen instructions and a few more for
   each word of the key. *)
let lookup_cost (f : Func.t) =
  24 + (6 * List.fold_left (fun n (_, t) -> n + Option.value ~default:0 (words t)) 0 f.Func.params)

(* What a lookup of [f] is charged, in sixteenths of a call: its cost
   against the weight of a call. A function whose calls are heavy pays
   little for each lookup, so it can look up for long before its hits
   start to pay; one whose calls are light pays up to four calls. *)
let charge weigh (f : Func.t) =
  let w = max 1 (weigh f.Func.symbol) in
  max 1 (min (4 * scale) (((scale * lookup_cost f) + (w / 2)) / w))

(* What a hit of [f] is credited for each unit of weight it saved, in
   sixteenths of one of [f]'s calls, shifted left by [credit_shift] so a
   unit is worth a fraction of a sixteenth. *)
let credit_shift = 16
let credit weigh (f : Func.t) = (scale lsl credit_shift) / max 1 (weigh f.Func.symbol)

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
   and the functions remembered, whose dispatchers codegen emits. In a
   program that spawns, and in a library, whose functions a program that
   spawns may call, threads share each table, whose entries' tags guard
   them (Memos), and each keeps its state of its own; a remembered
   function reads only its arguments and constants, so a result any thread
   made is the one every thread would. *)
let plan (p : Program.t) =
  let funcs = Hashtbl.create 64 in
  List.iter
    (fun (f : Func.t) -> if f.Func.linkage <> Linkage.Imported then Hashtbl.replace funcs f.Func.symbol f)
    p.Program.funcs;
  let sites = Hashtbl.create 64 in
  Hashtbl.iter (fun s f -> Hashtbl.replace sites s (calls f)) funcs;
  let callees s = List.map fst (Hashtbl.find sites s) in
  (* Pure: alone, and calling only pure functions with bodies here. The
     greatest such set, so a cycle of pure functions is pure. *)
  let outside = Hashtbl.create 8 in
  List.iter
    (fun (g : Global.t) -> if g.Global.linkage = Linkage.Imported then Hashtbl.replace outside g.Global.symbol ())
    p.Program.globals;
  let pure = Hashtbl.create 64 in
  Hashtbl.iter (fun s f -> if alone ~outside f then Hashtbl.replace pure s ()) funcs;
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
  (* Called in a loop of a function outside its own cycle, which may ask
     for the same arguments again. *)
  let looped = Hashtbl.create 8 in
  Hashtbl.iter
    (fun c l -> List.iter (fun (d, inside) -> if inside && Hashtbl.mem comp d && not (same c d) then Hashtbl.replace looped d ()) l)
    sites;
  let ops = operations funcs in
  let chosen (f : Func.t) =
    let s = f.Func.symbol in
    Hashtbl.mem pure s
    && Some s <> p.Program.entry
    && (match f.Func.linkage with Linkage.Local | Linkage.Exported | Linkage.Shared -> true | _ -> false)
    && fits f
    && (List.exists (fun (c, _) -> same c s) (Hashtbl.find sites s)
       || (Hashtbl.mem looped s && ops s >= 2 * lookup_cost f))
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
    List.map
      (fun (f : Func.t) ->
        {
          Global.symbol = state_symbol f.Func.symbol;
          linkage = Linkage.Local;
          ty = Ty.I64;
          per_thread = not p.Program.exclusive;
        })
      memos
  in
  let weigh = weight funcs remembered in
  let cheapest = least funcs remembered in
  ( { p with Program.funcs = funcs'; globals = p.Program.globals @ states },
    List.map
      (fun (f : Func.t) ->
        {
          func = f;
          body = f.Func.symbol ^ suffix_body;
          plain = f.Func.symbol ^ suffix_plain;
          charge = charge weigh f;
          cheapest = cheapest f.Func.symbol;
          credit = credit weigh f;
        })
      memos )
