(* What the evaluator computed, as CGT again (docs/design/optimization.md O4,
   O7): a constant as the expression that builds it, and an output as the
   runtime call that makes it. *)

open Cgt.Nodes
module V = Value

(* A folded value must not make the program much larger than the code it
   replaces (O6). *)
let max_size = 65_536

let ptr node = { Expr.node; ty = Ty.Ptr }
let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Ty.I64 }

(* [fresh] gives a number for each new local and label a list needs, which
   the function the code goes into does not use yet. *)
let rec expr ?fresh (t : Ty.t) (c : V.const) : Expr.t option =
  let made node = Some { Expr.node; ty = t } in
  match (t, c) with
  | (Ty.I64 | Ty.I32), V.Int i -> made (Expr.Int i)
  | (Ty.F64 | Ty.F32), V.Float f -> made (Expr.Float f)
  | Ty.I1, V.Bool b -> made (Expr.Bool b)
  | Ty.Void, V.Unit -> made Expr.Unit
  | Ty.Handle, V.Text s -> made (Expr.Text s)
  | Ty.Ptr, V.Func s -> made (Expr.Function s)
  | Ty.Struct ts, V.Record a when List.length ts = Array.length a -> members ?fresh t ts a
  | Ty.Array (e, n), V.Record a when n = Array.length a -> members ?fresh t (List.init n (fun _ -> e)) a
  | Ty.Sum ts, V.Case (i, p) when i < List.length ts ->
      Option.bind (expr ?fresh (List.nth ts i) p) (fun payload -> made (Expr.Case { index = i; payload }))
  (* A boxed member's payload in a block of its own, as lowering builds one. *)
  | Ty.Ptr, V.Box { ty; layout = Some layout; payload } ->
      Option.map (fun value -> ptr (Expr.Box { value; layout })) (expr ?fresh ty payload)
  (* A list, made where it is used as a list is made anywhere: empty, then
     each element pushed in order, in the region of the scope the code is
     in, as a call's result would be. *)
  | Ty.Handle, V.List { stride; element; layout; items } -> (
      match fresh with
      | None -> None
      | Some fresh ->
          let label = fresh () and r = fresh () in
          let make = Stat.assign r { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] }; ty = Ty.Handle } in
          let push c =
            Option.map
              (fun value ->
                let at = fresh () in
                let room =
                  ptr (Expr.Runtime { fn = Cgt.Runtime.List_push; args = [ ptr (Expr.Address r); int stride ] })
                in
                let address = ptr (Expr.Local at) in
                [
                  Stat.Let { id = at; value = room };
                  (match layout with
                  | Some layout -> Stat.Place { address; value; layout }
                  | None -> Stat.Store { address; value });
                ])
              (expr ~fresh element c)
          in
          let pushes = List.map push items in
          if List.for_all Option.is_some pushes then
            made (Expr.Expand { label; body = make :: List.concat_map Option.get pushes; result = Some r })
          else None)
  | _ -> None

(* A struct's members, or an array's elements, each at its index. *)
and members ?fresh t ts a =
  let built = List.mapi (fun i m -> Option.map (fun e -> (i, e)) (expr ?fresh m a.(i))) ts in
  if List.for_all Option.is_some built then
    Some { Expr.node = Expr.Record (List.map Option.get built); ty = t }
  else None

(* The value an expression that [expr] could have made stands for, which is
   what the fold knows a local holds once one is stored in it. *)
let rec const (e : Expr.t) : V.const option =
  match e.Expr.node with
  | Expr.Int i -> Some (V.Int (V.int e.Expr.ty i))
  | Expr.Float f -> Some (V.Float f)
  | Expr.Bool b -> Some (V.Bool b)
  | Expr.Unit -> Some V.Unit
  | Expr.Text s -> Some (V.Text s)
  | Expr.Function s -> Some (V.Func s)
  | Expr.Case { index; payload } -> Option.map (fun p -> V.Case (index, p)) (const payload)
  | Expr.Record ms -> (
      let n =
        match e.Expr.ty with
        | Ty.Struct ts -> List.length ts
        | Ty.Array (_, n) -> n
        | _ -> -1
      in
      let given = List.map (fun (i, m) -> (i, const m)) ms in
      if n < 0 || List.length given <> n || List.exists (fun (_, c) -> c = None) given then None
      else
        let a = Array.make n V.Unit in
        List.iter (fun (i, c) -> if i < n then a.(i) <- Option.get c) given;
        Some (V.Record a))
  | Expr.Box { value; layout } ->
      Option.map (fun payload -> V.Box { ty = value.Expr.ty; layout = Some layout; payload }) (const value)
  | Expr.Expand
      {
        body = Stat.Assign { place = { local; path = []; deref = false; _ }; value = { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] }; _ } } :: pushes;
        result = Some r;
        _;
      }
    when local = r ->
      let rec items acc = function
        | [] -> Some (List.rev acc)
        | Stat.Let { id; value = { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_push; args = [ { Expr.node = Expr.Address l; _ }; { Expr.node = Expr.Int stride; _ } ] }; _ } }
          :: (( Stat.Place { address = { Expr.node = Expr.Local at; _ }; value; _ }
              | Stat.Store { address = { Expr.node = Expr.Local at; _ }; value } ) as s)
          :: rest
          when l = r && at = id -> (
            let layout = match s with Stat.Place { layout; _ } -> Some layout | _ -> None in
            match const value with
            | Some c -> items ((Int64.to_int stride, value.Expr.ty, layout, c) :: acc) rest
            | None -> None)
        | _ -> None
      in
      Option.map
        (fun items ->
          match items with
          | [] -> V.List { stride = 0; element = Ty.Void; layout = None; items = [] }
          | (stride, element, layout, _) :: _ ->
              V.List { stride; element; layout; items = List.map (fun (_, _, _, c) -> c) items })
        (items [] pushes)
  | _ -> None

let literal e = Option.is_some (const e)

(* An output made again where the folded code was. A count given to
   `setThreads` resizes the pool or aborts; which one it did is already part
   of what the fold computed. *)
let output (o : Eval.output) =
  let call fn args ty = Stat.Eval { Expr.node = Expr.Runtime { fn; args }; ty } in
  match o with
  | Eval.Print s -> call Cgt.Runtime.Print [ { Expr.node = Expr.Text s; ty = Ty.Handle } ] Ty.Void
  | Eval.Set_threads n -> call Cgt.Runtime.Set_threads [ { Expr.node = Expr.Int n; ty = Ty.I64 } ] Ty.I64
  | Eval.Set_threads_auto -> call Cgt.Runtime.Set_threads_auto [] Ty.Void

let output_size = function Eval.Print s -> 24 + String.length s | _ -> 8
