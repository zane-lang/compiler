(* Experimental (docs/experiments/goose-comparison): unless ZANE_LOOP_PUSHES=0
   in the environment, a call in a loop's body to a function whose whole
   body is one push onto the list its first argument names -- `core`'s
   `push` -- is written out there as that push, so that codegen sees the
   loop push onto the list once each time round and can make room for all
   of them before it (Emit, [Stat.Repeat]). *)

open Cgt.Nodes

let on () = Sys.getenv_opt "ZANE_LOOP_PUSHES" <> Some "0"

(* The stride and layout of [f] when its body is a push of its second
   parameter onto the list its first names, and nothing else: `List`'s
   `push`, whose first parameter is the list, or `ListRef`'s, whose first
   is a record of one handle, the list at its offset 0. *)
let push_function (f : Func.t) =
  let list_arg list (e : Expr.t) =
    match e.Expr.node with
    | Expr.Local l -> l = list
    | Expr.Offset { base = { Expr.node = Expr.Local l; _ }; path = [ 0 ]; _ } -> l = list
    | _ -> false
  in
  let push list value copy = function
    | [
        Stat.Eval
          {
            Expr.node =
              Expr.Expand
                {
                  body =
                    [
                      Stat.Let { id = held; value = { Expr.node = Expr.Local v; _ } };
                      Stat.Let
                        {
                          id = slot;
                          value =
                            { Expr.node = Expr.Runtime { fn = Cgt.Runtime.List_push; args = [ l; { Expr.node = Expr.Int stride; _ } ] }; _ };
                        };
                      Stat.Place { address = { Expr.node = Expr.Local a; _ }; value = { Expr.node = Expr.Local h; _ }; layout };
                    ];
                  result = None;
                  _;
                };
            _;
          };
        Stat.Return { Expr.node = Expr.Unit; _ };
      ]
      when (v = value || Some v = copy) && list_arg list l && a = slot && h = held ->
        Some (stride, layout)
    | _ -> None
  in
  match (f.Func.params, f.Func.body) with
  | [ (list, _); (value, _) ], Stat.Let { id; value = { Expr.node = Expr.Local v; _ } } :: rest when v = value ->
      push list value (Some id) rest
  | [ (list, _); (value, _) ], body -> push list value None body
  | _ -> None

(* The largest local or label [body] uses. *)
let largest body =
  let most = ref 0 in
  let see n = if n > !most then most := n in
  Cgt.Traverse.walk_stats
    (fun e ->
      match e.Expr.node with
      | Expr.Local l | Expr.Address l -> see l
      | Expr.Expand { label; result; _ } ->
          see label;
          Option.iter see result
      | _ -> ())
    (function
      | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> see id
      | Stat.Scope { id; _ } -> see id
      | Stat.Leave l -> see l
      | _ -> ())
    body;
  !most

let func pushes (f : Func.t) =
  let next = ref (largest f.Func.body + List.fold_left (fun m (p, _) -> max m p) 0 f.Func.params) in
  let fresh () =
    incr next;
    !next
  in
  let written_out (s : Stat.t) =
    match s with
    | Stat.Eval { Expr.node = Expr.Call { fn; args = [ ({ Expr.node = Expr.Address _; _ } as list); value ] }; _ }
      -> (
        match Hashtbl.find_opt pushes fn with
        | Some (stride, layout) ->
            let label = fresh () and held = fresh () and slot = fresh () in
            let local id ty = { Expr.node = Expr.Local id; ty } in
            [ Stat.Let { id = held; value };
            Stat.Eval
              {
                Expr.node =
                  Expr.Expand
                    {
                      label;
                      body =
                        [
                          Stat.Let
                            {
                              id = slot;
                              value =
                                {
                                  Expr.node =
                                    Expr.Runtime
                                      { fn = Cgt.Runtime.List_push; args = [ list; { Expr.node = Expr.Int stride; ty = Ty.I64 } ] };
                                  ty = Ty.Ptr;
                                };
                            };
                          Stat.Place { address = local slot Ty.Ptr; value = local held value.Expr.ty; layout };
                          Stat.Leave label;
                        ];
                      result = None;
                    };
                ty = Ty.Void;
              } ]
        | None -> [ s ])
    | s -> [ s ]
  in
  let rec stats ss = List.map stat ss
  and stat (s : Stat.t) =
    match s with
    | Stat.Repeat { count; body } -> Stat.Repeat { count; body = List.concat_map written_out (stats body) }
    | Stat.Scope { id; body } -> Stat.Scope { id; body = stats body }
    | Stat.If { cond; body } -> Stat.If { cond; body = stats body }
    | Stat.Switch { value; cases } -> Stat.Switch { value; cases = List.map (fun (i, b) -> (i, stats b)) cases }
    | Stat.Eval ({ Expr.node = Expr.Expand e; _ } as x) ->
        Stat.Eval { x with Expr.node = Expr.Expand { e with body = stats e.body } }
    | s -> s
  in
  { f with Func.body = stats f.Func.body }

(* Whether [e] or [s] changes a list's count itself, or calls a function
   through a value. *)
let grows_expr (e : Expr.t) =
  match e.Expr.node with
  | Expr.Call_value _ -> true
  | Expr.Runtime { fn; _ } -> (
      match fn with
      | Cgt.Runtime.List_push | List_room | List_reserve | List_remove _ | List_swap_remove _ | Overwrite | Copy
      | Promote | Arrive ->
          true
      | _ -> false)
  | _ -> false

let grows_stat = function Stat.Spawn _ | Stat.Join _ | Stat.Overwrite _ -> true | _ -> false

(* The functions that cannot change a list's count (Cgt.List_pure): every
   function is taken to be one, then each that changes a count itself or
   calls one that is not is dropped, until none changes. *)
let pure (p : Program.t) =
  let table = Cgt.List_pure.functions in
  Hashtbl.reset table;
  List.iter (fun (f : Func.t) -> Hashtbl.replace table f.Func.symbol ()) p.Program.funcs;
  let impure (f : Func.t) =
    Cgt.Traverse.exists_in f.Func.body
      ~expr:(fun e ->
        grows_expr e || match e.Expr.node with Expr.Call { fn; _ } -> not (Hashtbl.mem table fn) | _ -> false)
      ~stat:grows_stat
  in
  let rec settle () =
    let dropped =
      List.filter (fun (f : Func.t) -> Hashtbl.mem table f.Func.symbol && impure f) p.Program.funcs
    in
    if dropped <> [] then begin
      List.iter (fun (f : Func.t) -> Hashtbl.remove table f.Func.symbol) dropped;
      settle ()
    end
  in
  settle ()

let program (p : Program.t) =
  if not (on ()) then p
  else
    let () = pure p in
    let pushes = Hashtbl.create 8 in
    List.iter
      (fun (f : Func.t) -> Option.iter (Hashtbl.replace pushes f.Func.symbol) (push_function f))
      p.Program.funcs;
    { p with Program.funcs = List.map (func pushes) p.Program.funcs }
