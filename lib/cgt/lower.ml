(* Lowering: the TST to the CGT (docs/design/lowering.md).

   What is lowered is what `main` reaches. A verb is lowered once, the first
   time a call reaches it, so a program pays only for the verbs it uses and a
   package's other declarations need not lower yet. Anything lowering cannot
   handle yet is refused with a diagnostic at the node, rather than lowered
   wrongly.

   This file is the recursive walk over a verb's body. What it reads is
   beside it: [State], [Type_layout], [Literals], [Verbs], [Outcome] and
   [Build]; [Program] lowers a whole program with it. *)

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

(* ---------------------------------------------------------------------- *)
(* Expressions                                                            *)
(* ---------------------------------------------------------------------- *)

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
      | Literal _ | Code _ -> Diagnostic.bug ~span "lowering: a block or literal parameter read as a value")
  | T.Expr.Bool_lit b -> { Expr.node = Expr.Bool b; ty = Nodes.Ty.I1 }
  | T.Expr.Construct { ctor = { owner = S.Intrinsic spelling; _ }; args; handler = None } ->
      primitive st ctx span spelling args e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Intrinsic spelling; _ }; value } ->
      primitive st ctx span spelling [ T.Arg.Value value ] e.T.Expr.ty
  | T.Expr.Construct { ctor = { owner = S.Declared id; instance; _ }; args; handler }
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } ->
      call st ctx span (verb_of st id instance) args handler e.T.Expr.ty
  | T.Expr.Coerce { ctor = { owner = S.Declared id; instance; _ }; value } ->
      call st ctx span (verb_of st id instance) [ T.Arg.Value value ] None e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; args; handler = None }
    when String.starts_with ~prefix:"@operators$" spelling ->
      operation st ctx span spelling args e.T.Expr.ty
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$print"; _ }; args; handler = None }
    -> (
      (* The program has one console (effects.md §6.6), so the subject names
         nothing the runtime needs. The text is a borrowed value, which the
         runtime reads where it is (L6). *)
      match args with
      | [ T.Arg.Value _console; T.Arg.Value text ] ->
          {
            Expr.node = Expr.Runtime { fn = Runtime.Print; args = [ borrow st ctx span text ] };
            ty = Nodes.Ty.Void;
          }
      | _ -> Diagnostic.bug ~span "lowering: `print` with the wrong arguments")
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
          let set = Expr.Runtime { fn = Runtime.Set_threads; args = [ count ] } in
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
      | _ -> Diagnostic.bug ~span "lowering: `setThreads` with the wrong arguments")
  | T.Expr.Call
      {
        callee = { owner = S.Intrinsic "@runtime$setThreadsAuto"; _ };
        args = [ _ ];
        handler = None;
      } ->
      { Expr.node = Expr.Runtime { fn = Runtime.Set_threads_auto; args = [] }; ty = Nodes.Ty.Void }
  (* A new list of the program's arguments, each a string that owns its
     bytes (effects.md §6.6). The program has one runtime, so the subject
     names nothing the runtime needs. *)
  | T.Expr.Call
      { callee = { owner = S.Intrinsic "@runtime$arguments"; _ }; args = [ _ ]; handler = None } ->
      { Expr.node = Expr.Runtime { fn = Runtime.Arguments; args = [] }; ty = Nodes.Ty.Handle }
  (* A number read from a string's text (types.md §2.10). The runtime writes
     it to [value]'s slot and says whether the text spelled one that fits;
     when it did not, the call aborts with `Unit`. *)
  | T.Expr.Call
      {
        callee =
          {
            owner = S.Intrinsic (("@primitives$parseI64" | "@primitives$parseF64") as spelling);
            _;
          };
        args;
        handler;
      } -> (
      match args with
      | [ T.Arg.Value text ] ->
          let fn, t, zero =
            if spelling = "@primitives$parseI64" then (Runtime.Parse_i64, Nodes.Ty.I64, Expr.Int 0L)
            else (Runtime.Parse_f64, Nodes.Ty.F64, Expr.Float 0.)
          in
          let text = borrow st ctx span text in
          let label = fresh st in
          let value = fresh st in
          let parsed = fresh st in
          let result = fresh st in
          let read = Expr.Runtime { fn; args = [ text; ptr (Expr.Address value) ] } in
          let i64 node = { Expr.node; ty = Nodes.Ty.I64 } in
          let failed =
            Expr.Binary { op = Expr.Eq; left = i64 (Expr.Local parsed); right = i64 (Expr.Int 0L) }
          in
          let on_abort =
            match handler with Some h -> handle st ctx h label (Some result) | None -> ctx.abort
          in
          let body =
            [
              Stat.Let { id = value; value = { Expr.node = zero; ty = t } };
              Stat.Let { id = parsed; value = i64 read };
              Stat.If
                { cond = { Expr.node = failed; ty = Nodes.Ty.I1 }; body = on_abort span unit_ };
              Stat.assign result { Expr.node = Expr.Local value; ty = t };
            ]
          in
          { Expr.node = Expr.Expand { label; body; result = Some result }; ty = t }
      | _ ->
          Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling))
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$push"; _ }; args; handler = None }
    -> (
      (* The value is taken first, then the list makes room for it, which may
         move its elements' bytes, and the value moves into the new last
         element. *)
      match args with
      | [ T.Arg.Value list; T.Arg.Value value ] ->
          let t =
            match element (Tty.strip_mode list.T.Expr.ty) with
            | Some t -> t
            | None -> Diagnostic.bug ~span "lowering: `push` onto something not a list"
          in
          let taken = moved st ctx span t value in
          let v = fresh st in
          let at = fresh st in
          let label = fresh st in
          let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
          let l = layout st span t in
          let room =
            Expr.Runtime
              { fn = Runtime.List_push; args = [ lend st ctx span list; int (stride st span t) ] }
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
      | _ -> Diagnostic.bug ~span "lowering: `push` with the wrong arguments")
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$size"; _ }; args; handler = None }
    -> (
      match args with
      | [ T.Arg.Value list ] ->
          let value = borrow st ctx span list in
          { Expr.node = Expr.Member { value; index = 1 }; ty = Nodes.Ty.I64 }
      | _ -> Diagnostic.bug ~span "lowering: `size` with the wrong arguments")
  | T.Expr.Subscript _ -> (
      (* The element's own storage: for an `&` element, what it holds is the
         reference, so this reads it rather than asking [addr] for the
         reference, which would ask back here. *)
      match storage st ctx span e with
      | Some p -> { Expr.node = Expr.Deref p; ty = ty st span e.T.Expr.ty }
      | None -> Diagnostic.bug ~span "lowering: a subscript with no address")
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
      | S.Intrinsic _ -> Diagnostic.bug ~span "lowering: an operator no package declared"
      | S.Declared id -> (
          match verb_of st id instance with
          | Some ({ params = [ pl; pr ]; _ } as v) when not (expands v) ->
              let for_left, for_right = if swapped then (pr, pl) else (pl, pr) in
              operands
                (fun () -> argument st ctx span v for_left left)
                (fun () -> argument st ctx span v for_right right)
                (fun l r -> invoke st ctx span v [ l; r ] handler)
          | Some v when expands v ->
              refuse span "lowering does not handle an operator that takes a block or a literal yet"
          | _ -> Diagnostic.bug ~span "lowering: an operator with no verb to call"))
  | T.Expr.Flip { impl = { owner = S.Declared id; instance; _ }; value; handler } ->
      call st ctx span (verb_of st id instance) [ T.Arg.Value value ] handler e.T.Expr.ty
  | T.Expr.Field { target; slot; _ } ->
      let t = ty st span e.T.Expr.ty in
      let owner = Tty.strip_mode target.T.Expr.ty in
      let index = member_index st owner slot in
      if boxed st owner (field_type st span owner slot) then
        (* A boxed member's payload is in its block. A fresh value is held
           in this scope first (storage), so its block is returned at the
           drain. *)
        match addr st ctx span e with
        | Some p -> { Expr.node = Expr.Deref p; ty = t }
        | None -> Diagnostic.bug ~span "lowering expected a boxed member to have a place"
      else if Tty.is_ref target.T.Expr.ty then
        (* Read through the reference, at the address of the owner it names
           (memory.md §4.1). *)
        let base = expr st ctx target in
        let within = ty st span owner in
        { Expr.node = Expr.Deref (ptr (Expr.Offset { base; within; path = [ index ] })); ty = t }
      else if collapsed st owner then { (borrow st ctx span target) with ty = t }
      else { Expr.node = Expr.Member { value = borrow st ctx span target; index }; ty = t }
  | T.Expr.Init fields -> record st ctx span e.T.Expr.ty fields
  | T.Expr.Construct_fields { ctor = { owner = S.Declared id; instance; _ }; fields; handler } ->
      construct_fields st ctx span (verb_of st id instance) fields handler e.T.Expr.ty
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
  | T.Expr.Lambda l ->
      { Expr.node = Expr.Function (lambda st span e.T.Expr.ty l); ty = Nodes.Ty.Ptr }
  (* A lambda-variable declared at package scope is its lambda, and any
     other package constant is read where it was made. *)
  | T.Expr.Var (T.Name_ref.Global { decl; _ }) -> (
      match Hashtbl.find_opt st.constants decl with
      | Some { value = { T.Expr.node = T.Expr.Lambda _; _ } as value; _ } -> expr st ctx value
      | Some _ -> { Expr.node = Expr.Deref (constant st decl); ty = ty st span e.T.Expr.ty }
      | None -> Diagnostic.bug ~span "lowering found no package constant here")
  | T.Expr.Call_value { callee; args; handler } -> (
      match Tty.strip_mode callee.T.Expr.ty with
      | Tty.Verb fv -> (
          let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
          let (fn : Expr.t) = value_of st ctx callee in
          match args with
          | T.Arg.Value subject :: rest
            when fv.Tty.is_mut && Option.is_some fv.Tty.this_ && subscripted subject ->
              (* The function value is read first, as it is written. *)
              let id = fresh st in
              let read = { Expr.node = Expr.Local id; ty = fn.Expr.ty } in
              let lets, args = held_last st ctx span v subject rest in
              held_in st
                (Stat.Let { id; value = fn } :: lets)
                (invoke ~fn:read st ctx span v (arguments ~direct:false st ctx span v args) handler)
          | _ -> invoke ~fn st ctx span v (arguments ~direct:false st ctx span v args) handler)
      | _ -> Diagnostic.bug ~span "lowering expected a function value here")
  (* `&` written before a place: a reference to it, minted, or a reference it
     holds copied (memory.md §2.6). *)
  | T.Expr.Ref value -> reference_to st ctx span value
  | T.Expr.Call { callee = { owner = S.Intrinsic spelling; _ }; _ }
    when String.starts_with ~prefix:"@controlflow$" spelling ->
      refuse span (Printf.sprintf "lowering does not handle `%s` used as a value yet" spelling)
  | _ -> Diagnostic.bug ~span "lowering: an expression of a form it has no case for"

(* ---------------------------------------------------------------------- *)
(* Primitives, lambdas and records                                        *)
(* ---------------------------------------------------------------------- *)

(* A storage primitive's constructor: `Unit` has no storage, a list starts
   empty, and the others embed their literal. An array's literal is its
   elements, each a value moved into its place, in the order written. *)
and primitive st ctx span spelling args (t : Tty.t) : Expr.t =
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
      { Expr.node = Expr.Runtime { fn = Runtime.List_new; args = [] }; ty = Nodes.Ty.Handle }
  | "ArrayRef.fill", [ _; T.Arg.Value make ] -> fill st ctx span make t
  | ("Array" | "ArrayRef"), [ T.Arg.Value v ] -> (
      match ((literal_of ctx v).T.Expr.node, array_of (Tty.strip_mode t)) with
      | T.Expr.Array_lit values, Some (e, n) when List.length values = n ->
          let element i v = (i, moved st ctx span e v) in
          { Expr.node = Expr.Record (List.mapi element values); ty = ty st span t }
      (* A spawned call's literal, made into its array where it was spawned
         (specialized). *)
      | T.Expr.Var (T.Name_ref.Local l), Some _ -> (
          let lowered = ty st span t in
          let value =
            match lookup ctx span l with
            | Slot id -> { Expr.node = Expr.Local id; ty = lowered }
            | Pointer id -> deref id lowered
            | _ -> Diagnostic.bug ~span "lowering expected an array literal here"
          in
          if owns st span t then
            { value with Expr.node = Expr.Copy { value; layout = layout st span t } }
          else value)
      | _ -> Diagnostic.bug ~span "lowering expected an array literal of the array's length here")
  (* A scalar formatted as text. The runtime returns a String handle that
     owns the bytes it formats. *)
  | "String", [ T.Arg.Value v ] when scalar v.T.Expr.ty ->
      let value = expr st ctx v in
      let fn =
        match value.Expr.ty with
        | Nodes.Ty.I32 -> Runtime.Text_i32
        | Nodes.Ty.I64 -> Runtime.Text_i64
        | Nodes.Ty.F32 -> Runtime.Text_f32
        | Nodes.Ty.F64 -> Runtime.Text_f64
        | _ -> Diagnostic.bug ~span "lowering: a non-scalar reached String's scalar constructor"
      in
      { Expr.node = Expr.Runtime { fn; args = [ value ] }; ty = Nodes.Ty.Handle }
  (* A scalar from another scalar (types.md §2.7): the plain constructors
     widen, and the named ones wrap, truncate or round. *)
  | _, [ T.Arg.Value v ] when scalar v.T.Expr.ty ->
      { Expr.node = Expr.Convert (expr st ctx v); ty = ty st span t }
  | _, [ T.Arg.Value v ] -> literal ctx span name v
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling)

(* An `@operators$` operation (syntax.md §2.7). Its operands run in the order
   written, and are read where they are: an operation keeps none of them. *)
and operation st ctx span spelling args (t : Tty.t) : Expr.t =
  let t = ty st span t in
  let value = function
    | T.Arg.Value v -> borrow st ctx span v
    | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block passed to an operation"
  in
  let name = String.sub spelling 11 (String.length spelling - 11) in
  match (name, args) with
  | ("negate" | "not"), [ v ] -> { Expr.node = Expr.Flip (value v); ty = t }
  | _, [ l; r ] -> (
      let l = value l in
      let r = value r in
      let op : Sst.Nodes.Operator.node =
        match name with
        | "add" | "or" | "concat" -> Add
        | "multiply" | "and" -> Mul
        | "divide" -> Div
        | "equal" -> Eq
        | "lessThan" -> Less
        | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: no operation `%s`" spelling)
      in
      primitive_op span op t l r)
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling)

(* `ArrayRef.fill(n, make)` (generics.md §8.4): a slot this scope holds,
   each element made by calling `make` with its position, counted from 1, in
   order, and moved into place; then the whole array moves out of the slot,
   which is spent, into wherever the call's value goes. *)
and fill st ctx span (make : T.Expr.t) (t : Tty.t) : Expr.t =
  match (array_of (Tty.strip_mode t), make.T.Expr.ty) with
  | Some (e, n), Tty.Verb fv ->
      let arr = ty st span t in
      let int k = { Expr.node = Expr.Int (Int64.of_int k); ty = Nodes.Ty.I64 } in
      let f = fresh st and slot = fresh st and i = fresh st and made = fresh st in
      let label = fresh st and result = fresh st in
      let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
      let fn = { Expr.node = Expr.Local f; ty = Nodes.Ty.Ptr } in
      let index = { Expr.node = Expr.Local i; ty = Nodes.Ty.I64 } in
      let call = invoke ~fn st ctx span v [ index ] None in
      let at =
        ptr
          (Expr.Runtime
             {
               fn = Runtime.Array_at;
               args = [ ptr (Expr.Address slot); index; int n; int (stride st span e) ];
             })
      in
      let next = { Expr.node = Expr.Binary { op = Expr.Add; left = index; right = int 1 }; ty = Nodes.Ty.I64 } in
      let whole = layout st span t in
      let body =
        [
          Stat.Let { id = f; value = value_of st ctx make };
          Stat.Reserve { id = slot; scope = arena st ctx.scope; ty = arr; layout = whole };
          Stat.Let { id = i; value = int 1 };
          Stat.Repeat
            {
              count = int n;
              body =
                [
                  Stat.Let { id = made; value = call };
                  Stat.Place
                    {
                      address = at;
                      value = { Expr.node = Expr.Local made; ty = call.Expr.ty };
                      layout = layout st span e;
                    };
                  Stat.assign i next;
                ];
            };
          Stat.assign result
            { Expr.node = Expr.Take { address = ptr (Expr.Address slot); layout = whole }; ty = arr };
        ]
      in
      { Expr.node = Expr.Expand { label; body; result = Some result }; ty = arr }
  | _ -> Diagnostic.bug ~span "lowering: `ArrayRef.fill` with the wrong arguments"

(* L14. A lambda captures nothing (functions.md §7.4), so it is lifted out
   as a function of its own, once, and its value is that function's address.
   A call through it ends only the ways its type says, which is why a
   lambda's body may not exit (control-flow.md §4.2). *)
and lambda st span t (l : T.Lambda.t) =
  match (List.assq_opt l.T.Lambda.body st.lambdas, t) with
  | None, _ -> Diagnostic.bug ~span "lowering: a lambda it gave no name"
  | Some s, Tty.Verb fv ->
      let key = "lambda " ^ s in
      if not (Hashtbl.mem st.symbols key) then begin
        Hashtbl.replace st.symbols key s;
        Queue.add (value_verb key fv l.T.Lambda.params l.T.Lambda.body) st.pending
      end;
      s
  | Some _, _ -> Diagnostic.bug ~span "lowering expected a function type here"

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
  | Nodes.Ty.Struct ms, _ when List.length ms = List.length fields ->
      { Expr.node = Expr.Record (members fields); ty = lowered }
  | _, [ f ] when collapsed st t -> { (value f) with ty = lowered }
  | _ -> Diagnostic.bug ~span "lowering expected a value for every member here"

(* ---------------------------------------------------------------------- *)
(* Storage, moves and borrows                                             *)
(* ---------------------------------------------------------------------- *)

(* A value read where its type's own storage is wanted: through a reference,
   the owner it names. *)
and value_of st ctx (e : T.Expr.t) =
  if Tty.is_ref e.T.Expr.ty then
    let t = ty st e.T.Expr.span (Tty.strip_mode e.T.Expr.ty) in
    { Expr.node = Expr.Deref (expr st ctx e); ty = t }
  else read st ctx e

(* A value read out of its place. One reached through an owner is read as a
   snapshot (concurrency.md §4.4). *)
and read st ctx (e : T.Expr.t) =
  let span = e.T.Expr.span in
  if through_owner st e && not (reference st e.T.Expr.ty) then
    match addr st ctx span e with
    | Some p -> { Expr.node = Expr.Snapshot p; ty = ty st span e.T.Expr.ty }
    | None -> expr st ctx e
  else expr st ctx e

(* The address of the value a place holds (L10): through a reference, the
   owner it names (memory.md §4.1); otherwise the place's own storage. *)
and addr st ctx span (e : T.Expr.t) : Expr.t option =
  if Tty.is_ref e.T.Expr.ty then Some (expr st ctx e) else storage st ctx span e

(* The address of a place's own storage: a local's slot, a `mut` subject's
   or borrowed argument's pointer, and a member of what any place holds. *)
and storage st ctx span (e : T.Expr.t) : Expr.t option =
  match e.T.Expr.node with
  | T.Expr.Var (T.Name_ref.Local l) -> (
      match lookup ctx span l with
      | Slot id -> Some (ptr (Expr.Address id))
      | Pointer id -> Some (ptr (Expr.Local id))
      | Future { settle; at = Some p } -> Some (joined st (settle ()) p)
      | _ -> None)
  | T.Expr.Field { target; slot; _ } ->
      let owner = Tty.strip_mode target.T.Expr.ty in
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
  | T.Expr.Var (T.Name_ref.Global { decl; _ }) -> (
      match Hashtbl.find_opt st.constants decl with
      | Some { value = { T.Expr.node = T.Expr.Lambda _; _ }; _ } | None -> None
      | Some _ -> Some (constant st decl))
  (* What the program has, such as `@program$console`, holds nothing a
     program reads (effects.md §6.6), so its place is a variable of the
     program's that holds nothing, whose address a reference to it holds. *)
  | T.Expr.Var (T.Name_ref.Intrinsic name) ->
      let symbol = "zane.value." ^ name in
      if not (List.exists (fun (g : Global.t) -> g.Global.symbol = symbol) st.globals) then
        st.globals <- { Global.symbol; linkage = Linkage.Local; ty = Nodes.Ty.I64 } :: st.globals;
      Some (ptr (Expr.Global symbol))
  | T.Expr.Subscript { target; impl; args } -> Some (subscript st ctx span target impl args)
  | T.Expr.Case_read { target; case; handler } when held st span e.T.Expr.ty ->
      Some (case_place st ctx span target case handler e.T.Expr.ty)
  | _ -> None

(* A reference to a place, minted as the place's address, or an existing
   reference copied (memory.md §2.6, §4.1). The semantic pass let only a
   settled place mint one, and a settled owner never moves, so the address
   holds until the owner's scope drains. *)
and reference_to st ctx span (e : T.Expr.t) =
  if Tty.is_ref e.T.Expr.ty then expr st ctx e
  else
    match addr st ctx span e with
    | Some p -> p
    | None -> Diagnostic.bug ~span "lowering expected a reference source here"

(* A value on its way into storage of type [dst]: a reference there is
   minted or copied, and a reference-type owner read from a place moves,
   which spends the place (lifetimes.md §1.6). *)
and moved st ctx span dst (e : T.Expr.t) =
  if Tty.is_ref dst then reference_to st ctx span e
  else if owned st dst && not (Tty.is_ref e.T.Expr.ty) then
    match e.T.Expr.node with
    | T.Expr.Var _ | T.Expr.Field _ -> (
        match addr st ctx span e with
        | Some address ->
            let l = layout st span dst in
            { Expr.node = Expr.Take { address; layout = l }; ty = ty st span dst }
        (* Semantics moves an owner only out of a roaming symbol or a field
           of one (moves.ml), which is a place. *)
        | None -> Diagnostic.bug ~span "lowering expected an owner to move out of a place")
    | _ -> expr st ctx e
  else if owns st span dst && is_place e then
    let value = value_of st ctx e in
    { Expr.node = Expr.Copy { value; layout = layout st span dst }; ty = value.Expr.ty }
  else read st ctx e

(* Whether an expression reads a value something else owns, rather than
   making a fresh one: a place, a member of any value, which a fresh value
   is borrowed for, an element, or what a case read gives. *)
and is_place (e : T.Expr.t) =
  Tty.is_ref e.T.Expr.ty
  ||
  match e.T.Expr.node with
  | T.Expr.Var _ | T.Expr.Field _ | T.Expr.Subscript _ | T.Expr.Case_read _ -> true
  | _ -> false

(* A value read where it is only looked at, as a value parameter or an
   operand: a place is read where it is, and a fresh owner, or a fresh value
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
   stored here first, which this scope then holds. *)
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

(* ---------------------------------------------------------------------- *)
(* Match, handlers and case reads                                         *)
(* ---------------------------------------------------------------------- *)

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
        let tsty = Tty.strip_mode e.T.Expr.ty in
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
              (* A fresh instance is held here, like any other. *)
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
    | None -> Diagnostic.bug ~span "lowering found no arm for a combination of cases"
    | Some a ->
        let binds =
          List.concat
            (List.map2
               (fun (p : T.Pattern.t) (pointer, _, tsty, _) ->
                 match p.T.Pattern.binder with
                 | None -> []
                 | Some l ->
                     let index = case_index st span tsty p.case in
                     let path = [ index ] in
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
  | None -> Diagnostic.bug ~span "lowering found no enum map here"
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
            | None -> Diagnostic.bug ~span (Printf.sprintf "lowering: the enum map has no entry for `%s`" member))
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
   is held in the handler's arena, which is innermost wherever the handler
   runs. *)
and handle ?resolve ?dropped st ctx (h : T.Handler.t) label result span (value : Expr.t) =
  let scope = { arena = None; settles = []; wants = [] } in
  let bind =
    match (h.T.Handler.binder, dropped) with
    | Some l, _ ->
        let id = fresh st in
        Hashtbl.replace ctx.env l.T.Local.id (Slot id);
        [ bind_local st scope l id value ]
    (* An abort value no binder names, of type [dropped], is still held
       here when it is an owner or owns a block, so the drain ends it. *)
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
  close st scope body

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
    let tsty = Tty.strip_mode target.T.Expr.ty in
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

(* A case read of an owner, or of a value that owns a block, as a place: the
   payload where the variant holds it when the case is live, or else a slot
   reserved in this scope before the read, which the handler's `resolve`
   fills. Either way what the read gives has one owner, and a copy of it
   owns blocks of its own. *)
and case_place st ctx span (target : T.Expr.t) case handler ret =
  let t = ty st span ret in
  let tsty = Tty.strip_mode target.T.Expr.ty in
  let within = ty st span tsty in
  let label = fresh st in
  let result = fresh st in
  let base = fresh st in
  let spare = fresh st in
  let l = layout st span ret in
  let live = case_index st span tsty case in
  let whole = { Expr.node = Expr.Deref (local_ptr base); ty = within } in
  let payload =
    let path = [ live ] in
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

(* ---------------------------------------------------------------------- *)
(* Subscripts, calls and arguments                                        *)
(* ---------------------------------------------------------------------- *)

(* The address of an element (functions.md §2.9): a list's or an array's,
   checked against its length, or what a declared subscript's body names,
   with `this` bound to the target's place. *)
and subscript st ctx span (target : T.Expr.t) (impl : T.Verb_ref.t) args =
  let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
  match (impl.owner, args) with
  | S.Intrinsic "@primitives$[]", [ index ] -> (
      match (element (Tty.strip_mode target.T.Expr.ty), array_of (Tty.strip_mode target.T.Expr.ty)) with
      | Some t, _ ->
          ptr
            (Expr.Runtime
               {
                 fn = Runtime.List_at;
                 args =
                   [ lend st ctx span target; borrow st ctx span index; int (stride st span t) ];
               })
      | None, Some (t, n) ->
          let array = lend st ctx span target in
          let index = borrow st ctx span index in
          ptr
            (Expr.Runtime
               { fn = Runtime.Array_at; args = [ array; index; int n; int (stride st span t) ] })
      | None, None -> Diagnostic.bug ~span "lowering: an intrinsic subscript of something not a list or an array")
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
            | None -> Diagnostic.bug ~span "lowering expected a subscript's body to name a place"
          in
          ptr
            (Expr.Expand
               { label; body = binds @ [ Stat.assign result place ]; result = Some result })
      | _ -> Diagnostic.bug ~span "lowering: a declared subscript with no single place to name")
  | _ -> Diagnostic.bug ~span "lowering: a subscript of no owner it knows"

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
  match verb with
  | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
  | Some v -> (
      match passed v args with
      | T.Arg.Value subject :: rest when v.signature.S.is_mut && subscripted subject ->
          located_last st ctx span v subject rest handler ret
      | args -> plain_call st ctx span v args handler ret)

and plain_call st ctx span v args handler ret =
  if expands v then expand st ctx span v args handler ret
  else invoke st ctx span v (arguments st ctx span v args) handler

(* A `!` call whose subject is reached through a subscript (memory.md §2.12):
   the subject's operands run first, then the arguments, each held in a slot
   of its own in written order, and only then is the subject located, so an
   argument that moves the list the subject is an element of moves it before
   the call finds where the element is. *)
and located_last st ctx span v subject rest handler ret =
  let lets, args = held_last st ctx span v subject rest in
  held_in st lets (plain_call st ctx span v args handler ret)

(* The subject's operands pinned and each argument held, as [located_last]
   needs them, for any call form that runs a `!` call on a subscripted
   subject: the statements, and the arguments to pass. *)
and held_last st ctx span v subject rest =
  let pins, subject = pinned st ctx span subject in
  let held =
    match v.params with
    | _ :: params when List.length params = List.length rest ->
        List.map2
          (fun (p : T.Local.t) a ->
            match (a, p.T.Local.ty) with
            | T.Arg.Value e, Tty.Concept _ when expands v -> ([], T.Arg.Value e)
            | T.Arg.Value e, _ ->
                let value = argument st ctx span v p e in
                let id = fresh st in
                let l = { p with T.Local.id = -id } in
                Hashtbl.replace ctx.env l.T.Local.id
                  (if by_address st v p then Pointer id else Slot id);
                let read = { e with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) } in
                ([ Stat.Let { id; value } ], T.Arg.Value read)
            | (T.Arg.Block _ as b), _ -> ([], b))
          params rest
    | _ -> Diagnostic.bug ~span "lowering: a `!` call with the wrong arguments"
  in
  (pins @ List.concat_map fst held, T.Arg.Value subject :: List.map snd held)

(* [lets], then [value], as one expression. *)
and held_in st lets (value : Expr.t) =
  let label = fresh st in
  let body, result =
    if value.Expr.ty = Nodes.Ty.Void then (lets @ [ Stat.Eval value ], None)
    else
      let result = fresh st in
      (lets @ [ Stat.assign result value ], Some result)
  in
  { Expr.node = Expr.Expand { label; body; result }; ty = value.Expr.ty }

(* Whether a place is reached through a subscript, whose element a list
   that grows would move. *)
and subscripted (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Subscript _ -> true
  | T.Expr.Field { target; _ } | T.Expr.Case_read { target; _ } -> subscripted target
  | _ -> false

(* A place's operands, its subscripts' indices, run now into slots of their
   own in written order, and the place rewritten to read them: what runs
   after them no longer changes which element is meant, and where that
   element is is found when the place is located. *)
and pinned st ctx span (e : T.Expr.t) : Stat.t list * T.Expr.t =
  match e.T.Expr.node with
  | T.Expr.Field ({ target; _ } as f) ->
      let pins, target = pinned st ctx span target in
      (pins, { e with T.Expr.node = T.Expr.Field { f with target } })
  | T.Expr.Subscript ({ target; args; _ } as s) ->
      let pins, target = pinned st ctx span target in
      let held =
        List.map
          (fun (a : T.Expr.t) ->
            let id = fresh st in
            let l = { T.Local.id = -id; name = "index"; ty = a.T.Expr.ty; span = a.T.Expr.span } in
            Hashtbl.replace ctx.env l.T.Local.id (Slot id);
            let read = { a with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) } in
            (Stat.Let { id; value = borrow st ctx span a }, read))
          args
      in
      let args = List.map snd held in
      (pins @ List.map fst held, { e with T.Expr.node = T.Expr.Subscript { s with target; args } })
  | _ -> ([], e)

(* types.md §3.3: a field-constructor call is a call to the constructor,
   with each entry's value in its slot and an entry left out given its
   default. The entries run in the order written, then the defaults in
   declaration order. *)
and construct_fields st ctx span verb (fields : T.Field_value.t list) handler ret =
  match verb with
  | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
  | Some v ->
      let defaults = Option.value ~default:[] (Hashtbl.find_opt st.defaults v.key) in
      let slots = List.map (fun (f : T.Field_value.t) -> f.T.Field_value.slot) fields in
      let left_out = List.filter (fun (slot, _) -> not (List.mem slot slots)) defaults in
      let written =
        List.map (fun (f : T.Field_value.t) -> (f.T.Field_value.slot, f.value)) fields
      in
      let given = written @ left_out in
      if List.length given <> List.length v.params then
        Diagnostic.bug ~span "lowering expected every entry of a field constructor to be given or defaulted";
      if List.map fst given = List.init (List.length given) Fun.id then
        call st ctx span verb (List.map (fun (_, e) -> T.Arg.Value e) given) handler ret
      else
        (* Each value is stored as the constructor takes it, in the order it
           runs, and passed in its slot. A constructor expanded where it is
           called (L11) takes its literals as they are, and a stored value
           through a local of its own that names the store. *)
        let stored =
          List.map
            (fun (slot, (e : T.Expr.t)) ->
              let p = List.nth v.params slot in
              match p.T.Local.ty with
              | Tty.Concept _ when expands v -> (slot, [], `Arg (T.Arg.Value e))
              | _ ->
                  let value = argument st ctx span v p e in
                  let id = fresh st in
                  let read = { Expr.node = Expr.Local id; ty = value.Expr.ty } in
                  let named =
                    if expands v then begin
                      let l = { p with T.Local.id = -id } in
                      Hashtbl.replace ctx.env l.T.Local.id
                        (if by_address st v p then Pointer id else Slot id);
                      `Arg (T.Arg.Value { e with T.Expr.node = T.Expr.Var (T.Name_ref.Local l) })
                    end
                    else `Value read
                  in
                  (slot, [ Stat.Let { id; value } ], named))
            given
        in
        let lets = List.concat_map (fun (_, l, _) -> l) stored in
        let in_slot slot = List.find_map (fun (s, _, a) -> if s = slot then Some a else None) stored in
        let slots =
          List.init (List.length given) (fun slot ->
              match in_slot slot with
              | Some a -> a
              | None -> Diagnostic.bug ~span (Printf.sprintf "lowering: argument slot %d is empty" slot))
        in
        let value =
          if expands v then
            let arg = function `Arg a -> a | `Value _ -> Diagnostic.bug ~span "lowering expected an argument" in
            expand st ctx span v (List.map arg slots) handler ret
          else
            let value = function `Value a -> a | `Arg _ -> Diagnostic.bug ~span "lowering expected a value" in
            invoke st ctx span v (List.map value slots) handler
        in
        let label = fresh st in
        if value.Expr.ty = Nodes.Ty.Void then
          let body = lets @ [ Stat.Eval value ] in
          { Expr.node = Expr.Expand { label; body; result = None }; ty = value.Expr.ty }
        else
          let result = fresh st in
          let body = lets @ [ Stat.assign result value ] in
          { Expr.node = Expr.Expand { label; body; result = Some result }; ty = value.Expr.ty }

(* A type written where a value goes, or a number given to an explicit
   number parameter, picks the instance, and an instance takes no parameter
   for it (generics.md §5.3). *)
and passed (v : verb) args =
  let bound =
    if List.length v.signature.S.params = List.length args then
      List.map (fun (p : S.param) -> Option.is_some p.S.binds) v.signature.S.params
    else List.map (fun _ -> false) args
  in
  List.combine bound args
  |> List.filter_map (fun (bound, arg) ->
         match arg with
         | T.Arg.Value { T.Expr.node = T.Expr.Type_arg _; _ } -> None
         | _ -> if bound then None else Some arg)

and arguments ?direct st ctx span v args =
  List.map2
    (fun (p : T.Local.t) arg ->
      match arg with
      | T.Arg.Value a -> argument ?direct st ctx span v p a
      | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block argument to a verb it does not expand")
    v.params args

(* ---------------------------------------------------------------------- *)
(* Spawns                                                                 *)
(* ---------------------------------------------------------------------- *)

(* concurrency.md §3. A spawned call's arguments run here, as any call's do
   (L6), and are stored in a frame in this block's arena. A function of its
   own reads them from there on a thread of the pool, calls the verb, and
   stores how it ended at the frame's start. The block waits for the call
   before it drains (§4.1), and the result comes home to a slot reserved in
   the same arena: at a read of the local it is bound to, or at the drain.

   A call that can abort or exit settles on this thread, once, where it is
   first read, or where the block ends when nothing reads it first
   (docs/spec-divergences.md §10). An abort runs the handler written at the
   spawn (§3.3), or goes where an abort from here goes, and its `resolve`
   gives the result; an exit ends the run of the block the spawn is in. *)
and spawn st ctx span (e : T.Expr.t) =
  match e.T.Expr.node with
  | T.Expr.Spawn inner -> spawn st ctx span inner
  | T.Expr.Call { callee = { owner = S.Declared id; instance; _ }; args; handler } -> (
      match verb_of st id instance with
      | None -> Diagnostic.bug ~span "lowering: a call to a verb it has no body for"
      | Some v when expands v ->
          let v, args = specialized st ctx span v (passed v args) in
          spawn_call st ctx span v None ~writes:v.signature.S.is_mut args handler
      | Some v -> (
          match passed v args with
          | T.Arg.Value subject :: rest when v.signature.S.is_mut && subscripted subject ->
              let lets, args = held_last st ctx span v subject rest in
              let stats, future = spawn_call st ctx span v None ~writes:true args handler in
              (lets @ stats, future)
          | args -> spawn_call st ctx span v None ~writes:v.signature.S.is_mut args handler))
  | T.Expr.Call { callee = { owner = S.Intrinsic _; _ } as callee; args; handler } ->
      let v, args = wrapped st span callee args e.T.Expr.ty in
      spawn_call st ctx span v None ~writes:false args handler
  | T.Expr.Call_value { callee; args; handler } -> (
      match Tty.strip_mode callee.T.Expr.ty with
      | Tty.Verb fv -> (
          let v = value_verb "value" fv (value_params span fv) { T.Block.stats = []; span } in
          let (fn : Expr.t) = value_of st ctx callee in
          match args with
          | T.Arg.Value subject :: rest
            when fv.Tty.is_mut && Option.is_some fv.Tty.this_ && subscripted subject ->
              let id = fresh st in
              let read = { Expr.node = Expr.Local id; ty = fn.Expr.ty } in
              let lets, args = held_last st ctx span v subject rest in
              let stats, future = spawn_call st ctx span v (Some read) ~writes:true args handler in
              ((Stat.Let { id; value = fn } :: lets) @ stats, future)
          | _ -> spawn_call st ctx span v (Some fn) ~writes:fv.Tty.is_mut args handler)
      | _ -> Diagnostic.bug ~span "lowering expected a function value here")
  | _ -> Diagnostic.bug ~span "lowering: a spawn of something not a call"

(* A spawned call has a function to run on another thread, which a verb
   expanded where it is called has not (L11). It gets one of its own, named
   `zane.expanded.N`: the verb with each literal it was given bound where
   its body reads it, one function for each verb and set of literals. A
   block argument cannot be spawned (concurrency.md §3.1), and an array
   literal's elements are values the spawn makes, so its parameter becomes
   one the function takes, of the array's type. *)
and specialized st ctx span (v : verb) args =
  let concept (p : T.Local.t) = match p.T.Local.ty with Tty.Concept c -> Some c | _ -> None in
  let pairs = List.combine v.params args in
  let literals, kept =
    List.partition_map
      (fun ((p : T.Local.t), arg) ->
        match (concept p, arg) with
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
        | None, _ -> Right (p, arg))
      pairs
  in
  let text (_, (e : T.Expr.t)) =
    match e.T.Expr.node with
    | T.Expr.Integer_lit s | T.Expr.Decimal_lit s -> s
    | T.Expr.Text_lit s -> Printf.sprintf "%S" s
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
and wrapped st span (callee : T.Verb_ref.t) args ret =
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
and spawn_call st ctx span v fn ~writes passed handler =
  let o = outcome st span v in
  let whole = returned o in
  let args = arguments st ctx span v passed in
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
        Some (this.T.Local.ty, through_owner st subject)
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
      ret = Nodes.Ty.Void;
      body;
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
    (pre @ [ first; spawned ], Future { settle; at })

(* ---------------------------------------------------------------------- *)
(* Calls and expansion                                                    *)
(* ---------------------------------------------------------------------- *)

(* An argument as the callee takes it (L6): a place it may write, or a
   borrowed owner, is lent by its address, a reference is minted or copied,
   a `^T` argument is moved, and a value is borrowed.

   A fresh owner moved into a `^T` parameter is made in this block's
   region. A callee that drops it leaves its blocks there (memory.md §3.5),
   so they go when this block drains, as they would in the block's own
   scope, rather than piling up in an enclosing one for as long as a loop
   runs. The block keeps an arena for that only when the callee can drop
   the owner, which Regions decides; a call through a function value, and a
   verb expanded here, which has no function of its own, can always. *)
and argument ?(direct = true) st ctx span v (p : T.Local.t) a =
  if by_address st v p then lend st ctx span a
  else if Tty.is_ref p.T.Local.ty then reference_to st ctx span a
  else if roaming st p.T.Local.ty then begin
    (if held st span p.T.Local.ty && not (is_place a) then
       if (not direct) || expands v then ignore (arena st ctx.scope)
       else
         let same (q : T.Local.t) = q.T.Local.id = p.T.Local.id in
         let index = Option.value ~default:(-1) (List.find_index same v.params) in
         ctx.scope.wants <- (symbol st v, index) :: ctx.scope.wants);
    moved st ctx span p.T.Local.ty a
  end
  else borrow st ctx span a

(* L12. A call that can end more than one way is switched on how it ended:
   done gives its result, aborted runs its handler, or the abort of the
   `match` it flows out of, and an exit ends this invocation too. The call
   is to [v]'s function, or through [fn], a function value's address. *)
and invoke ?fn st ctx span v args handler =
  let o = outcome st span v in
  let call =
    match fn with
    | Some fn -> Expr.Call_value { fn; args }
    | None -> Expr.Call { fn = symbol st v; args }
  in
  let value = { Expr.node = call; ty = returned o } in
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
   argument to its code, a literal to itself, the subject or a borrowed
   owner to the caller's place, a `^T` argument to a slot this scope holds
   the moved value in, and any other argument to a new slot holding its
   value (L6). *)
and expand st ctx span v args handler ret =
  if List.mem v.decl ctx.expanding then
    Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` expands into itself" v.signature.S.name);
  if List.length args <> List.length v.params then
    Diagnostic.bug ~span "lowering expected an argument for every parameter";
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
                   | _ -> Diagnostic.bug ~span "lowering expected a block here")
               | _ -> Diagnostic.bug ~span "lowering expected a block here")
           (* An array literal's elements are values the caller's code
              names, so the array is made here, where the call is written,
              and the parameter names its slot. *)
           | T.Arg.Value a, Tty.Concept (Tty.Array_lit (t, n)) when is_array_lit (literal_of ctx a)
             ->
               let arr = array_type t n in
               let value = primitive st ctx span "@primitives$Array" [ arg ] arr in
               let id = fresh st in
               bind p (Slot id);
               if held st span arr then
                 let layout = layout st span arr in
                 [ Stat.Hold { id; scope = arena st ctx.scope; value; layout } ]
               else [ Stat.Let { id; value } ]
           (* A literal stands for itself. A spawned call's array literal is
              a value in a slot by now (specialized), which the parameter
              names too. *)
           | T.Arg.Value a, Tty.Concept _ -> (
               let lit = literal_of ctx a in
               match lit.T.Expr.node with
               | T.Expr.Var (T.Name_ref.Local l) -> (
                   match lookup ctx span l with
                   | (Slot _ | Pointer _) as b ->
                       bind p b;
                       []
                   | _ ->
                       bind p (Literal lit);
                       [])
               | _ ->
                   bind p (Literal lit);
                   [])
           | ( T.Arg.Value { T.Expr.node = T.Expr.Var (T.Name_ref.Local l); T.Expr.ty = at; _ },
               _ )
             when (p.T.Local.name = "this" || (owned st p.T.Local.ty && not (roaming st p.T.Local.ty)))
                  && not (Tty.is_ref at) -> (
               match lookup ctx span l with
               | (Slot _ | Pointer _) as b ->
                   bind p b;
                   []
               | Future { settle; at = Some at } ->
                   let id = fresh st in
                   bind p (Pointer id);
                   settle () @ [ Stat.Let { id; value = at } ]
               | _ -> Diagnostic.bug ~span "lowering expected a place here")
           (* Any other place the body may write, or that it borrows, is lent
              by its address. *)
           | T.Arg.Value a, _
             when p.T.Local.name = "this" || (owned st p.T.Local.ty && not (roaming st p.T.Local.ty)) ->
               let value = lend st ctx span a in
               let id = fresh st in
               bind p (Pointer id);
               [ Stat.Let { id; value } ]
           (* A taken owner is moved into a slot of its own, which this scope
              holds, so it dies with the scope unless the body moves it on. *)
           | T.Arg.Value a, _ when roaming st p.T.Local.ty ->
               let value = moved st ctx span p.T.Local.ty a in
               let id = fresh st in
               bind p (Slot id);
               [ Build.bind st ctx.scope span p.T.Local.ty id value ]
           | T.Arg.Value a, _ ->
               let value =
                 if Tty.is_ref p.T.Local.ty then reference_to st ctx span a else borrow st ctx span a
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

(* ---------------------------------------------------------------------- *)
(* Blocks, statements and places                                          *)
(* ---------------------------------------------------------------------- *)

(* L8: a block that holds a reference-type local has an arena of its own.
   [enter] runs first, in the block's scope: a function's `^T` parameters
   are held there, so the body's drain ends any it did not move on. *)
and block ?(enter = fun _ -> []) st ctx (b : T.Block.t) =
  let scope = { arena = None; settles = []; wants = [] } in
  let entered = enter scope in
  let body = entered @ List.concat_map (stat st { ctx with scope }) b.T.Block.stats in
  (* A spawned call that can abort or exit, and that nothing has read,
     settles where the block ends. *)
  let body = body @ List.concat_map (fun settle -> settle ()) (List.rev scope.settles) in
  close st scope body

(* A block argument's code, where it was written. An exit ends this run of
   it (docs/spec-divergences.md §9). *)
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
      | _ -> Diagnostic.bug ~span "lowering expected a block here")
  | T.Arg.Value _ -> Diagnostic.bug ~span "lowering expected a block here"

and stat st ctx (s : T.Stat.t) : Stat.t list =
  let span = s.T.Stat.span in
  match s.T.Stat.node with
  (* A local bound to a spawned call waits for it where it is read. *)
  (* A local's type may differ from the call's only as storage that holds
     it (Tty.held_as): a function type's `mut`, which changes nothing it
     holds. *)
  | T.Stat.Let { local; value = { T.Expr.node = T.Expr.Spawn call; _ } } ->
      if ty st span local.T.Local.ty <> ty st span call.T.Expr.ty then
        Diagnostic.bug ~span "lowering expected a spawned call bound to a local of the type it returns";
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
  | T.Stat.Assign { target; value } when subscripted target ->
      (* The destination's operands, then the value, and only then is the
         destination located (memory.md §2.12): a value that grows the list
         the destination is an element of has moved it by then. *)
      let pins, target = pinned st ctx span target in
      let t = target.T.Expr.ty in
      let id = fresh st in
      let v = moved st ctx span t value in
      let read = { Expr.node = Expr.Local id; ty = v.Expr.ty } in
      let address =
        match storage st ctx span target with
        | Some a -> a
        | None -> refuse span "lowering does not store into this place yet"
      in
      pins
      @ [ Stat.Let { id; value = v } ]
      @
      if held st span t then [ Stat.Overwrite { address; value = read; layout = layout st span t } ]
      else [ Stat.Store { address; value = read } ]
  | T.Stat.Assign { target; value } -> (
      let t = target.T.Expr.ty in
      let address () =
        match storage st ctx span target with
        | Some a -> a
        | None -> refuse span "lowering does not store into this place yet"
      in
      if held st span t then
        (* An owner, or a value that owns blocks, is replaced in place
           (memory.md §2.2): at the same address, each boxed member's block
           kept, and the rest of what it replaces returning its blocks. *)
        let address = address () in
        let value = moved st ctx span t value in
        [ Stat.Overwrite { address; value; layout = layout st span t } ]
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
      | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling))
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
  (* An abort hands its value to the caller's handler as a return hands it
     to the caller, at the declared abort type: an `&T` abort type takes a
     reference, whatever the expression's own type. *)
  | T.Stat.Abort e -> ctx.abort span (escape st span st.aborts None (moved st ctx span st.aborts e))
  | T.Stat.Resolve e -> (
      match ctx.resolve with
      | Some resolve -> resolve e.T.Expr.ty (moved st ctx span e.T.Expr.ty e)
      | None -> Diagnostic.bug ~span "lowering: a `resolve` outside a handler")

(* Where an assignment stores: a local, or the place a `mut` subject points
   at, and the members below it. A struct of one member adds no step. A
   place reached through a reference has no local to start from, and is
   stored through its address instead. *)
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
      | _ -> Diagnostic.bug ~span "lowering expected a place here")
  | T.Expr.Field { target = inner; _ } when Tty.is_ref inner.T.Expr.ty -> None
  | T.Expr.Field { target = inner; slot; _ } ->
      Option.map
        (fun (p : Expr.place) ->
          if collapsed st inner.T.Expr.ty then p
          else { p with path = p.path @ [ member_index st inner.T.Expr.ty slot ] })
        (place st ctx span inner)
  | _ -> None
