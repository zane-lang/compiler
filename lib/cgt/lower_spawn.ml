(* Lowering's spawned calls (docs/design/lowering.md §9): the frame a
   spawned call's arguments are stored in, the function that runs it on
   another thread, and what settles how it ended. The walk in [Lower] is
   [w]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Literals
open Verbs
open Outcome
open Build

(* A spawned call has a function to run on another thread, which a verb
   expanded where it is called has not (L11). It gets one of its own, named
   `zane.expanded.N`: the verb with each literal it was given bound where
   its body reads it, one function for each verb and set of literals. A
   block argument cannot be spawned (concurrency.md §3.1), and an array
   literal's elements are values the spawn makes, so its parameter becomes
   one the function takes, of the array's type. So does each value
   interpolated into a string literal (types.md §2.8): the function takes a
   string for it, and the literal it is given reads that parameter. *)
let specialized st ctx span (v : verb) args =
  let concept (p : T.Local.t) = match p.T.Local.ty with Tty.Concept c -> Some c | _ -> None in
  let pairs = List.combine v.params args in
  let interpolated (p : T.Local.t) (lit : T.Expr.t) pieces =
    let prim = Tst.Intrinsics.prim "String" in
    let piece = function
      | T.Expr.Interpolation (v : T.Expr.t) ->
          let l = { T.Local.id = -fresh st; name = interpolated_name; ty = prim; span = v.T.Expr.span } in
          ( [ Either.Right (l, T.Arg.Value v) ],
            T.Expr.Interpolation { v with T.Expr.node = T.Expr.Var (T.Name_ref.Local l); ty = prim } )
      | f -> ([], f)
    in
    let held = List.map piece pieces in
    Either.Left (p.T.Local.id, { lit with T.Expr.node = T.Expr.Text_lit (List.map snd held) })
    :: List.concat_map fst held
  in
  let literals, kept =
    List.partition_map Fun.id
    @@ List.concat_map
      (fun ((p : T.Local.t), arg) ->
        match (concept p, arg) with
        | Some Tty.Text_lit, T.Arg.Value a when interpolates (literal_of ctx a) -> (
            let lit = literal_of ctx a in
            match lit.T.Expr.node with
            | T.Expr.Text_lit pieces -> interpolated p lit pieces
            | _ -> Diagnostic.bug ~span "lowering expected a string literal here")
        | _ -> [ (match (concept p, arg) with
        | Some (Tty.Array_lit (t, n)), T.Arg.Value a ->
            let arr = array_type t n in
            let ctor =
              {
                T.Verb_ref.owner = S.Intrinsic "@primitives$Array";
                name = "@primitives$Array";
                instance = [];
              }
            in
            let built = T.Expr.Construct { ctor; args = [ arg ]; handler = None } in
            let built = { a with T.Expr.node = built; ty = arr } in
            Right ({ p with T.Local.ty = arr }, T.Arg.Value built)
        | Some (Tty.Integer_lit | Tty.Decimal_lit | Tty.Text_lit), T.Arg.Value a ->
            Left (p.T.Local.id, literal_of ctx a)
        | Some _, _ -> Diagnostic.bug ~span "lowering expected a literal here"
        | None, _ -> Right (p, arg)) ])
      pairs
  in
  let text (_, (e : T.Expr.t)) =
    match e.T.Expr.node with
    | T.Expr.Integer_lit s | T.Expr.Decimal_lit s -> s
    | T.Expr.Text_lit pieces ->
        (* Each fragment quoted, so a `\%` the text holds never reads as a
           site, and two literals that differ only in where a site falls
           never share a key. *)
        String.concat " "
          (List.map (function T.Expr.Fragment s -> Printf.sprintf "%S" s | T.Expr.Interpolation _ -> "\\%") pieces)
    | _ -> Diagnostic.bug ~span "lowering expected a literal here"
  in
  let key = Printf.sprintf "expanded %s(%s)" v.key (String.concat ", " (List.map text literals)) in
  let params = List.map fst kept in
  let signature = { v.signature with S.home = S.Namespace "zane" } in
  let v' = { v with key; params; literals; signature } in
  if not (Hashtbl.mem st.symbols key) then begin
    Hashtbl.replace st.symbols key (Printf.sprintf "zane.expanded.%d" (numbered st.expanded));
    Queue.add v' st.pending
  end;
  (v', List.map snd kept)

(* A spawned call to an intrinsic, which has no function of its own, runs
   through one named `zane.intrinsic.N` that takes the call's arguments
   and makes the call. One the program has, such as `@program$console`,
   stays where the call reads it. *)
let wrapped st span (callee : T.Verb_ref.t) args ret =
  let spelling = match callee.owner with S.Intrinsic s -> s | S.Declared _ -> "" in
  let abort =
    List.find_map
      (fun (_, (s : S.t)) -> if s.S.owner = callee.owner then s.S.abort else None)
      Tst.Intrinsics.methods
    |> Option.map (Tty.subst (List.map (fun ((p : Tty.param), a) -> (p.Tty.id, a)) callee.instance))
  in
  let parts =
    List.mapi
      (fun i arg ->
        match arg with
        | T.Arg.Value ({ T.Expr.node = T.Expr.Var (T.Name_ref.Intrinsic _); _ } as a) -> (None, a)
        | T.Arg.Value a ->
            let id = -1 - i and ty = a.T.Expr.ty and span = a.T.Expr.span in
            let l = { T.Local.id; name = string_of_int i; ty; span } in
            (Some (l, arg), { a with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) })
        | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block argument cannot be spawned")
      args
  in
  let taken = List.filter_map fst parts in
  let given = List.map (fun (_, a) -> T.Arg.Value a) parts in
  let call = T.Expr.Call { callee; args = given; handler = None } in
  let call = { T.Expr.node = call; ty = ret; span } in
  let body = { T.Block.stats = [ { T.Stat.node = T.Stat.Return call; span } ]; span } in
  let signature =
    {
      S.owner = callee.owner;
      name = spelling;
      home = S.Namespace "zane";
      kind = S.Function;
      generics = [];
      params = [];
      ret;
      abort;
      is_mut = false;
    }
  in
  let n = numbered st.intrinsics in
  let key = Printf.sprintf "intrinsic %d" n in
  let v =
    { decl = -1; key; instance = []; signature; params = List.map fst taken; body; literals = [] }
  in
  Hashtbl.replace st.symbols key (Printf.sprintf "zane.intrinsic.%d" n);
  Queue.add v st.pending;
  (v, List.map snd taken)

(* A spawned call to [v]'s function, or through [fn], a function value's
   address, which runs before the arguments and rides in the frame ahead of
   them. [writes] is whether the call may write its subject. *)
let spawn_call w st ctx span v fn ~writes passed handler =
  let o = outcome st span v in
  let whole = returned o in
  let args = Lower_calls.arguments w ~direct:(Option.is_none fn) st ctx span v passed in
  (* A `mut` subject reached through an owner is copied into the frame,
     and the call works on the copy, which it writes back when it
     returns (§4.4). A function value's subject is lent by its address
     (L14), so one it may not write is read into the frame here, where
     the spawn is written, as a subject passed by value is. *)
  let subject =
    match (v.params, passed) with
    | this :: _, T.Arg.Value subject :: _
      when by_address st v this && this.T.Local.name = "this"
           && (not (reference st this.T.Local.ty))
           && (through_owner st subject || not writes) ->
        Some (this.T.Local.ty, through_owner st subject && snapshots st subject)
    | _ -> None
  in
  let pre, args =
    match (subject, args) with
    | Some (t, shared), first :: rest ->
        let loc = fresh st in
        let place = { Expr.node = Expr.Local loc; ty = Nodes.Ty.Ptr } in
        let read = if shared then Expr.Snapshot place else Expr.Deref place in
        let value = { Expr.node = read; ty = ty st span t } in
        let copy =
          if writes && owns st span t then
            { value with Expr.node = Expr.Copy { value; layout = layout st span t } }
          else value
        in
        ([ Stat.Let { id = loc; value = first } ], (place :: rest) @ [ copy ])
    | _ -> ([], args)
  in
  let fns = Option.to_list fn in
  let shift = List.length fns in
  let stored = fns @ args in
  let frame = Nodes.Ty.Struct (whole :: List.map (fun (a : Expr.t) -> a.Expr.ty) stored) in
  let at = fresh st in
  let member i = ptr (Expr.Offset { base = local_ptr at; within = frame; path = [ i ] }) in
  let copied = List.length stored in
  let passes =
    if Option.is_some subject then List.filteri (fun i _ -> i < List.length args - 1) args
    else args
  in
  let read i (a : Expr.t) =
    if i = 0 && Option.is_some subject then member copied
    else { Expr.node = Expr.Deref (member (i + 1 + shift)); ty = a.Expr.ty }
  in
  let given = List.mapi read passes in
  let call =
    match fn with
    | Some _ ->
        let fn = { Expr.node = Expr.Deref (member 1); ty = Nodes.Ty.Ptr } in
        { Expr.node = Expr.Call_value { fn; args = given }; ty = whole }
    | None -> { Expr.node = Expr.Call { fn = symbol st v; args = given }; ty = whole }
  in
  let writeback =
    match subject with
    | Some (t, _) when writes ->
        let size = fst (Nodes.Ty.size_align (ty st span t)) in
        let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
        let target = { Expr.node = Expr.Deref (member (1 + shift)); ty = Nodes.Ty.Ptr } in
        let back =
          Expr.Runtime
            {
              fn = Runtime.Writeback;
              args = [ target; member copied; int size; layout_table (layout st span t) ];
            }
        in
        [ Stat.Eval { Expr.node = back; ty = Nodes.Ty.Void } ]
    | _ -> []
  in
  let body =
    (if whole = Nodes.Ty.Void then [ Stat.Eval call ]
     else [ Stat.Store { address = member 0; value = call } ])
    @ writeback
  in
  let thunk = Printf.sprintf "zane.spawn.%d" (List.length st.spawned + 1) in
  st.spawned <-
    {
      Func.symbol = thunk;
      linkage = Linkage.Local;
      params = [ (at, Nodes.Ty.Ptr) ];
      places = [];
      ret = Nodes.Ty.Void;
      body;
      values = [];
    }
    :: st.spawned;
  let task = fresh st in
  let dest = if whole = Nodes.Ty.Void then None else Some (fresh st) in
  let home =
    if plain o then layout st span v.signature.S.ret else outcome_layout st span v
  in
  let scope = arena st ctx.scope in
  let spawned = Stat.Spawn { task; scope; thunk; frame; args = stored; dest; layout = home } in
  let slot = Option.map (fun id -> ptr (Expr.Address id)) dest in
  if plain o then
    (pre @ [ spawned ], Future { settle = (fun () -> [ Stat.Join task ]); at = slot })
  else
    let slot =
      match slot with
      | Some slot -> slot
      | None -> Diagnostic.bug ~span "lowering: a spawn with an outcome has nowhere to put it"
    in
    let pending = fresh st in
    let payload i = ptr (Expr.Offset { base = slot; within = whole; path = [ i ] }) in
    let settle () =
      let label = fresh st in
      let resolve _ value =
        let value = outcome_case o done_ value in
        [ Stat.Place { address = slot; value; layout = home }; Stat.Leave label ]
      in
      let on_abort =
        match handler with
        | Some h ->
            Lower_match.handle w ~resolve ?dropped:v.signature.S.abort st ctx h label None
        | None -> ctx.abort
      in
      let failed =
        match (o.aborts, v.signature.S.abort) with
        | Some a, Some t ->
            let l = layout st span t in
            let value = Expr.Take { address = payload aborted; layout = l } in
            let value = { Expr.node = value; ty = a } in
            [ (aborted, on_abort span value) ]
        | _ -> []
      in
      let left = if o.exit_ then [ (exited, ctx.finish span) ] else [] in
      let cases = ((done_, []) :: failed) @ left in
      let flag = { Expr.node = Expr.Local pending; ty = Nodes.Ty.I1 } in
      let whole = { Expr.node = Expr.Deref slot; ty = whole } in
      let once =
        [
          Stat.assign pending { Expr.node = Expr.Bool false; ty = Nodes.Ty.I1 };
          Stat.Switch { value = whole; cases };
        ]
      in
      let body = [ Stat.Join task; Stat.If { cond = flag; body = once } ] in
      let settled = Expr.Expand { label; body; result = None } in
      [ Stat.Eval { Expr.node = settled; ty = Nodes.Ty.Void } ]
    in
    ctx.scope.settles <- settle :: ctx.scope.settles;
    let unsettled = { Expr.node = Expr.Bool true; ty = Nodes.Ty.I1 } in
    let first = Stat.Let { id = pending; value = unsettled } in
    let at = if o.ok = Nodes.Ty.Void then None else Some (payload done_) in
    (pre @ [ first; spawned ], Future { settle; at })

(* concurrency.md §3. A spawned call's arguments run here, as any call's do
   (L6), and are stored in a frame in this block's arena. A function of its
   own reads them from there on a thread of the pool, calls the verb, and
   stores how it ended at the frame's start. The block waits for the call
   before it drains (§4.1), and the result comes home to a slot reserved in
   the same arena: at a read of the local it is bound to, or at the drain.

   A call that can abort or exit settles on this thread, once, where it is
   first read, or where the block ends when nothing reads it first
   (docs/spec-divergences.md §8). An abort runs the handler written at the
   spawn (§3.3), or goes where an abort from here goes, and its `resolve`
   gives the result; an exit ends the run of the block the spawn is in. *)
let rec spawn w st ctx span (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Spawn inner -> spawn w st ctx span inner
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } -> (
      match verb_of st id instance with
      | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
      | Some v when expands v ->
          let v, args = specialized st ctx span v (Lower_calls.passed v args) in
          spawn_call w st ctx span v None ~writes:v.signature.S.is_mut args handler
      | Some v -> (
          match Lower_calls.passed v args with
          | T.Arg.Value subject :: rest
            when v.signature.S.is_mut && Lower_calls.subscripted subject ->
              let lets, args = Lower_calls.held_last w st ctx span v subject rest in
              let stats, future = spawn_call w st ctx span v None ~writes:true args handler in
              (lets @ stats, future)
          | args -> spawn_call w st ctx span v None ~writes:v.signature.S.is_mut args handler))
  | T.Expr.Call { callee = { owner = S.Intrinsic _; _ } as callee; args; handler } ->
      let v, args = wrapped st span callee args e.T.Expr.ty in
      spawn_call w st ctx span v None ~writes:false args handler
  | T.Expr.Call_value { callee; args; handler } -> (
      match Tty.strip_mode callee.T.Expr.ty with
      | Tty.Verb fv -> (
          let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
          let (fn : Expr.t) = w.value_of st ctx callee in
          match args with
          | T.Arg.Value subject :: rest
            when fv.Tty.is_mut && Option.is_some fv.Tty.this_ && Lower_calls.subscripted subject ->
              let id = fresh st in
              let read = { Expr.node = Expr.Local id; ty = fn.Expr.ty } in
              let lets, args = Lower_calls.held_last w ~direct:false st ctx span v subject rest in
              let stats, future =
                spawn_call w st ctx span v (Some read) ~writes:true args handler
              in
              ((Stat.Let { id; value = fn } :: lets) @ stats, future)
          | _ -> spawn_call w st ctx span v (Some fn) ~writes:fv.Tty.is_mut args handler)
      | _ -> Diagnostic.bug ~span "lowering expected a function value here")
  | _ -> Diagnostic.bug ~span "lowering: a spawn of something not a call"
