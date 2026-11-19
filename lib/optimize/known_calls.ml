(* A call of a known function value, and a call given one, written out
   where it is made.

   A worker's step and test are lambdas (control-flow.md §3.7), and `work`
   is a function given them: `m!work(step)` calls `work`, whose loop calls
   the step through its value, so the step's body, and every write it makes
   to the subject's members, is in a function of its own until LLVM inlines
   it, after this stage. Written out here, a call of a function value that
   names its function ([Call_value] of [Function]) and a call of a function
   given one, the step's body reads and writes the subject's place itself:
   a struct held there is then split into its members (Split_holds) as it
   is under a counted loop.

   A callee is written out as an expansion ([Expand]): its ids renumbered,
   each parameter given the argument's value, and each `return` assigning
   the expansion's result and leaving it, with a value on its way out of the
   function's arenas leaving the expansion's instead ([Escape]). The copy's
   locals that hold a value type are listed with the caller's ([values]).
   An argument that is a function value, a local's address or a constant,
   given to a parameter the callee neither assigns nor takes the address
   of, replaces the parameter; any other is bound to a fresh local first,
   in the order the arguments run. A callee that spawns, or returns through a result
   slot it is given, is called as it was; so is one given a function value
   whose body is larger than [budget] nodes, or that calls itself. *)

open Cgt.Nodes
open Cgt.Traverse

(* How many nodes a function given a function value may have to be written
   out. A lambda a call names is written out whatever its size: it is
   lifted from the one place it is written. *)
let budget = 80

(* How many times a body is searched for calls to write out: what a copy
   brings in, such as the step inside `work`, is written out on the next. *)
let rounds = 4

let nodes (body : Stat.t list) =
  let n = ref 0 in
  walk_stats (fun _ -> incr n) (fun _ -> incr n) body;
  !n

(* Whether [f] can be written out: it returns a value, not through a slot
   it is given, and starts no spawned call. *)
let fit (f : Func.t) =
  (match f.Func.ret with Ty.Struct _ | Ty.Sum _ | Ty.Array _ | Ty.Packed _ -> false | _ -> true)
  && not
       (exists_in f.Func.body
          ~expr:(fun _ -> false)
          ~stat:(function Stat.Spawn _ | Stat.Join _ -> true | _ -> false))

(* Whether [g] calls itself: written out, it would bring in a call to
   write out again, each round. *)
let calls_itself (g : Func.t) =
  exists_in g.Func.body
    ~expr:(fun (e : Expr.t) -> match e.Expr.node with Expr.Call { fn; _ } -> fn = g.Func.symbol | _ -> false)
    ~stat:(fun _ -> false)

(* An argument that may stand for its parameter wherever the callee names it. *)
let stable (e : Expr.t) =
  match e.Expr.node with
  | Expr.Function _ | Expr.Address _ | Expr.Int _ | Expr.Bool _ | Expr.Float _ | Expr.Unit -> true
  | _ -> false

(* The parameters [body] assigns or takes the address of. *)
let pinned (body : Stat.t list) =
  let t = Hashtbl.create 8 in
  walk_stats
    (fun e -> match e.Expr.node with Expr.Address i -> Hashtbl.replace t i () | _ -> ())
    (function Stat.Assign { place; _ } when not place.Expr.deref -> Hashtbl.replace t place.Expr.local () | _ -> ())
    body;
  t

(* [body] with each parameter in [subst] replaced by its argument: a read
   of it by the argument, and a place reached through it, when the argument
   is a local's address, by that local's own place. A parameter in [moved]
   is bound to a fresh local instead: it is renamed wherever it is named. *)
let substitute (subst : (int, Expr.t) Hashtbl.t) (moved : (int, int) Hashtbl.t) body =
  let rec fe (e : Expr.t) =
    match e.Expr.node with
    | Expr.Local i when Hashtbl.mem subst i -> Some { (Hashtbl.find subst i) with Expr.ty = e.Expr.ty }
    | Expr.Local i when Hashtbl.mem moved i -> Some { e with Expr.node = Expr.Local (Hashtbl.find moved i) }
    | Expr.Address i when Hashtbl.mem moved i -> Some { e with Expr.node = Expr.Address (Hashtbl.find moved i) }
    | _ -> None
  and fs (s : Stat.t) =
    match s with
    | Stat.Assign { place; value } -> (
        let value = map_expr fe fs value in
        match (Hashtbl.find_opt subst place.Expr.local, Hashtbl.find_opt moved place.Expr.local) with
        | Some { Expr.node = Expr.Address h; _ }, _ when place.Expr.deref ->
            Some [ Stat.Assign { place = { place with Expr.local = h; deref = false }; value } ]
        | _, Some id -> Some [ Stat.Assign { place = { place with Expr.local = id }; value } ]
        | _ -> Some [ Stat.Assign { place; value } ])
    | _ -> None
  in
  map_stats fe fs body

(* Each `return` in [body] made an assignment of [result] and a way out of
   [label]. Only a function's own `return`s are statements: lowering made
   each expansion's a [Leave] already. *)
let returns label result (body : Stat.t list) =
  let value (e : Expr.t) =
    match e.Expr.node with
    | Expr.Escape ({ exit = None; _ } as x) -> { e with Expr.node = Expr.Escape { x with exit = Some label } }
    | _ -> e
  in
  map_stats
    (fun _ -> None)
    (function
      | Stat.Return e -> Some (match result with Some r -> [ Stat.assign r (value e); Stat.Leave label ] | None -> [ Stat.Eval (value e); Stat.Leave label ])
      | _ -> None)
    body

(* [f]'s body written out for [args], its ids taken from [next]. Each local
   of the copy that holds a value type, as [f] lists its own, is added to
   [values]. *)
let expand next values (f : Func.t) (args : Expr.t list) ty : Expr.t =
  (* Its own ids first, past both functions' so that none meets a
     parameter's. *)
  next := max !next (Cgt.Memo.largest_id f);
  let counter = ref (!next + 1) in
  let map, body = Cgt.Memo.renumbering counter f.Func.body in
  List.iter (fun i -> Option.iter (fun j -> values := j :: !values) (Hashtbl.find_opt map i)) f.Func.values;
  next := !counter;
  let fresh () =
    incr next;
    !next
  in
  let pinned = pinned body in
  let subst = Hashtbl.create 8 and moved = Hashtbl.create 8 in
  let binds =
    List.concat
      (List.map2
         (fun (p, _) (a : Expr.t) ->
           if stable a && not (Hashtbl.mem pinned p) then begin
             Hashtbl.replace subst p a;
             []
           end
           else begin
             let id = fresh () in
             Hashtbl.replace moved p id;
             if List.mem p f.Func.values then values := id :: !values;
             [ Stat.Let { id; value = a } ]
           end)
         f.Func.params args)
  in
  let body = substitute subst moved body in
  let label = fresh () in
  let result = match ty with Ty.Void -> None | _ -> Some (fresh ()) in
  { Expr.node = Expr.Expand { label; body = binds @ returns label result body; result }; ty }

(* [body] with each read of a local bound once to a function value, and
   neither assigned nor addressed after, made that function value: an
   expression verb written out by lowering (lowering.md L11) binds the
   lambda it is given so, and its calls through that local then name the
   function. *)
let named (body : Stat.t list) =
  let pinned = pinned body and known = Hashtbl.create 8 in
  walk_stats
    (fun _ -> ())
    (function
      | Stat.Let { id; value = { Expr.node = Expr.Function _; _ } as v } when not (Hashtbl.mem pinned id) -> Hashtbl.replace known id v
      | _ -> ())
    body;
  if Hashtbl.length known = 0 then body
  else
    map_stats
      (fun (e : Expr.t) ->
        match e.Expr.node with
        | Expr.Local i when Hashtbl.mem known i -> Some { (Hashtbl.find known i) with Expr.ty = e.Expr.ty }
        | _ -> None)
      (fun _ -> None)
      body

let func funcs (f : Func.t) : Func.t =
  let next = ref (Peel.largest f) in
  let callee sym =
    match Hashtbl.find_opt funcs sym with Some g when fit g && g.Func.symbol <> f.Func.symbol && not (calls_itself g) -> Some g | _ -> None
  in
  let given_function args = List.exists (fun (a : Expr.t) -> match a.Expr.node with Expr.Function _ -> true | _ -> false) args in
  let changed = ref false and values = ref [] in
  let fe (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call_value { fn = { Expr.node = Expr.Function sym; _ }; args } -> (
        match callee sym with
        | Some g when List.length g.Func.params = List.length args ->
            changed := true;
            Some (expand next values g args e.Expr.ty)
        | _ -> None)
    | Expr.Call { fn; args } when given_function args -> (
        match callee fn with
        | Some g when List.length g.Func.params = List.length args && nodes g.Func.body <= budget ->
            changed := true;
            Some (expand next values g args e.Expr.ty)
        | _ -> None)
    | _ -> None
  in
  let rec go n body =
    changed := false;
    let body = map_stats fe (fun _ -> None) (named body) in
    if !changed && n > 1 then go (n - 1) body else body
  in
  let body = go rounds f.Func.body in
  { f with Func.body = body; values = f.Func.values @ List.rev !values }

let program (p : Program.t) =
  let funcs = Hashtbl.create 64 in
  List.iter (fun (f : Func.t) -> Hashtbl.replace funcs f.Func.symbol f) p.Program.funcs;
  { p with Program.funcs = List.map (func funcs) p.Program.funcs }
