(* Experimental partial inlining (docs/experiments/goose-comparison): each
   call to a function whose body has a cheap way out is preceded by a copy
   of that way out, so the call is made only when the cheap way is not
   taken. A recursion's base case is the common one: `make(depth - 1)`
   builds a leaf in its caller when `depth - 1` is 0, and `check(p.left)`
   counts one when `p.left` is a leaf, where each was a call before. LLVM
   never inlines a function into itself, and runs no partial inliner at
   `-O2`, so this is stage 5's to do (O11).

   A function's copy is its body with every arm of a branch or a switch
   that calls anything, or does more than a few steps of work, replaced by
   a jump to the call. What is kept must change nothing the call would do
   again: anything with an effect may only be part of a value the copy
   returns, which ends it. A copy that keeps no way out is not made. The
   copy is of the body as lowering left it, which calls nothing, so it is
   made once whatever calls what. *)

open Cgt.Nodes

(* How many nodes a function's kept way out may have. *)
let budget = 48

(* The runtime functions the kept part of a copy may call outside a returned
   value: reads, which change nothing. *)
let reads = function Cgt.Runtime.Link | Cgt.Runtime.Pool_root -> true | _ -> false

exception Unfit

(* The kept part of [f]'s body, with each arm that calls or loops replaced
   by [bail], or [None] when it keeps no way out or breaks a rule above. *)
let template (f : Func.t) bail : Stat.t list option =
  let costly ss =
    Cgt.Traverse.exists_in ss
      ~expr:(fun e -> match e.Expr.node with Expr.Call _ | Expr.Call_value _ -> true | _ -> false)
      ~stat:(function
        | Stat.Repeat _ | Stat.Spawn _ | Stat.Join _ | Stat.Scope _ | Stat.Hold _ | Stat.Reserve _ -> true
        | _ -> false)
  in
  (* An arm that calls or loops leaves for the call. A list is cut at its
     first statement that does, except where that statement's value is an
     expansion, whose body is cut the same way. *)
  let rec prune = function
    | [] -> []
    | s :: rest -> (
        match prune_stat s with Some s -> s :: prune rest | None -> [ Stat.Leave bail ])
  and arm body = if costly body then [ Stat.Leave bail ] else body
  and inside (e : Expr.t) =
    match e.Expr.node with
    | Expr.Expand x -> Some { e with node = Expr.Expand { x with body = prune x.body } }
    | _ -> None
  and prune_stat (s : Stat.t) =
    match s with
    | Stat.If { cond; body } when not (costly [ Stat.Eval cond ]) -> Some (Stat.If { cond; body = arm body })
    | Stat.Switch { value; cases } when not (costly [ Stat.Eval value ]) ->
        Some (Stat.Switch { value; cases = List.map (fun (i, b) -> (i, arm b)) cases })
    | s when not (costly [ s ]) -> Some s
    | Stat.Let { id; value } -> Option.map (fun value -> Stat.Let { id; value }) (inside value)
    | Stat.Assign { place; value } -> Option.map (fun value -> Stat.Assign { place; value }) (inside value)
    | Stat.Eval e -> Option.map (fun e -> Stat.Eval e) (inside e)
    | Stat.Return e -> Option.map (fun e -> Stat.Return e) (inside e)
    | _ -> None
  in
  let bails ss = Cgt.Traverse.exists_in ss ~expr:(fun _ -> false) ~stat:(fun s -> s = Stat.Leave bail) in
  (* A copy is worth making when some arm of a branch gets out without
     leaving for the call, or when nothing in it leaves for the call. *)
  let useful kept =
    let found = ref false in
    Cgt.Traverse.walk_stats
      (fun _ -> ())
      (function
        | Stat.If { body; _ } -> if not (bails body) then found := true
        | Stat.Switch { cases; _ } -> if List.exists (fun (_, b) -> not (bails b)) cases then found := true
        | _ -> ())
      kept;
    !found || not (bails kept)
  in
  let body = match f.Func.body with [ Stat.Scope { body; _ } ] -> body | body -> body in
  let kept = prune body in
  (* Effects only inside a returned value, and nothing a scope would own. *)
  let size = ref 0 and returns = ref false in
  let rec check_expr ~returned (e : Expr.t) =
    incr size;
    (match e.Expr.node with
    | Expr.Call _ | Expr.Call_value _ | Expr.Escape _ | Expr.Box _ | Expr.Copy _ | Expr.Take _ | Expr.Snapshot _ ->
        raise Unfit
    | Expr.Runtime { fn; _ } when not (returned || reads fn) -> raise Unfit
    | _ -> ());
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.iter (check_expr ~returned) es;
    List.iter (check_stats ~returned) bodies
  and check_stats ~returned ss = List.iter (check_stat ~returned) ss
  and check_stat ~returned (s : Stat.t) =
    incr size;
    match s with
    | Stat.Return e ->
        returns := true;
        check_expr ~returned:true e
    | Stat.Store _ | Stat.Overwrite _ | Stat.Place _ | Stat.Repeat _ | Stat.Spawn _ | Stat.Join _
    | Stat.Scope _ | Stat.Hold _ | Stat.Reserve _ ->
        raise Unfit
    | s ->
        let es, bodies = Cgt.Traverse.stat_parts s in
        List.iter (check_expr ~returned) es;
        List.iter (check_stats ~returned) bodies
  in
  try
    check_stats ~returned:false kept;
    if !returns && !size <= budget && useful kept then Some kept else None
  with Unfit -> None

(* The largest id [f] uses for a local, a label or a scope. *)
let largest (f : Func.t) =
  let top = ref 0 in
  let see i = if i > !top then top := i in
  List.iter (fun (i, _) -> see i) f.Func.params;
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Local i | Expr.Address i -> see i
      | Expr.Expand { label; result; _ } ->
          see label;
          Option.iter see result
      | _ -> ())
    (function
      | Stat.Let { id; _ } -> see id
      | Stat.Hold { id; scope; _ } | Stat.Reserve { id; scope; _ } ->
          see id;
          see scope
      | Stat.Scope { id; _ } -> see id
      | Stat.Assign { place; _ } -> see place.local
      | Stat.Leave l | Stat.Join l -> see l
      | Stat.Spawn { task; scope; dest; _ } ->
          see task;
          see scope;
          Option.iter see dest
      | _ -> ())
    f.Func.body;
  !top

type copy = { params : (int * Ty.t) list; bail : int; kept : Stat.t list; ret : Ty.t; values : int list }

(* [kept] with each of its ids renamed by [rename], each `return` made a
   store into [result] and a leave of [out]. *)
let instantiate rename ~out ~result (kept : Stat.t list) =
  let rec stats ss = List.concat_map stat ss
  and stat (s : Stat.t) : Stat.t list =
    match s with
    | Stat.Return e -> (
        let e = expr e in
        match result with
        | Some (r, ty) -> [ Stat.Assign { place = { local = r; deref = false; ty; path = [] }; value = e }; Stat.Leave out ]
        | None -> [ Stat.Eval e; Stat.Leave out ])
    | Stat.Let { id; value } -> [ Stat.Let { id = rename id; value = expr value } ]
    | Stat.Assign { place; value } -> [ Stat.Assign { place = { place with local = rename place.local }; value = expr value } ]
    | Stat.Leave l -> [ Stat.Leave (rename l) ]
    | s -> [ Cgt.Traverse.map_stat_parts expr stats s ]
  and expr (e : Expr.t) : Expr.t =
    match e.Expr.node with
    | Expr.Local i -> { e with node = Expr.Local (rename i) }
    | Expr.Address i -> { e with node = Expr.Address (rename i) }
    | Expr.Expand { label; body; result } ->
        { e with node = Expr.Expand { label = rename label; body = stats body; result = Option.map rename result } }
    | _ -> Cgt.Traverse.map_expr_parts expr stats e
  in
  stats kept

(* Every call in [f] to a function with a copy made to try the copy first. *)
let rewrite copies (f : Func.t) : Func.t =
  let next = ref (largest f) in
  let fresh () = incr next; !next in
  let added = ref [] in
  let fe (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call { fn; args } -> (
        match Hashtbl.find_opt copies fn with
        | None -> None
        | Some c ->
            let out = fresh () and bail = fresh () in
            let table = Hashtbl.create 16 in
            let given = List.map (fun (p, ty) -> (p, fresh (), ty)) c.params in
            List.iter (fun (p, a, _) -> Hashtbl.replace table p a) given;
            Hashtbl.replace table c.bail bail;
            let rename i =
              match Hashtbl.find_opt table i with
              | Some j -> j
              | None ->
                  let j = fresh () in
                  Hashtbl.replace table i j;
                  if List.mem i c.values then added := j :: !added;
                  j
            in
            let result = if c.ret = Ty.Void then None else Some (fresh (), c.ret) in
            let lets = List.map2 (fun (_, a, _) arg -> Stat.Let { id = a; value = arg }) given args in
            let call = { e with node = Expr.Call { fn; args = List.map (fun (_, a, ty) -> { Expr.node = Expr.Local a; ty }) given } } in
            let tried = instantiate rename ~out ~result c.kept in
            let fallback =
              match result with
              | Some (r, ty) -> [ Stat.Assign { place = { local = r; deref = false; ty; path = [] }; value = call }; Stat.Leave out ]
              | None -> [ Stat.Eval call; Stat.Leave out ]
            in
            let body =
              lets
              @ [ Stat.Eval { Expr.node = Expr.Expand { label = bail; body = tried; result = None }; ty = Ty.Void } ]
              @ fallback
            in
            Some { e with node = Expr.Expand { label = out; body; result = Option.map fst result } })
    | _ -> None
  in
  let body = Cgt.Traverse.map_stats fe (fun _ -> None) f.Func.body in
  { f with body; values = f.Func.values @ !added }

(* Every function's calls to the functions whose copies fit tried first.
   Off unless `ZANE_PARTIAL_INLINE` is 1. *)
let program (p : Program.t) : Program.t =
  if Sys.getenv_opt "ZANE_PARTIAL_INLINE" <> Some "1" then p
  else begin
    let copies = Hashtbl.create 16 in
    List.iter
      (fun (f : Func.t) ->
        if f.Func.body <> [] then begin
          let bail = largest f + 1 in
          match template f bail with
          | Some kept ->
              Hashtbl.replace copies f.Func.symbol
                { params = f.Func.params; bail; kept; ret = f.Func.ret; values = f.Func.values }
          | None -> ()
        end)
      p.Program.funcs;
    { p with Program.funcs = List.map (rewrite copies) p.Program.funcs }
  end
