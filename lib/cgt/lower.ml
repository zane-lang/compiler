(* Lowering: the TST to the CGT (docs/design/lowering.md).

   What is lowered is what `main` reaches. A verb is lowered once, the first
   time a call reaches it, so a program pays only for the verbs it uses and a
   package's other declarations need not lower yet. Anything lowering cannot
   handle yet is refused with a diagnostic at the node, rather than lowered
   wrongly.

   This file is the recursive walk over verbs and programs. What it reads is
   beside it: [State], [Type_layout] and [Literals]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes

type problem = State.problem = Diagnostic of Diagnostic.t | Message of string

open State
open Type_layout
open Literals

(* ---------------------------------------------------------------------- *)
(* Verbs                                                                  *)
(* ---------------------------------------------------------------------- *)

(* A verb's symbol is its declaration as written (Symbol.verb). Asking for
   one queues the verb to be lowered, once. *)
let symbol st (v : verb) =
  match Hashtbl.find_opt st.symbols v.key with
  | Some s -> s
  | None ->
      let s = Symbol.verb v.signature v.instance in
      Hashtbl.replace st.symbols v.key s;
      Queue.add v st.pending;
      s

(* A verb's key: its declaration's id, with an instance's arguments. *)
let key decl (instance : (Tty.param * Tty.arg) list) =
  match instance with
  | [] -> string_of_int decl
  | args ->
      Printf.sprintf "%d<%s>" decl
        (String.concat ", " (List.map (fun (_, a) -> Tty.arg_to_string a) args))

(* The verb a reference names: a declaration, or the instance its arguments
   pick. *)
let verb_of st id instance = Hashtbl.find_opt st.verbs (key id instance)

(* L11: a verb with a concept parameter -- a block, or a literal it embeds --
   has no function. Each call to it is replaced by its body. *)
let expands (v : verb) =
  List.exists
    (fun (p : T.Local.t) -> match p.T.Local.ty with Tty.Concept _ -> true | _ -> false)
    v.params

(* How a verb's call can end (L12): its primary result, and the abort value
   when it declares an abort type, and an exit when it has one. *)
type outcome = { ok : Nodes.Ty.t; aborts : Nodes.Ty.t option; exit_ : bool }

let outcome st span (v : verb) =
  {
    ok = ty st span v.signature.S.ret;
    aborts = Option.map (ty st span) v.signature.S.abort;
    exit_ = Tst.Exits.block v.body;
  }

(* A function that can end more than one way returns a sum of the three:
   done with its result, aborted with its abort value, or exited
   (docs/design/lowering.md §9). One that can only finish returns its result. *)
let plain o = o.aborts = None && not o.exit_

let returned o =
  if plain o then o.ok
  else Nodes.Ty.Sum [ o.ok; Option.value o.aborts ~default:Nodes.Ty.Void; Nodes.Ty.Void ]

let done_ = 0
let aborted = 1
let exited = 2

let outcome_case o index (payload : Expr.t) =
  { Expr.node = Expr.Case { index; payload }; ty = returned o }

let unit_ = { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }

(* Where the hosts and blocks of a call's outcome are, when it can end more
   than one way: the result's under the done tag, and the abort value's
   under the aborted one. *)
let outcome_layout st span (v : verb) =
  let s = v.signature in
  let name =
    Printf.sprintf "outcome of %s%s" (Symbol.ty s.S.ret)
      (match s.S.abort with Some a -> " ? " ^ Symbol.ty a | None -> "")
  in
  if not (Hashtbl.mem st.layouts name) then begin
    let under tag t = positions st span t Nodes.Ty.payload_offset [ (0, tag) ] in
    let failed = match s.S.abort with Some a -> under aborted a | None -> [] in
    Hashtbl.replace st.layouts name (under done_ s.S.ret @ failed);
    st.named <- name :: st.named
  end;
  name

(* L6: a `mut` method's subject, a reference-type subject, and a swallowed
   reference-type argument are passed as the address of the caller's place;
   the caller's host keeps the value (lifetimes.md §1.5). *)
let by_address st (v : verb) (p : T.Local.t) =
  (v.signature.S.is_mut && p.T.Local.name = "this") || hosted st p.T.Local.ty

let deref id t = { Expr.node = Expr.Deref { Expr.node = Expr.Local id; ty = Nodes.Ty.Ptr }; ty = t }

let binop : Sst.Nodes.Operator.node -> Expr.binop = function
  | Add -> Expr.Add
  | Mul -> Expr.Mul
  | Div -> Expr.Div
  | Eq -> Expr.Eq
  | Less -> Expr.Less

(* A storage primitive's constructor: `Unit` has no storage, a list starts
   empty, and the others embed their literal. *)
let primitive ctx span spelling args : Expr.t =
  let prefix = "@primitives$" in
  let n = String.length prefix in
  let name =
    if String.length spelling > n && String.sub spelling 0 n = prefix then
      String.sub spelling n (String.length spelling - n)
    else spelling
  in
  match (name, args) with
  | "Unit", [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  (* A new list is empty, and owns no block until its first `push`. *)
  | "List", [ _ ] ->
      { Expr.node = Expr.Runtime { fn = "zane_list_new"; args = [] }; ty = Nodes.Ty.Handle }
  | _, [ T.Arg.Value v ] -> literal ctx span name v
  | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling)

(* An exit ends the run of a block (docs/spec-divergences.md §11). Semantics
   rejects one anywhere else, so this is not reached. *)
let no_block span = refuse span "an exit ends the block its call is written in, and this is in none"

(* Where nothing leaves: an enum map's entry, which is a constant. *)
let constant_ctx () =
  let nowhere span = refuse span "lowering expected nothing here to leave" in
  {
    env = Hashtbl.create 1;
    exit = Function;
    expanding = [];
    abort = (fun span _ -> nowhere span);
    resolve = None;
    finish = nowhere;
    exit_call = nowhere;
    scope = { arena = None; settles = [] };
  }

(* A block's arena, made the first time it is needed. *)
let arena st scope =
  match scope.arena with
  | Some a -> a
  | None ->
      let a = fresh st in
      scope.arena <- Some a;
      a

(* A new local: held in the block's arena when it is a host or owns a
   block. *)
let bind st scope span t id value =
  if held st span t then Stat.Host { id; scope = arena st scope; value; layout = layout st span t }
  else Stat.Let { id; value }

let bind_local st scope (l : T.Local.t) id value =
  bind st scope l.T.Local.span l.T.Local.ty id value

let ptr node = { Expr.node; ty = Nodes.Ty.Ptr }

(* A value of type [t] leaving the arenas an exit drains: a host, or a
   value that owns a block, takes its blocks out of them first. *)
let escape st span t exit (value : Expr.t) =
  if held st span t then
    { value with Expr.node = Expr.Escape { value; layout = layout st span t; exit } }
  else value
let layout_table l = ptr (Expr.Layout l)
let resolve (tether : Expr.t) = ptr (Expr.Resolve tether)
let local_ptr id = ptr (Expr.Local id)

(* A storage primitive's operator. The scalars have the machine's own, and
   `@primitives$String` joins and compares in the runtime. *)
let primitive_op span op t (l : Expr.t) (r : Expr.t) =
  match (l.Expr.ty, op) with
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Add ->
      { Expr.node = Expr.Runtime { fn = "zane_text_join"; args = [ l; r ] }; ty = t }
  | Nodes.Ty.Handle, Sst.Nodes.Operator.Eq ->
      let same =
        { Expr.node = Expr.Runtime { fn = "zane_text_equal"; args = [ l; r ] }; ty = Nodes.Ty.I64 }
      in
      let yes = { Expr.node = Expr.Int 1L; ty = Nodes.Ty.I64 } in
      { Expr.node = Expr.Binary { op = Expr.Eq; left = same; right = yes }; ty = t }
  | Nodes.Ty.Handle, _ -> refuse span "`@primitives$String` has no such operator"
  | _ -> { Expr.node = Expr.Binary { op = binop op; left = l; right = r }; ty = t }

let rec expr st ctx (e : T.Expr.t) : Expr.t =
  let span = e.T.Expr.span in
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> { Expr.node = Expr.Local id; ty = ty st span l.T.Local.ty }
      | Pointer id -> deref id (ty st span l.T.Local.ty)
      | Future { settle; at } ->
          let t = ty st span l.T.Local.ty in
          let value =
            match at with Some p -> { Expr.node = Expr.Deref p; ty = t } | None -> unit_
          in
          joined st (settle ()) value
      | Literal _ | Code _ -> refuse span "lowering does not read this parameter as a value")
  | T.Expr.Bool_lit b -> { Expr.node = Expr.Bool b; ty = Nodes.Ty.I1 }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } ->
      primitive ctx span spelling args
  | T.Expr.Coerce { ctor = { owner = S.Intrinsic spelling; _ }; value } ->
      primitive ctx span spelling [ T.Arg.Value value ]
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance; _ }; args; handler }
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } ->
      call st ctx span (verb_of st id instance) args handler e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Declared id; instance; _ }; value } ->
      call st ctx span (verb_of st id instance) [ T.Arg.Value value ] None e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$print"; _ }; args; handler = None }
    -> (
      (* The program has one console (effects.md §6.6), so the subject names
         nothing the runtime needs. The text is a guest to a place in this
         frame, and the runtime reads the view stored there (L10). *)
      match args with
      | [ T.Arg.Value _console; T.Arg.Value text ] ->
          {
            Expr.node = Expr.Runtime { fn = "zane_print"; args = [ borrow st ctx span text ] };
            ty = Nodes.Ty.Void;
          }
      | _ -> refuse span "lowering does not handle this call to `print`")
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$setThreads"; _ }; args; handler }
    -> (
      (* The pool is resized (concurrency.md §2.4), or, for a count below
         one, left as it was, and the call aborts with `Unit`. The program
         has one runtime, so the subject names nothing the runtime needs. *)
      match args with
      | [ T.Arg.Value _runtime; T.Arg.Value count ] ->
          let count = borrow st ctx span count in
          let label = fresh st in
          let id = fresh st in
          let set = Expr.Runtime { fn = "zane_set_threads"; args = [ count ] } in
          let set = { Expr.node = set; ty = Nodes.Ty.I64 } in
          let zero = { Expr.node = Expr.Int 0L; ty = Nodes.Ty.I64 } in
          let local = { Expr.node = Expr.Local id; ty = Nodes.Ty.I64 } in
          let failed = Expr.Binary { op = Expr.Eq; left = local; right = zero } in
          let failed = { Expr.node = failed; ty = Nodes.Ty.I1 } in
          let on_abort =
            match handler with Some h -> handle st ctx h label None | None -> ctx.abort
          in
          let body =
            [ Stat.Let { id; value = set }; Stat.If { cond = failed; body = on_abort span unit_ } ]
          in
          { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void }
      | _ -> refuse span "lowering does not handle this call to `setThreads`")
  | T.Expr.Call
      {
        callee = { owner = S.Intrinsic "@runtime$setThreadsAuto"; _ };
        args = [ _ ];
        handler = None;
      } ->
      { Expr.node = Expr.Runtime { fn = "zane_set_threads_auto"; args = [] }; ty = Nodes.Ty.Void }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$push"; _ }; args; handler = None }
    -> (
      (* The value is taken first, then the list makes room for it, which may
         move its elements, and the value moves into the new last element. *)
      match args with
      | [ T.Arg.Value list; T.Arg.Value value ] ->
          let t = Option.get (element (strip list.T.Expr.ty)) in
          let taken = moved st ctx span t value in
          let v = fresh st in
          let at = fresh st in
          let label = fresh st in
          let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
          let l = layout st span t in
          let room =
            Expr.Runtime
              {
                fn = "zane_list_push";
                args = [ lend st ctx span list; int (stride st span t); layout_table l ];
              }
          in
          let body =
            [
              Stat.Let { id = v; value = taken };
              Stat.Let { id = at; value = ptr room };
              Stat.Place
                {
                  address = local_ptr at;
                  value = { Expr.node = Expr.Local v; ty = taken.Expr.ty };
                  layout = l;
                };
            ]
          in
          { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void }
      | _ -> refuse span "lowering does not handle this call to `push`")
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$size"; _ }; args; handler = None }
    -> (
      match args with
      | [ T.Arg.Value list ] ->
          let value = borrow st ctx span list in
          { Expr.node = Expr.Member { value; index = 2 }; ty = Nodes.Ty.I64 }
      | _ -> refuse span "lowering does not handle this call to `size`")
  | T.Expr.Subscript _ -> (
      match addr st ctx span e with
      | Some p -> { Expr.node = Expr.Deref p; ty = ty st span e.T.Expr.ty }
      | None -> refuse span "lowering does not handle this subscript yet")
  | T.Expr.Op { op; impl = { owner; instance; _ }; left; right; swapped; handler } -> (
      let t = ty st span e.T.Expr.ty in
      (* [left] and [right] are in written order, and run in it
         (operators.md §2.3). When the desugaring swapped them, they are passed
         the other way round: `a > b` calls `<` with `b` first. *)
      let operands l r apply =
        if swapped then in_order st t l r (fun l r -> apply r l)
        else
          let l = l () in
          apply l (r ())
      in
      match owner with
      | S.Intrinsic _ ->
          operands
            (fun () -> borrow st ctx span left)
            (fun () -> borrow st ctx span right)
            (fun l r -> primitive_op span op t l r)
      | S.Declared id -> (
          match verb_of st id instance with
          | Some ({ params = [ pl; pr ]; _ } as v) when not (expands v) ->
              let for_left, for_right = if swapped then (pr, pl) else (pl, pr) in
              operands
                (fun () -> argument st ctx span v for_left left)
                (fun () -> argument st ctx span v for_right right)
                (fun l r -> invoke st ctx span v [ l; r ] handler)
          | _ -> refuse span "lowering does not handle this operator yet"))
  | T.Expr.Flip { impl = { owner = S.Intrinsic _; _ }; value; handler = None } ->
      { Expr.node = Expr.Flip (expr st ctx value); ty = ty st span e.T.Expr.ty }
  | T.Expr.Flip { impl = { owner = S.Declared id; instance; _ }; value; handler } ->
      call st ctx span (verb_of st id instance) [ T.Arg.Value value ] handler e.T.Expr.ty
  | T.Expr.Field { target; slot; _ } ->
      let t = ty st span e.T.Expr.ty in
      let owner = strip target.T.Expr.ty in
      let index = member_index st owner slot in
      if boxed st owner (field_type st span owner slot) then
        (* A boxed member's payload is in its block. *)
        match addr st ctx span e with
        | Some p -> { Expr.node = Expr.Deref p; ty = t }
        | None -> refuse span "lowering does not read a boxed member of a fresh value yet"
      else if is_guest target.T.Expr.ty then
        (* Read through the guest, where its host is now (memory.md §4.4). *)
        let base = resolve (expr st ctx target) in
        let within = ty st span owner in
        { Expr.node = Expr.Deref (ptr (Expr.Offset { base; within; path = [ index ] })); ty = t }
      else if collapsed st owner then { (borrow st ctx span target) with ty = t }
      else { Expr.node = Expr.Member { value = borrow st ctx span target; index }; ty = t }
  | T.Expr.Init fields | T.Expr.Construct_fields { fields; handler = None; _ } ->
      record st ctx span e.T.Expr.ty fields
  | T.Expr.Case { case; payload } ->
      let index = case_index st span e.T.Expr.ty case in
      let t = payload_type st span e.T.Expr.ty case in
      let payload = member st ctx span e.T.Expr.ty t payload in
      case_of st span e.T.Expr.ty index payload
  | T.Expr.Enum_member case ->
      let index = case_index st span e.T.Expr.ty case in
      case_of st span e.T.Expr.ty index unit_
  | T.Expr.Match { scrutinees; arms; handler } ->
      match_ st ctx span scrutinees arms handler e.T.Expr.ty
  | T.Expr.Case_read { target; case; handler } ->
      case_read st ctx span target case handler e.T.Expr.ty
  | T.Expr.Map_read { target; map; _ } -> map_read st ctx span target map e.T.Expr.ty
  (* A spawned call read where it is written is waited for at once, which
     is the call itself (docs/design/lowering.md §9). *)
  | T.Expr.Spawn call -> expr st ctx call
  | _ -> refuse span "lowering does not handle this expression yet"

(* A spawned call's result, read once the call has returned (concurrency.md
   §3.2). *)
and joined st settle (value : Expr.t) =
  let label = fresh st in
  if value.Expr.ty = Nodes.Ty.Void then
    { Expr.node = Expr.Expand { label; body = settle; result = None }; ty = value.ty }
  else
    let result = fresh st in
    let body = settle @ [ Stat.assign result value ] in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }

(* A member's value on its way into the type [holder] being built: moved
   there, and placed in a block of its own when the member is boxed. *)
and member st ctx span holder t (e : T.Expr.t) =
  let value = moved st ctx span t e in
  if boxed st holder t then ptr (Expr.Box { value; layout = layout st span t }) else value

(* A struct built member by member, in the order they were written. One of a
   single member is that member, and an empty one is nothing (L5). *)
and record st ctx span t (fields : T.Field_value.t list) =
  let lowered = ty st span t in
  let value (f : T.Field_value.t) =
    member st ctx span t (field_type st span t f.T.Field_value.slot) f.T.Field_value.value
  in
  let members fields =
    List.map (fun (f : T.Field_value.t) -> (member_index st t f.T.Field_value.slot, value f)) fields
  in
  match (lowered, fields) with
  | Nodes.Ty.Void, [] -> { Expr.node = Expr.Unit; ty = Nodes.Ty.Void }
  (* A reference type's instance starts untethered (memory.md §4.3). *)
  | Nodes.Ty.Struct (bp :: rest), _ when reference st t && List.length rest = List.length fields ->
      let untethered = (0, { Expr.node = Expr.Int 0L; ty = bp }) in
      { Expr.node = Expr.Record (untethered :: members fields); ty = lowered }
  | Nodes.Ty.Struct ms, _ when List.length ms = List.length fields ->
      { Expr.node = Expr.Record (members fields); ty = lowered }
  | _, [ f ] when collapsed st t -> { (value f) with ty = lowered }
  | _ -> refuse span "lowering does not fill a member's default yet"

(* A value read where its type's own storage is wanted: through a guest, the
   host it names. *)
and value_of st ctx (e : T.Expr.t) =
  if is_guest e.T.Expr.ty then
    let t = ty st e.T.Expr.span (strip e.T.Expr.ty) in
    { Expr.node = Expr.Deref (resolve (expr st ctx e)); ty = t }
  else read st ctx e

(* A value read out of its place. One reached through a host is read as a
   snapshot (concurrency.md §4.4). *)
and read st ctx (e : T.Expr.t) =
  let span = e.T.Expr.span in
  if through_host st e && not (reference st e.T.Expr.ty) then
    match addr st ctx span e with
    | Some p -> { Expr.node = Expr.Snapshot p; ty = ty st span e.T.Expr.ty }
    | None -> expr st ctx e
  else expr st ctx e

(* The address of the value a place holds (L10): through a guest, the host
   it names now (memory.md §4.4); otherwise the place's own storage. *)
and addr st ctx span (e : T.Expr.t) : Expr.t option =
  if is_guest e.T.Expr.ty then Some (resolve (expr st ctx e)) else storage st ctx span e

(* The address of a place's own storage: a local's slot, a `mut` subject's
   or swallowed argument's pointer, and a member of what any place holds. *)
and storage st ctx span (e : T.Expr.t) : Expr.t option =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> Some (ptr (Expr.Address id))
      | Pointer id -> Some (ptr (Expr.Local id))
      | Future { settle; at = Some p } -> Some (joined st (settle ()) p)
      | _ -> None)
  | T.Expr.Field { target; slot; _ } ->
      let owner = strip target.T.Expr.ty in
      let base =
        match addr st ctx span target with
        | Some base -> Some base
        | None when boxed st owner (field_type st span owner slot) -> Some (lend st ctx span target)
        | None -> None
      in
      Option.map
        (fun base ->
          if collapsed st owner then base
          else
            let within = ty st span owner in
            let at = ptr (Expr.Offset { base; within; path = [ member_index st owner slot ] }) in
            (* A boxed member's place is its payload, in its block. *)
            if boxed st owner (field_type st span owner slot) then ptr (Expr.Deref at) else at)
        base
  | T.Expr.Subscript { target; impl; args } -> Some (subscript st ctx span target impl args)
  | T.Expr.Case_read { target; case; handler } when held st span e.T.Expr.ty ->
      Some (case_place st ctx span target case handler e.T.Expr.ty)
  | _ -> None

(* A guest to a place, minted, or an existing guest copied as the identity
   it ends at (memory.md §2.6, §4.4). *)
and guest st ctx span (e : T.Expr.t) =
  if is_guest e.T.Expr.ty then { Expr.node = Expr.Terminal (expr st ctx e); ty = Nodes.Ty.I32 }
  else
    match addr st ctx span e with
    | Some p -> { Expr.node = Expr.Mint p; ty = Nodes.Ty.I32 }
    | None -> refuse span "lowering expected a guest source here"

(* A value on its way into storage of type [dst]: a guest there is minted
   or copied, and a reference-type host read from a place moves, which
   spends the place (memory.md §3.7). *)
and moved st ctx span dst (e : T.Expr.t) =
  if is_guest dst then guest st ctx span e
  else if hosted st dst && not (is_guest e.T.Expr.ty) then
    match e.T.Expr.node with
    | T.Expr.Var _ | T.Expr.Field _ -> (
        match addr st ctx span e with
        | Some address ->
            let l = layout st span dst in
            { Expr.node = Expr.Take { address; layout = l }; ty = ty st span dst }
        | None -> refuse span "lowering does not move a host out of a fresh value yet")
    | _ -> expr st ctx e
  else if owns st span dst && is_place e then
    let value = value_of st ctx e in
    { Expr.node = Expr.Copy { value; layout = layout st span dst }; ty = value.Expr.ty }
  else read st ctx e

(* Whether an expression reads a value something else owns, rather than
   making a fresh one: a place, a member of any value, which a fresh value
   is borrowed for, an element, or what a case read gives. *)
and is_place (e : T.Expr.t) =
  is_guest e.T.Expr.ty
  ||
  match e.T.Expr.node with
  | T.Expr.Var _ | T.Expr.Field _ | T.Expr.Subscript _ | T.Expr.Case_read _ -> true
  | _ -> false

(* A value read where it is only looked at, as a value parameter or an
   operand: a place is read where it is, and a fresh host, or a fresh value
   that owns a block, is held in this scope first, so the scope's drain ends
   it and returns its blocks. *)
and borrow st ctx span (e : T.Expr.t) =
  if held st span e.T.Expr.ty && not (is_place e) then begin
    let value = expr st ctx e in
    let id = fresh st in
    let label = fresh st in
    let result = fresh st in
    let body =
      [
        bind st ctx.scope span e.T.Expr.ty id value;
        Stat.assign result { Expr.node = Expr.Local id; ty = value.Expr.ty };
      ]
    in
    { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }
  end
  else value_of st ctx e

(* The address a callee is lent (L6): the caller's place, or a fresh value
   stored here first, which this scope then hosts. *)
and lend st ctx span (a : T.Expr.t) =
  match addr st ctx span a with
  | Some p -> p
  | None ->
      let value = expr st ctx a in
      let id = fresh st in
      let label = fresh st in
      let result = fresh st in
      let body =
        [ bind st ctx.scope span a.T.Expr.ty id value; Stat.assign result (ptr (Expr.Address id)) ]
      in
      ptr (Expr.Expand { label; body; result = Some result })

(* L13. The scrutinees are reached once, in order, and a switch on each one's
   tag nests inside the last; the semantic pass wrote one arm per
   combination of cases, so each arm is lowered once, where its combination
   is reached. A binder is the address of its case's payload, in the
   scrutinee's own storage when it is a place, so a write through it is a
   write to the payload. A `return` in an arm is the `match`'s value. *)
and match_ st ctx span scrutinees (arms : T.Arm.t list) handler ret =
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  let stored =
    List.map
      (fun (e : T.Expr.t) ->
        let tsty = strip e.T.Expr.ty in
        let within = ty st span tsty in
        let lets, pointer =
          match addr st ctx span e with
          | Some p ->
              let pointer = fresh st in
              ([ Stat.Let { id = pointer; value = p } ], pointer)
          | None ->
              let value = value_of st ctx e in
              let id = fresh st in
              let pointer = fresh st in
              (* A fresh instance is hosted here, like any other. *)
              let at = Stat.Let { id = pointer; value = ptr (Expr.Address id) } in
              ([ bind st ctx.scope span tsty id value; at ], pointer)
        in
        let whole = { Expr.node = Expr.Deref (local_ptr pointer); ty = within } in
        (pointer, sum_of st span tsty whole, tsty, lets))
      scrutinees
  in
  (* An arm's abort is the `match`'s (error-handling.md §3.5). *)
  let abort = match handler with Some h -> handle st ctx h label result | None -> ctx.abort in
  let inner = { ctx with exit = Leave { label; result; ret }; abort } in
  let selects chosen (a : T.Arm.t) =
    List.map (fun (p : T.Pattern.t) -> p.T.Pattern.case) a.patterns = chosen
  in
  let arm chosen =
    match List.find_opt (selects chosen) arms with
    | None -> refuse span "lowering found no arm for a combination of cases"
    | Some a ->
        let binds =
          List.concat
            (List.map2
               (fun (p : T.Pattern.t) (pointer, _, tsty, _) ->
                 match p.T.Pattern.binder with
                 | None -> []
                 | Some l ->
                     let index = case_index st span tsty p.case in
                     let path = (if reference st tsty then [ 1 ] else []) @ [ index ] in
                     let within = ty st span tsty in
                     let at = ptr (Expr.Offset { base = local_ptr pointer; within; path }) in
                     (* A boxed payload is in its block. *)
                     let boxed = boxed st tsty (payload_type st span tsty p.case) in
                     let value = if boxed then ptr (Expr.Deref at) else at in
                     let bound = fresh st in
                     Hashtbl.replace ctx.env l.T.Local.id (Pointer bound);
                     [ Stat.Let { id = bound; value } ])
               a.patterns stored)
        in
        binds @ block st inner a.body
  in
  let rec dispatch chosen = function
    | [] -> arm (List.rev chosen)
    | (_, source, tsty, _) :: rest ->
        let cases =
          List.mapi (fun i c -> (i, dispatch (c :: chosen) rest)) (cases st span tsty)
        in
        [ Stat.Switch { value = source; cases } ]
  in
  let lets = List.concat_map (fun (_, _, _, l) -> l) stored in
  { Expr.node = Expr.Expand { label; body = lets @ dispatch [] stored; result }; ty = t }

(* An enum map read is a switch on the member, each case giving its entry. *)
and map_read st ctx span target map ret =
  match Hashtbl.find_opt st.maps map with
  | None -> refuse span "lowering found no enum map here"
  | Some (enum, entries) ->
      let t = ty st span ret in
      let label = fresh st in
      let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
      let value = value_of st ctx target in
      let id = fresh st in
      let entry_ctx = { (constant_ctx ()) with expanding = ctx.expanding } in
      let cases =
        List.mapi
          (fun i member ->
            match List.assoc_opt member entries with
            | Some e -> (i, leave label result (expr st entry_ctx e))
            | None -> refuse span (Printf.sprintf "the enum map has no entry for `%s`" member))
          (cases st span enum)
      in
      {
        Expr.node =
          Expr.Expand
            {
              label;
              body =
                [
                  Stat.Let { id; value };
                  Stat.Switch
                    {
                      value = sum_of st span enum { Expr.node = Expr.Local id; ty = value.Expr.ty };
                      cases;
                    };
                ];
              result;
            };
        ty = t;
      }

(* A handler, run where its operation aborted: its binder holds the abort
   value, and a `resolve` gives the operation its value and goes past it. *)
(* A handler is a block of its own, so an abort value of a reference type
   is hosted in the handler's arena, which is innermost wherever the handler
   runs. *)
and handle ?resolve ?dropped st ctx (h : T.Handler.t) label result span (value : Expr.t) =
  let scope = { arena = None; settles = [] } in
  let bind =
    match (h.T.Handler.binder, dropped) with
    | Some l, _ ->
        let id = fresh st in
        Hashtbl.replace ctx.env l.T.Local.id (Slot id);
        [ bind_local st scope l id value ]
    (* An abort value no binder names, of type [dropped], is still held
       here when it is a host or owns a block, so the drain ends it. *)
    | None, Some t when held st span t -> [ bind st scope span t (fresh st) value ]
    | None, _ -> [ Stat.Eval value ]
  in
  let resolve =
    match resolve with
    | Some r -> r
    | None -> fun t value -> leave label result (escape st span t (Some label) value)
  in
  let inner = { ctx with resolve = Some resolve; scope } in
  let body = bind @ block st inner h.T.Handler.body in
  match scope.arena with None -> body | Some id -> [ Stat.Scope { id; body } ]

(* A case read is its payload when the case is live, and runs its handler
   when another is (adt.md §5.2). The other cases fall through to it. *)
and case_read st ctx span (target : T.Expr.t) case handler ret =
  let t = ty st span ret in
  if held st span ret then
    { Expr.node = Expr.Deref (case_place st ctx span target case handler ret); ty = t }
  else
    let label = fresh st in
    let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
    let value = borrow st ctx span target in
    let id = fresh st in
    let live = case_index st span target.T.Expr.ty case in
    let tsty = strip target.T.Expr.ty in
    let source = sum_of st span tsty { Expr.node = Expr.Local id; ty = value.Expr.ty } in
    let payload i = { Expr.node = Expr.Payload { value = source; index = i }; ty = t } in
    let cases =
      List.mapi
        (fun i _ -> if i = live then (i, leave label result (payload i)) else (i, []))
        (cases st span target.T.Expr.ty)
    in
    let otherwise = handle st ctx handler label result span unit_ in
    let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] @ otherwise in
    { Expr.node = Expr.Expand { label; body; result }; ty = t }

(* A case read of a host, or of a value that owns a block, as a place: the
   payload where the variant holds it when the case is live, or else a slot
   reserved in this scope before the read, which the handler's `resolve`
   fills. Either way what the read gives has one owner, and a copy of it
   owns blocks of its own. *)
and case_place st ctx span (target : T.Expr.t) case handler ret =
  let t = ty st span ret in
  let tsty = strip target.T.Expr.ty in
  let within = ty st span tsty in
  let label = fresh st in
  let result = fresh st in
  let base = fresh st in
  let spare = fresh st in
  let l = layout st span ret in
  let live = case_index st span tsty case in
  let whole = { Expr.node = Expr.Deref (local_ptr base); ty = within } in
  let payload =
    let path = (if reference st tsty then [ 1 ] else []) @ [ live ] in
    let at = ptr (Expr.Offset { base = local_ptr base; within; path }) in
    if boxed st tsty ret then ptr (Expr.Deref at) else at
  in
  let cases =
    List.mapi
      (fun i _ -> if i = live then (i, leave label (Some result) payload) else (i, []))
      (cases st span tsty)
  in
  let resolve _ value =
    [
      Stat.Place { address = ptr (Expr.Address spare); value; layout = l };
      Stat.assign result (ptr (Expr.Address spare));
      Stat.Leave label;
    ]
  in
  let otherwise = handle ~resolve st ctx handler label (Some result) span unit_ in
  let body =
    [
      Stat.Reserve { id = spare; scope = arena st ctx.scope; ty = t; layout = l };
      Stat.Let { id = base; value = lend st ctx span target };
      Stat.Switch { value = sum_of st span tsty whole; cases };
    ]
    @ otherwise
  in
  ptr (Expr.Expand { label; body; result = Some result })

(* The address of an element (functions.md §2.9): a list's, checked against
   its length, or what a declared subscript's body names, with `this` bound
   to the target's place. *)
and subscript st ctx span (target : T.Expr.t) (impl : T.Verb_ref.t) args =
  match (impl.owner, args) with
  | S.Intrinsic "@primitives$[]", [ index ] -> (
      match element (strip target.T.Expr.ty) with
      | Some t ->
          let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
          ptr
            (Expr.Runtime
               {
                 fn = "zane_list_at";
                 args =
                   [ lend st ctx span target; borrow st ctx span index; int (stride st span t) ];
               })
      | None -> refuse span "lowering does not handle this subscript yet")
  | S.Declared id, _ -> (
      match verb_of st id impl.instance with
      | Some ({ params = this :: rest; body = { stats = [ { node = T.Stat.Return e; _ } ]; _ }; _ }
             as v)
        when List.length rest = List.length args ->
          let env = Hashtbl.create 4 in
          let at = fresh st in
          Hashtbl.replace env this.T.Local.id (Pointer at);
          let binds =
            Stat.Let { id = at; value = lend st ctx span target }
            :: List.map2
                 (fun (p : T.Local.t) a ->
                   let id = fresh st in
                   Hashtbl.replace env p.T.Local.id (Slot id);
                   Stat.Let { id; value = borrow st ctx span a })
                 rest args
          in
          let inner = { ctx with env; expanding = v.decl :: ctx.expanding } in
          let label = fresh st in
          let result = fresh st in
          let place =
            match addr st inner span e with
            | Some p -> p
            | None -> refuse span "lowering expected a subscript's body to name a place"
          in
          ptr
            (Expr.Expand
               { label; body = binds @ [ Stat.assign result place ]; result = Some result })
      | _ -> refuse span "lowering does not handle this subscript yet")
  | _ -> refuse span "lowering does not handle this subscript yet"

(* What a `return` to an expansion does: store the result, and leave. *)
and leave label result value =
  match result with
  | Some id -> [ Stat.assign id value; Stat.Leave label ]
  | None -> [ Stat.Eval value; Stat.Leave label ]

(* Two operands stored in the order they are given, then combined. *)
and in_order st t first second combine =
  let store make =
    let (v : Expr.t) = make () in
    let id = fresh st in
    ({ Expr.node = Expr.Local id; ty = v.Expr.ty }, Stat.Let { id; value = v })
  in
  let a, let_a = store first in
  let b, let_b = store second in
  let label = fresh st in
  let result = fresh st in
  {
    Expr.node =
      Expr.Expand
        {
          label;
          body = [ let_a; let_b; Stat.assign result (combine a b) ];
          result = Some result;
        };
    ty = t;
  }

and call st ctx span verb args handler ret : Expr.t =
  let args = passed args in
  match verb with
  | None -> refuse span "lowering does not handle a call to this verb yet"
  | Some v when expands v -> expand st ctx span v args handler ret
  | Some v -> invoke st ctx span v (arguments st ctx span v args) handler

(* A type written where a value goes picks the instance, and an instance
   takes no parameter for it (generics.md §5.3). *)
and passed args =
  List.filter
    (function T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> false | _ -> true)
    args

and arguments st ctx span v args =
  List.map2
    (fun (p : T.Local.t) arg ->
      match arg with
      | T.Arg.Value a -> argument st ctx span v p a
      | T.Arg.Block _ -> refuse span "lowering does not expand block arguments here")
    v.params args

(* concurrency.md §3. A spawned call's arguments run here, as any call's do
   (L6), and are stored in a frame in this block's arena. A function of its
   own reads them from there on a thread of the pool, calls the verb, and
   stores how it ended at the frame's start. The block waits for the call
   before it drains (§4.1), and the result comes home to a slot reserved in
   the same arena: at a read of the local it is bound to, or at the drain.

   A call that can abort or exit settles on this thread, once, where it is
   first read, or where the block ends when nothing reads it first
   (docs/spec-divergences.md §13). An abort runs the handler written at the
   spawn (§3.3), or goes where an abort from here goes, and its `resolve`
   gives the result; an exit ends the run of the block the spawn is in. *)
and spawn st ctx span (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Spawn inner -> spawn st ctx span inner
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } -> (
      match verb_of st id instance with
      | None -> refuse span "lowering does not handle a call to this verb yet"
      | Some v when expands v ->
          refuse span "lowering does not spawn a verb that is expanded where it is called yet"
      | Some v ->
          let o = outcome st span v in
          let whole = returned o in
          let passed = passed args in
          let args = arguments st ctx span v passed in
          (* A `mut` subject reached through a host is copied into the frame,
             and the call works on the copy, which it writes back when it
             returns (§4.4). *)
          let subject =
            match (v.params, passed) with
            | this :: _, T.Arg.Value subject :: _
              when v.signature.S.is_mut && this.T.Local.name = "this"
                   && (not (reference st this.T.Local.ty))
                   && through_host st subject ->
                Some this.T.Local.ty
            | _ -> None
          in
          let pre, args =
            match (subject, args) with
            | Some t, first :: rest ->
                let loc = fresh st in
                let place = { Expr.node = Expr.Local loc; ty = Nodes.Ty.Ptr } in
                let value = { Expr.node = Expr.Snapshot place; ty = ty st span t } in
                let copy =
                  if owns st span t then
                    { value with Expr.node = Expr.Copy { value; layout = layout st span t } }
                  else value
                in
                ([ Stat.Let { id = loc; value = first } ], (place :: rest) @ [ copy ])
            | _ -> ([], args)
          in
          let frame = Nodes.Ty.Struct (whole :: List.map (fun (a : Expr.t) -> a.Expr.ty) args) in
          let at = fresh st in
          let member i = ptr (Expr.Offset { base = local_ptr at; within = frame; path = [ i ] }) in
          let copied = List.length args in
          let passes =
            if Option.is_some subject then List.filteri (fun i _ -> i < copied - 1) args
            else args
          in
          let read i (a : Expr.t) =
            if i = 0 && Option.is_some subject then member copied
            else { Expr.node = Expr.Deref (member (i + 1)); ty = a.Expr.ty }
          in
          let call =
            { Expr.node = Expr.Call { fn = symbol st v; args = List.mapi read passes }; ty = whole }
          in
          let writeback =
            match subject with
            | Some t ->
                let size = fst (Nodes.Ty.size_align (ty st span t)) in
                let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
                let target = { Expr.node = Expr.Deref (member 1); ty = Nodes.Ty.Ptr } in
                let back =
                  Expr.Runtime
                    {
                      fn = "zane_writeback";
                      args = [ target; member copied; int size; layout_table (layout st span t) ];
                    }
                in
                [ Stat.Eval { Expr.node = back; ty = Nodes.Ty.Void } ]
            | None -> []
          in
          let body =
            (if whole = Nodes.Ty.Void then [ Stat.Eval call ]
             else [ Stat.Store { address = member 0; value = call } ])
            @ writeback
          in
          let thunk = Printf.sprintf "zane.spawn.%d" (List.length st.spawned + 1) in
          st.spawned <-
            { Func.symbol = thunk; params = [ (at, Nodes.Ty.Ptr) ]; ret = Nodes.Ty.Void; body }
            :: st.spawned;
          let task = fresh st in
          let dest = if whole = Nodes.Ty.Void then None else Some (fresh st) in
          let home =
            if plain o then layout st span v.signature.S.ret else outcome_layout st span v
          in
          let scope = arena st ctx.scope in
          let spawned = Stat.Spawn { task; scope; thunk; frame; args; dest; layout = home } in
          let slot = Option.map (fun id -> ptr (Expr.Address id)) dest in
          if plain o then
            (pre @ [ spawned ], Future { settle = (fun () -> [ Stat.Join task ]); at = slot })
          else
            let slot = Option.get slot in
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
                | Some h -> handle ~resolve ?dropped:v.signature.S.abort st ctx h label None
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
            (pre @ [ first; spawned ], Future { settle; at }))
  | _ -> refuse span "lowering spawns only a call to a declared verb yet"

(* An argument as the callee takes it (L6): a place it may write or take
   the host from is lent by its address, a guest is minted or copied, and
   a value is borrowed. *)
and argument st ctx span v (p : T.Local.t) a =
  if by_address st v p then lend st ctx span a
  else if is_guest p.T.Local.ty then guest st ctx span a
  else borrow st ctx span a

(* L12. A call that can end more than one way is switched on how it ended:
   done gives its result, aborted runs its handler, or the abort of the
   `match` it flows out of, and an exit ends this invocation too. *)
and invoke st ctx span v args handler =
  let o = outcome st span v in
  let value = { Expr.node = Expr.Call { fn = symbol st v; args }; ty = returned o } in
  if plain o then value
  else
    let label = fresh st in
    let result = if o.ok = Nodes.Ty.Void then None else Some (fresh st) in
    let id = fresh st in
    let source = { Expr.node = Expr.Local id; ty = value.Expr.ty } in
    let payload index t = { Expr.node = Expr.Payload { value = source; index }; ty = t } in
    let on_abort =
      match handler with
      | Some h -> handle ?dropped:v.signature.S.abort st ctx h label result
      | None -> ctx.abort
    in
    let finished =
      if o.ok = Nodes.Ty.Void then [ (done_, [ Stat.Leave label ]) ]
      else [ (done_, leave label result (payload done_ o.ok)) ]
    in
    let failed =
      match o.aborts with Some a -> [ (aborted, on_abort span (payload aborted a)) ] | None -> []
    in
    let left = if o.exit_ then [ (exited, ctx.finish span) ] else [] in
    let cases = finished @ failed @ left in
    let body = [ Stat.Let { id; value }; Stat.Switch { value = source; cases } ] in
    { Expr.node = Expr.Expand { label; body; result }; ty = o.ok }

(* L11. A parameter is bound to what it stands for in the body: a block
   argument to its code, a literal to itself, the subject or a swallowed
   host to the caller's place, and any other argument to a new slot holding
   its value (L6). *)
and expand st ctx span v args handler ret =
  if List.mem v.decl ctx.expanding then
    refuse span (Printf.sprintf "`%s` expands into itself" v.signature.S.name);
  if List.length args <> List.length v.params then
    refuse span "lowering does not fill a default argument yet";
  let env = Hashtbl.create 8 in
  let bind (p : T.Local.t) b = Hashtbl.replace env p.T.Local.id b in
  let binds =
    List.concat
      (List.map2
         (fun (p : T.Local.t) arg ->
           match (arg, p.T.Local.ty) with
           | T.Arg.Block block, _ ->
               bind p (Code { block; ctx });
               []
           | T.Arg.Value a, Tty.Concept Tty.Block -> (
               match a.T.Expr.node with
               | T.Expr.Var (T.Name_ref.Local l) -> (
                   match lookup ctx span l with
                   | Code c ->
                       bind p (Code c);
                       []
                   | _ -> refuse span "lowering expected a block here")
               | _ -> refuse span "lowering expected a block here")
           | T.Arg.Value a, Tty.Concept _ ->
               bind p (Literal (literal_of ctx a));
               []
           | ( T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); T.Expr.ty = at; _ },
               _ )
             when (p.T.Local.name = "this" || hosted st p.T.Local.ty) && not (is_guest at) -> (
               match lookup ctx span l with
               | (Slot _ | Pointer _) as b ->
                   bind p b;
                   []
               | Future { settle; at = Some at } ->
                   let id = fresh st in
                   bind p (Pointer id);
                   settle () @ [ Stat.Let { id; value = at } ]
               | _ -> refuse span "lowering expected a place here")
           (* Any other place the body may write, or take the host from, is
              lent by its address. *)
           | T.Arg.Value a, _ when p.T.Local.name = "this" || hosted st p.T.Local.ty ->
               let value = lend st ctx span a in
               let id = fresh st in
               bind p (Pointer id);
               [ Stat.Let { id; value } ]
           | T.Arg.Value a, _ ->
               let value =
                 if is_guest p.T.Local.ty then guest st ctx span a else borrow st ctx span a
               in
               let id = fresh st in
               bind p (Slot id);
               [ Stat.Let { id; value } ])
         v.params args)
  in
  let t = ty st span ret in
  let label = fresh st in
  let result = if t = Nodes.Ty.Void then None else Some (fresh st) in
  (* An exit in the body ends the invocation the call was written in, and
     one that body calls ends the expansion (control-flow.md §4.2). *)
  let inner =
    {
      env;
      exit = Leave { label; result; ret };
      expanding = v.decl :: ctx.expanding;
      abort =
        (match handler with
        | Some h -> handle ?dropped:v.signature.S.abort st ctx h label result
        | None -> ctx.abort);
      resolve = None;
      finish = no_block;
      exit_call = ctx.finish;
      scope = ctx.scope;
    }
  in
  match binds @ block st inner v.body with
  (* A body that only returns a value is that value. *)
  | [ Stat.Assign { place = { local; path = []; deref = false; _ }; value }; Stat.Leave l ]
    when Some local = result && l = label ->
      value
  | [ Stat.Eval value; Stat.Leave l ] when result = None && l = label -> value
  | body -> { Expr.node = Expr.Expand { label; body; result }; ty = t }

(* L8: a block that hosts a reference-type local has an arena of its own. *)
and block st ctx (b : T.Block.t) =
  let scope = { arena = None; settles = [] } in
  let body = List.concat_map (stat st { ctx with scope }) b.T.Block.stats in
  (* A spawned call that can abort or exit, and that nothing has read,
     settles where the block ends. *)
  let body = body @ List.concat_map (fun settle -> settle ()) (List.rev scope.settles) in
  match scope.arena with None -> body | Some id -> [ Stat.Scope { id; body } ]

(* A block argument's code, where it was written. An exit ends this run of
   it (docs/spec-divergences.md §11). *)
and code st ctx span (arg : T.Arg.t) =
  let run ctx b =
    let label = fresh st in
    let left = ref false in
    let finish _ =
      left := true;
      [ Stat.Leave label ]
    in
    let body = block st { ctx with finish } b in
    if !left then
      [ Stat.Eval { Expr.node = Expr.Expand { label; body; result = None }; ty = Nodes.Ty.Void } ]
    else body
  in
  match arg with
  | T.Arg.Block b -> run ctx b
  | T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); _ } -> (
      match lookup ctx span l with
      | Code c -> run c.ctx c.block
      | _ -> refuse span "lowering expected a block here")
  | T.Arg.Value _ -> refuse span "lowering expected a block here"

and stat st ctx (s : T.Stat.t) : Stat.t list =
  let span = s.T.Stat.span in
  match s.T.Stat.node with
  (* A local bound to a spawned call waits for it where it is read. *)
  | T.Stat.Let { local; value = { T.Expr.node = T.Expr.Spawn call; _ } } ->
      if not (Tty.equal local.T.Local.ty call.T.Expr.ty) then
        refuse span "lowering binds a spawned call only to a local of the type it returns yet";
      let stats, future = spawn st ctx span call in
      Hashtbl.replace ctx.env local.T.Local.id future;
      stats
  | T.Stat.Spawn e ->
      fst (spawn st ctx span e)
  | T.Stat.Let { local; value } ->
      let value = moved st ctx span local.T.Local.ty value in
      let id = fresh st in
      Hashtbl.replace ctx.env local.T.Local.id (Slot id);
      [ bind_local st ctx.scope local id value ]
  | T.Stat.Assign { target; value } -> (
      let t = target.T.Expr.ty in
      let address () =
        match storage st ctx span target with
        | Some a -> a
        | None -> refuse span "lowering does not store into this place yet"
      in
      if held st span t then
        (* A host replaced in place keeps, merges or floats its identities
           (memory.md §4.5), and what it replaces returns its blocks. An
           element is a contingent place (§2.2). *)
        let address = address () in
        let value = moved st ctx span t value in
        let contingent =
          match target.T.Expr.node with T.Expr.Subscript _ -> true | _ -> false
        in
        [ Stat.Overwrite { address; value; layout = layout st span t; contingent } ]
      else
        match place st ctx span target with
        | Some place -> [ Stat.Assign { place; value = moved st ctx span t value } ]
        | None ->
            let address = address () in
            [ Stat.Store { address; value = moved st ctx span t value } ])
  | T.Stat.Expr
      {
        T.Expr.node =
          T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None };
        _;
      }
    when String.length spelling > 13 && String.sub spelling 0 13 = "@controlflow$" -> (
      match (spelling, args) with
      | "@controlflow$branch", [ T.Arg.Value cond; body ] ->
          let cond = expr st ctx cond in
          [ Stat.If { cond; body = code st ctx span body } ]
      | "@controlflow$repeat", [ T.Arg.Value count; body ] ->
          let count = expr st ctx count in
          [ Stat.Repeat { count; body = code st ctx span body } ]
      | "@controlflow$exitFromCall", [] -> ctx.exit_call span
      | _ -> refuse span (Printf.sprintf "lowering does not handle `%s` yet" spelling))
  (* A fresh value nothing keeps is held here, so the drain ends it. *)
  | T.Stat.Expr e when held st span e.T.Expr.ty && not (is_place e) ->
      [ bind st ctx.scope span e.T.Expr.ty (fresh st) (expr st ctx e) ]
  | T.Stat.Expr e -> [ Stat.Eval (expr st ctx e) ]
  | T.Stat.Return e -> (
      match ctx.exit with
      | Function ->
          [ Stat.Return (st.returns (escape st span st.ret None (moved st ctx span st.ret e))) ]
      | Leave { label; result; ret } ->
          leave label result (escape st span ret (Some label) (moved st ctx span ret e)))
  | T.Stat.Abort e -> ctx.abort span (moved st ctx span e.T.Expr.ty e)
  | T.Stat.Resolve e -> (
      match ctx.resolve with
      | Some resolve -> resolve e.T.Expr.ty (moved st ctx span e.T.Expr.ty e)
      | None -> refuse span "lowering does not handle a block that yields a value yet")

(* Where an assignment stores: a local, or the place a `mut` subject points
   at, and the members below it. A struct of one member adds no step. A
   place reached through a guest has no local to start from, and is stored
   through its address instead. *)
and place st ctx span (target : T.Expr.t) : Expr.place option =
  match target.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      let t = ty st span l.T.Local.ty in
      match lookup ctx span l with
      | Slot local -> Some { Expr.local; deref = false; ty = t; path = [] }
      | Pointer local -> Some { local; deref = true; ty = t; path = [] }
      (* A spawned call's result is stored through its address, once the
         call has returned. *)
      | Future _ -> None
      | _ -> refuse span "lowering expected a place here")
  | T.Expr.Field { target = inner; _ } when is_guest inner.T.Expr.ty -> None
  | T.Expr.Field { target = inner; slot; _ } ->
      Option.map
        (fun (p : Expr.place) ->
          if collapsed st inner.T.Expr.ty then p
          else { p with path = p.path @ [ member_index st inner.T.Expr.ty slot ] })
        (place st ctx span inner)
  | _ -> None

let func st (v : verb) : Func.t =
  let span = v.body.T.Block.span in
  st.next <- 0;
  let env = Hashtbl.create 16 in
  let params =
    List.map
      (fun (p : T.Local.t) ->
        let id = fresh st in
        if by_address st v p then begin
          Hashtbl.replace env p.T.Local.id (Pointer id);
          (id, Nodes.Ty.Ptr)
        end
        else begin
          Hashtbl.replace env p.T.Local.id (Slot id);
          (id, ty st p.T.Local.span p.T.Local.ty)
        end)
      v.params
  in
  let o = outcome st span v in
  st.returns <- (if plain o then Fun.id else outcome_case o done_);
  st.ret <- v.signature.S.ret;
  let ctx =
    {
      env;
      exit = Function;
      expanding = [];
      abort =
        (fun _ value ->
          let value =
            match v.signature.S.abort with
            | Some t -> escape st span t None value
            | None -> value
          in
          [ Stat.Return (outcome_case o aborted value) ]);
      resolve = None;
      finish = no_block;
      exit_call = (fun _ -> [ Stat.Return (outcome_case o exited unit_) ]);
      scope = { arena = None; settles = [] };
    }
  in
  { Func.symbol = symbol st v; params; ret = returned o; body = block st ctx v.body }

(* ---------------------------------------------------------------------- *)
(* Programs                                                               *)
(* ---------------------------------------------------------------------- *)

let program (p : T.Program.t) =
  let st =
    {
      verbs = Hashtbl.create 64;
      types = Hashtbl.create 64;
      maps = Hashtbl.create 16;
      layouts = Hashtbl.create 16;
      named = [];
      symbols = Hashtbl.create 64;
      pending = Queue.create ();
      next = 0;
      returns = Fun.id;
      ret = Tty.Error;
      spawned = [];
    }
  in
  let add decl instance signature params body =
    let key = key decl instance in
    Hashtbl.replace st.verbs key { decl; key; instance; signature; params; body }
  in
  List.iter
    (fun (pkg : T.Package.t) ->
      List.iter
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Type { name; params; reference; definition } ->
              Hashtbl.replace st.types (pkg.T.Package.name, name) (params, definition, reference)
          | T.Decl.Enum_map { enum; entries; _ } ->
              Hashtbl.replace st.maps d.T.Decl.id (enum, entries)
          | T.Decl.Verb { signature; body = T.Decl.Checked { params; body } } ->
              add d.T.Decl.id [] signature params body
          (* A subscript's body is the place it names (functions.md §2.9). *)
          | T.Decl.Subscript { signature; params; value = Some e } ->
              let return = { T.Stat.node = T.Stat.Return e; span = e.T.Expr.span } in
              let body = { T.Block.stats = [ return ]; span = e.T.Expr.span } in
              add d.T.Decl.id [] signature params body
          | _ -> ())
        pkg.T.Package.decls)
    p.T.Program.packages;
  (* An instance's signature still names its parameters; its body already
     has its arguments. *)
  List.iter
    (fun (i : T.Instance.t) ->
      let sub = Tty.subst (List.map (fun ((p : Tty.param), a) -> (p.id, a)) i.T.Instance.args) in
      let signature = i.T.Instance.signature in
      let signature =
        { signature with S.ret = sub signature.S.ret; abort = Option.map sub signature.S.abort }
      in
      add i.T.Instance.decl i.T.Instance.args signature i.T.Instance.params i.T.Instance.body)
    p.T.Program.instances;
  try
    (* The root package is the first (docs/design/semantics.md §2), and its `main`
       is where the program starts (packages.md §6.2). *)
    let root =
      match p.T.Program.packages with
      | r :: _ -> r
      | [] -> raise (Refused (Message "no packages"))
    in
    let main =
      List.find_map
        (fun (d : T.Decl.t) ->
          match d.T.Decl.node with
          | T.Decl.Verb { signature; _ } when signature.S.name = "main" ->
              verb_of st d.T.Decl.id []
          | _ -> None)
        root.T.Package.decls
    in
    match main with
    | None ->
        raise
          (Refused
             (Message
                (Printf.sprintf "the root package `%s` declares no `main` to start from"
                   root.T.Package.name)))
    | Some main ->
        (* The runtime calls `main` and reads no outcome from it. *)
        let span = main.body.T.Block.span in
        if not (plain (outcome st span main)) then
          refuse span "`main` has no caller to abort to or exit";
        let entry = symbol st main in
        (* In the order calls first reach them, `main` first. *)
        let rec drain acc =
          match Queue.take_opt st.pending with
          | None -> List.rev acc
          | Some v -> drain (func st v :: acc)
        in
        let funcs = drain [] in
        let funcs = funcs @ List.rev st.spawned in
        let layouts = List.rev_map (fun n -> (n, Hashtbl.find st.layouts n)) st.named in
        Ok { Program.funcs; entry; layouts }
  with Refused problem -> Error problem
