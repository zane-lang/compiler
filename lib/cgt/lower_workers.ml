(* Lowering's worker pools (concurrency.md §6, runtime/workers.c). A pool is
   a handle, its runtime object's address and a stamp, which the scope
   holding it ends as it ends a foreign handle (Type_layout.is_pool). Each
   operation on a pool is a call into the runtime. The runtime runs a step
   and a funnel through a thunk of the program's own, `zane.step.N` and
   `zane.funnel.N`, which reads a frame the runtime fills and calls the step
   or the funnel through its function value, as a spawned call's thunk calls
   its verb (Lower_spawn). The walk in [Lower] is [w]. *)

module T = Tst.Nodes
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Build

let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 }
let size st span t = fst (Nodes.Ty.size_align (ty st span t))
let unit_value = { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }

(* The value at the address [at], of type [t]; nothing for a `Unit`. *)
let read_at st span t (at : Expr.t) =
  let lowered = ty st span t in
  if lowered = Nodes.Ty.Void then unit_value else { Expr.node = Expr.Deref at; ty = lowered }

(* A 64-bit FNV-1a hash of a type's symbol: the event type's identity,
   which the runtime compares where a walk table's address would differ
   between objects (`zane_workers_publish`). *)
let type_id st span t =
  let h = ref 0xcbf29ce484222325L in
  String.iter
    (fun c -> h := Int64.mul (Int64.logxor !h (Int64.of_int (Char.code c))) 0x100000001b3L)
    (layout st span t);
  { Expr.node = Expr.Int !h; ty = Nodes.Ty.I64 }

(* A value of type [t] that a thunk computes and nothing keeps: held in a
   scope of its own when it owns a block, so that scope's end ends it, and
   used by [use] as a local. *)
let kept st span t (value : Expr.t) use =
  if held st span t then begin
    let scope = { arena = None; settles = []; wants = [] } in
    let id = fresh st in
    close st scope (bind st scope span t id value :: use { Expr.node = Expr.Local id; ty = value.Expr.ty })
  end
  else use value

(* A thunk the runtime calls with the address of a frame it fills: a
   function of the program's, named `zane.<kind>.N`, whose body [body] is
   given the frame's local. *)
let thunk st kind body =
  let at = fresh st in
  let symbol = Printf.sprintf "zane.%s.%d" kind (List.length st.spawned + 1) in
  st.spawned <-
    {
      Func.symbol;
      linkage = Linkage.Local;
      params = [ (at, Nodes.Ty.Ptr) ];
      places = [];
      ret = Nodes.Ty.Void;
      body = body at;
      values = [];
    }
    :: st.spawned;
  symbol

let member at frame i = ptr (Expr.Offset { base = local_ptr at; within = frame; path = [ i ] })
let field at frame i = { Expr.node = Expr.Deref (member at frame i); ty = Nodes.Ty.Ptr }

(* The frame a step's thunk reads (`zane_step_frame`, runtime/workers.c):
   the step, its result's conversion to a Bool and the publish function,
   each a function value; the element's address; the state snapshot's
   address; and room for the step's result. *)
let step_frame = Nodes.Ty.Struct [ Ptr; Ptr; Ptr; Ptr; Ptr; I1 ]

(* A step's thunk. The step is called with the element as its `this`,
   lent by its address as a function value's subject is (L14), and, for a
   pool with state, the snapshot and the publish function; its result,
   converted by `test`, is stored in the frame. *)
let step_thunk st span ~stateful ~state ~result =
  thunk st "step" (fun at ->
      let field = field at step_frame in
      let args = if stateful then [ field 3; read_at st span state (field 4); field 2 ] else [ field 3 ] in
      let stepped = { Expr.node = Expr.Call_value { fn = field 0; args }; ty = ty st span result } in
      kept st span result stepped (fun stepped ->
          let ok = { Expr.node = Expr.Call_value { fn = field 1; args = [ stepped ] }; ty = Nodes.Ty.I1 } in
          [ Stat.Store { address = member at step_frame 5; value = ok } ]))

(* The frame a funnel's thunk reads (`zane_funnel_frame`): the funnel, the
   state's address and the event's. *)
let funnel_frame = Nodes.Ty.Struct [ Ptr; Ptr; Ptr ]

(* A funnel's thunk: the funnel is called with the state as its `this`,
   lent by its address, and the event. Its result is dropped, and ended
   when it owns a block. *)
let funnel_thunk st span ~event ~result =
  thunk st "funnel" (fun at ->
      let field = field at funnel_frame in
      let applied =
        { Expr.node = Expr.Call_value { fn = field 0; args = [ field 1; read_at st span event (field 2) ] }; ty = ty st span result }
      in
      kept st span result applied (fun applied -> [ Stat.Eval applied ]))

let verb_result span (t : Tty.t) =
  match Tty.strip_mode t with
  | Tty.Verb v -> v.Tty.ret
  | _ -> Diagnostic.bug ~span "lowering expected a function value here"

let parts span t =
  match pool_args (Tty.strip_mode t) with
  | Some parts -> parts
  | None -> Diagnostic.bug ~span "lowering expected a worker pool here"

(* A value on its way to the runtime, which reads it at an address: held in
   a local first. *)
let addressed st (value : Expr.t) =
  let id = fresh st in
  (Stat.Let { id; value }, ptr (Expr.Address id))

(* A new pool (§6.1). The runtime copies the state into the pool's own
   region; the handle is the object's address and a stamp, as a foreign
   handle's is. *)
let new_pool w st ctx span ?state ?funnel (t : Tty.t) =
  let _, s, e = parts span t in
  let stateful, pre, state_at, funnel_value, thunk_value =
    match (state, funnel) with
    | Some state, Some funnel ->
        let held, at = addressed st (w.borrow st ctx span state) in
        let fn = w.value_of st ctx funnel in
        let thunk = funnel_thunk st span ~event:e ~result:(verb_result span funnel.T.Expr.ty) in
        (1, [ held ], at, fn, ptr (Expr.Function thunk))
    | _ ->
        (* A pool without state reads none of these. *)
        let none = layout_table (layout st span s) in
        (0, [], none, none, none)
  in
  let obj = fresh st and stamp = fresh st and result = fresh st and label = fresh st in
  let made =
    Expr.Runtime
      {
        fn = Runtime.Workers_new;
        args =
          [
            int stateful;
            state_at;
            int (size st span s);
            layout_table (layout st span s);
            funnel_value;
            thunk_value;
            int (size st span e);
            layout_table (layout st span e);
            type_id st span e;
          ];
      }
  in
  let handle = ty st span t in
  let local id t = { Expr.node = Expr.Local id; ty = t } in
  let body =
    pre
    @ [
        Stat.Let { id = obj; value = ptr made };
        Stat.Let
          {
            id = stamp;
            value = { Expr.node = Expr.Runtime { fn = Runtime.Handle_made; args = [ local obj Nodes.Ty.Ptr ] }; ty = Nodes.Ty.I64 };
          };
        Stat.assign result
          { Expr.node = Expr.Record [ (0, local obj Nodes.Ty.Ptr); (1, local stamp Nodes.Ty.I64) ]; ty = handle };
      ]
  in
  { Expr.node = Expr.Expand { label; body; result = Some result }; ty = handle }

(* `@primitives$WorkerPool` and `@primitives$EventSource.every`, by the
   name a constructor is spelled with after `@primitives$`. *)
let construct w st ctx span name args (t : Tty.t) =
  match (name, args) with
  | "WorkerPool", [ _ ] -> Some (new_pool w st ctx span t)
  | "WorkerPool", [ _; T.Arg.Value state; T.Arg.Value funnel ] -> Some (new_pool w st ctx span ~state ~funnel t)
  (* A timer is its interval (§6.3). *)
  | "EventSource.every", [ T.Arg.Value interval ] -> Some (w.borrow st ctx span interval)
  | _ -> None

let starts = [ "@primitives$start"; "@primitives$startOn"; "@primitives$startAlone"; "@primitives$startAloneOn" ]

(* The calls [call] lowers. *)
let runs spelling =
  List.mem spelling starts
  || List.mem spelling [ "@primitives$state"; "@primitives$elements"; "@primitives$publish" ]

let call w st ctx span spelling args (ret : Tty.t) : Expr.t =
  let value = function
    | T.Arg.Value v -> v
    | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block passed to a worker pool"
  in
  let args = List.map value args in
  let void label body = { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void } in
  match (spelling, args) with
  (* §6.2: the element, the pool's own once it is moved or copied in, the
     sources, and the step with what the checker supplied. The arguments run
     in the order written. *)
  | _, pool :: element :: rest when List.mem spelling starts ->
      let stateful = spelling = "@primitives$start" || spelling = "@primitives$startOn" in
      let with_sources = spelling = "@primitives$startOn" || spelling = "@primitives$startAloneOn" in
      let el, s, _ = parts span pool.T.Expr.ty in
      let sources, rest = if with_sources then (Some (List.hd rest), List.tl rest) else (None, rest) in
      let step, test, publish =
        match rest with
        | [ step; test; publish ] -> (step, test, Some publish)
        | [ step; test ] -> (step, test, None)
        | _ -> Diagnostic.bug ~span "lowering: `start` with the wrong arguments"
      in
      (* The pool is read before the element, as written. *)
      let pool_id = fresh st in
      let pooled = Stat.Let { id = pool_id; value = w.lend st ctx span pool } in
      let pool = local_ptr pool_id in
      let held, element_at = addressed st (w.moved st ctx span el element) in
      let sources = Option.map (w.lend st ctx span) sources in
      let step_value = w.value_of st ctx step in
      let test = w.value_of st ctx test in
      let publish = Option.map (w.value_of st ctx) publish in
      let none = layout_table (layout st span s) in
      let thunk = step_thunk st span ~stateful ~state:s ~result:(verb_result span step.T.Expr.ty) in
      let started =
        Expr.Runtime
          {
            fn = Runtime.Workers_start;
            args =
              [
                pool;
                element_at;
                int (size st span el);
                layout_table (layout st span el);
                ptr (Expr.Function thunk);
                step_value;
                test;
                Option.value publish ~default:none;
                int (if with_sources then 1 else 0);
                Option.value sources ~default:none;
              ];
          }
      in
      void (fresh st) [ pooled; held; Stat.Eval { Expr.node = started; ty = Nodes.Ty.Void } ]
  (* §6.6: a snapshot of the state, read from the runtime's buffer at
     once. *)
  | "@primitives$state", [ pool ] ->
      let _, s, _ = parts span pool.T.Expr.ty in
      let read = ptr (Expr.Runtime { fn = Runtime.Workers_state; args = [ w.lend st ctx span pool ] }) in
      (* A `Unit` state has nothing to read, but the read still waits
         (spec-divergences.md §12). *)
      if ty st span s = Nodes.Ty.Void then void (fresh st) [ Stat.Eval read ] else read_at st span s read
  (* §6.6: a new list of a snapshot of each element. *)
  | "@primitives$elements", [ pool ] ->
      let el, _, _ = parts span pool.T.Expr.ty in
      let args = [ w.lend st ctx span pool; int (stride st span el); layout_table (layout st span el) ] in
      { Expr.node = Expr.Runtime { fn = Runtime.Workers_elements; args }; ty = Nodes.Ty.list_handle () }
  (* §6.5: the event copied into the funnel's queue of the pool whose work
     is running. *)
  | "@primitives$publish", [ event ] ->
      let e = event.T.Expr.ty in
      let held, at = addressed st (w.borrow st ctx span event) in
      let published =
        Expr.Runtime
          { fn = Runtime.Workers_publish; args = [ at; int (size st span e); type_id st span e ] }
      in
      ignore ret;
      void (fresh st) [ held; Stat.Eval { Expr.node = published; ty = Nodes.Ty.Void } ]
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling)
