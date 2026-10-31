(* Lowering's intrinsics (docs/design/lowering.md): what the runtime does
   for a program, a list's own operations, `@operators$` operations and
   `@math$` functions. The walk in [Lower] is [w]. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout
open Build

(* An `@operators$` operation (syntax.md §2.7). Its operands run in the order
   written, and are read where they are: an operation keeps none of them. *)
let operation w st ctx span spelling args (t : Tty.t) : Expr.t =
  let t = ty st span t in
  let value = function
    | T.Arg.Value v -> w.borrow st ctx span v
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
        | "add" | "disjoin" | "concat" -> Add
        | "multiply" | "conjoin" -> Mul
        | "divide" -> Div
        | "equal" -> Eq
        | "lessThan" -> Less
        | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: no operation `%s`" spelling)
      in
      primitive_op span op t l r)
  | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling)

(* A math function of `@math$` (math.md §2). Its operands run in the order
   written, and are read where they are, as an operation's are. *)
let math w st ctx span spelling args (t : Tty.t) : Expr.t =
  let name = String.sub spelling 6 (String.length spelling - 6) in
  match Math.of_name name with
  | Some fn ->
      let value = function
        | T.Arg.Value v -> w.borrow st ctx span v
        | T.Arg.Block _ -> Diagnostic.bug ~span "lowering: a block passed to a math function"
      in
      { Expr.node = Expr.Math { fn; args = List.map value args }; ty = ty st span t }
  | None -> Diagnostic.bug ~span (Printf.sprintf "lowering: no math function `%s`" spelling)

(* The intrinsics [call] lowers. *)
let runs spelling =
  List.mem spelling
    [
      "@runtime$print";
      "@runtime$setThreads";
      "@runtime$setThreadsAuto";
      "@runtime$arguments";
      "@primitives$parseI64";
      "@primitives$parseF64";
      "@primitives$push";
      "@primitives$size";
      "@primitives$remove";
      "@primitives$swapRemove";
    ]

(* A call to what the runtime does for the program, or to a list's own
   operation. *)
let call w st ctx span (e : T.Expr.t) : Expr.t =
  match e.T.Expr.node with
  | T.Expr.Call { callee = { owner = S.Intrinsic "@runtime$print"; _ }; args; handler = None }
    -> (
      (* The program has one console (effects.md §6.6), so the subject names
         nothing the runtime needs. The text is a borrowed value, which the
         runtime reads where it is (L6). *)
      match args with
      | [ T.Arg.Value _console; T.Arg.Value text ] ->
          {
            Expr.node = Expr.Runtime { fn = Runtime.Print; args = [ w.borrow st ctx span text ] };
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
          let count = w.borrow st ctx span count in
          let label = fresh st in
          let id = fresh st in
          let set = Expr.Runtime { fn = Runtime.Set_threads; args = [ count ] } in
          let set = { Expr.node = set; ty = Nodes.Ty.I64 } in
          let zero = { Expr.node = Expr.Int 0L; ty = Nodes.Ty.I64 } in
          let local = { Expr.node = Expr.Local id; ty = Nodes.Ty.I64 } in
          let failed = Expr.Binary { op = Expr.Eq; left = local; right = zero } in
          let failed = { Expr.node = failed; ty = Nodes.Ty.I1 } in
          let on_abort =
            match handler with
            | Some h -> Lower_match.handle w st ctx h label None
            | None -> ctx.abort
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
      { Expr.node = Expr.Runtime { fn = Runtime.Arguments; args = [] }; ty = Nodes.Ty.list_handle () }
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
          let text = w.borrow st ctx span text in
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
            match handler with
            | Some h -> Lower_match.handle w st ctx h label (Some result)
            | None -> ctx.abort
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
          let taken = stored_ref ~slot:(ref_slot t) (w.moved st ctx span t value) in
          let v = fresh st in
          let at = fresh st in
          let label = fresh st in
          let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
          let l = layout st span t in
          let room =
            Expr.Runtime
              { fn = Runtime.List_push; args = [ w.lend st ctx span list; int (stride st span t) ] }
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
          let value = w.borrow st ctx span list in
          if value.Expr.ty = Nodes.Ty.Handle32 || value.Expr.ty = Nodes.Ty.Handle16 then
            let count = { Expr.node = Expr.Member { value; index = 1 }; ty = Nodes.Ty.I32 } in
            { Expr.node = Expr.Convert count; ty = Nodes.Ty.I64 }
          else { Expr.node = Expr.Member { value; index = 1 }; ty = Nodes.Ty.I64 }
      | _ -> Diagnostic.bug ~span "lowering: `size` with the wrong arguments")
  | T.Expr.Call
      {
        callee =
          { owner = S.Intrinsic (("@primitives$remove" | "@primitives$swapRemove") as spelling); _ };
        args;
        handler = None;
      } -> (
      (* The list runs before the index, as a subject runs before its
         arguments. A list that is an element is the exception, as for any
         `!` call on one ([located_last]): its own operands run first, then
         the index, and only then is it located, so an index that grows the
         list holding it moves it before the call finds it. The element's
         place is checked against the count as a subscript's is, and the
         element moves out of it; then the list closes over the place. An
         element with no storage has nothing to move, so only the check
         and the closing run. *)
      match args with
      | [ T.Arg.Value list; T.Arg.Value index ] ->
          let element_of = Lower_calls.subscripted list in
          let pins, list =
            if element_of then Lower_calls.pinned w st ctx span list else ([], list)
          in
          let t =
            match element (Tty.strip_mode list.T.Expr.ty) with
            | Some t -> t
            | None -> Diagnostic.bug ~span "lowering: a removal from something not a list"
          in
          let lt = ty st span t in
          let scalars = not (Nodes.Ty.holds_handle lt) in
          let fn =
            if spelling = "@primitives$remove" then Runtime.List_remove { scalars }
            else Runtime.List_swap_remove { scalars }
          in
          let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
          let l = fresh st in
          let i = fresh st in
          let v = fresh st in
          let label = fresh st in
          let s = int (stride st span t) in
          let the_list = local_ptr l in
          let the_index = { Expr.node = Expr.Local i; ty = Nodes.Ty.I64 } in
          let at = ptr (Expr.Runtime { fn = Runtime.List_at; args = [ the_list; the_index; s ] }) in
          let closed = Expr.Runtime { fn; args = [ the_list; the_index; s ] } in
          let the_index_runs = Stat.Let { id = i; value = w.borrow st ctx span index } in
          let the_list_runs = Stat.Let { id = l; value = w.lend st ctx span list } in
          let operands =
            if element_of then pins @ [ the_index_runs; the_list_runs ]
            else [ the_list_runs; the_index_runs ]
          in
          let moved, result =
            if lt = Nodes.Ty.Void then ([ Stat.Eval at ], None)
            else
              let taken = Expr.Take { address = at; layout = layout st span t } in
              ([ Stat.Let { id = v; value = { Expr.node = taken; ty = lt } } ], Some v)
          in
          let body = operands @ moved @ [ Stat.Eval { Expr.node = closed; ty = Nodes.Ty.Void } ] in
          { Expr.node = Expr.Expand { label; body; result }; ty = lt }
      | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" spelling))
  | _ -> Diagnostic.bug ~span "lowering: an expression of a form it has no case for"
