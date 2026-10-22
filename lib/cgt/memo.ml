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
}

(* The 8-byte words a value of [t] is held in when remembered, or [None]
   for a type that owns blocks or holds an address, whose value is not
   its words alone. *)
let rec words (t : Ty.t) =
  match t with
  | Ty.Void -> Some 0
  | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> Some 1
  | Ty.Struct ts ->
      List.fold_left
        (fun acc t -> match (acc, words t) with Some a, Some b -> Some (a + b) | _ -> None)
        (Some 0) ts
  | Ty.Handle | Ty.Ptr | Ty.Sum _ | Ty.Array _ -> None

let most_key_words = 4
let most_result_words = 2

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
    let funcs' =
      List.concat_map
        (fun (f : Func.t) ->
          let s = f.Func.symbol in
          if Hashtbl.mem remembered s then
            [
              { f with Func.symbol = s ^ suffix_body; linkage = Linkage.Local };
              { f with Func.symbol = s ^ suffix_plain; linkage = Linkage.Local; body = plain_of s f.Func.body };
            ]
          else [ f ])
        p.Program.funcs
    in
    ( { p with Program.funcs = funcs' },
      List.map (fun (f : Func.t) -> { func = f; body = f.Func.symbol ^ suffix_body; plain = f.Func.symbol ^ suffix_plain }) memos )
