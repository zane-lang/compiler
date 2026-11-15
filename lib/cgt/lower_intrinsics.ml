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
      "@primitives$parseF64At";
      "@primitives$sameRange";
      "@primitives$hashRange";
      "@primitives$push";
      "@primitives$size";
      "@primitives$remove";
      "@primitives$swapRemove";
      "@primitives$byteCount";
      "@primitives$byteAt";
      "@primitives$text";
      "@primitives$appendRange";
      "@primitives$appendOwn";
      "@primitives$copyRange";
      "@primitives$sort";
      "@primitives$sortBy";
      "@primitives$findPair";
      "@primitives$findAny";
      "@primitives$hashBytes";
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
            owner =
              S.Intrinsic
                (("@primitives$parseI64" | "@primitives$parseF64" | "@primitives$parseF64At") as
                 spelling);
            _;
          };
        args;
        handler;
      } -> (
      let range =
        match args with
        | [] -> []
        | _ :: rest -> List.filter_map (function T.Arg.Value a -> Some a | _ -> None) rest
      in
      match (args, range) with
      | T.Arg.Value text :: _, range
        when List.length range = List.length args - 1
             && List.length range = if spelling = "@primitives$parseF64At" then 2 else 0 ->
          let fn, t, zero =
            match spelling with
            | "@primitives$parseI64" -> (Runtime.Parse_i64, Nodes.Ty.I64, Expr.Int 0L)
            | "@primitives$parseF64" -> (Runtime.Parse_f64, Nodes.Ty.F64, Expr.Float 0.)
            | _ -> (Runtime.Parse_f64_at, Nodes.Ty.F64, Expr.Float 0.)
          in
          let text = w.borrow st ctx span text in
          let range = List.map (w.borrow st ctx span) range in
          let label = fresh st in
          let value = fresh st in
          let parsed = fresh st in
          let result = fresh st in
          let read = Expr.Runtime { fn; args = [ text; ptr (Expr.Address value) ] @ range } in
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
  (* EXPERIMENT (LangArena zane-vs-c): a string's bytes. *)
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$byteCount"; _ }; args = [ T.Arg.Value text ]; handler = None }
    ->
      { Expr.node = Expr.Member { value = w.borrow st ctx span text; index = 1 }; ty = Nodes.Ty.I64 }
  | T.Expr.Call
      { callee = { owner = S.Intrinsic "@primitives$byteAt"; _ }; args = [ T.Arg.Value text; T.Arg.Value index ]; handler = None }
    ->
      let s = fresh st and i = fresh st and v = fresh st and label = fresh st in
      let the_text = { Expr.node = Expr.Local s; ty = Nodes.Ty.Handle } in
      let at =
        ptr
          (Expr.Runtime
             {
               fn = Runtime.Array_at;
               args =
                 [
                   { Expr.node = Expr.Member { value = the_text; index = 0 }; ty = Nodes.Ty.Ptr };
                   { Expr.node = Expr.Local i; ty = Nodes.Ty.I64 };
                   { Expr.node = Expr.Member { value = the_text; index = 1 }; ty = Nodes.Ty.I64 };
                   { Expr.node = Expr.Int 1L; ty = Nodes.Ty.I64 };
                 ];
             })
      in
      let body =
        [
          Stat.Let { id = s; value = w.borrow st ctx span text };
          Stat.Let { id = i; value = w.borrow st ctx span index };
          Stat.Let { id = v; value = { Expr.node = Expr.Deref at; ty = Nodes.Ty.I8 } };
        ]
      in
      { Expr.node = Expr.Expand { label; body; result = Some v }; ty = Nodes.Ty.I8 }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$text"; _ }; args = [ T.Arg.Value bytes ]; handler = None } ->
      (* The runtime copies the list's storage as the text's bytes, so its
         elements must each be one byte: `U8`, or a struct of one. *)
      let rec byte (t : Nodes.Ty.t) =
        match t with
        | Nodes.Ty.I8 -> true
        | Nodes.Ty.Struct [ t ] | Nodes.Ty.Packed (Nodes.Ty.Struct [ t ]) -> byte t
        | _ -> false
      in
      (match element (Tty.strip_mode bytes.T.Expr.ty) with
      | Some t when byte (ty st span t) -> ()
      | _ -> refuse span "`@primitives$text` makes a string only from a list of bytes");
      { Expr.node = Expr.Runtime { fn = Runtime.Text_bytes; args = [ w.borrow st ctx span bytes ] }; ty = Nodes.Ty.Handle }
  | T.Expr.Call { callee = { owner = S.Intrinsic ("@primitives$appendRange" | "@primitives$appendOwn" | "@primitives$copyRange" as name); _ }; args; handler = None }
    -> (
      (* EXPERIMENT (LangArena zane-vs-goose): the runtime copies the
         range's bytes, so the elements must own no blocks. *)
      let rec plain (t : Nodes.Ty.t) =
        match t with
        | Nodes.Ty.I1 | Nodes.Ty.I8 | Nodes.Ty.I32 | Nodes.Ty.I64 | Nodes.Ty.F32 | Nodes.Ty.F64 -> true
        | Nodes.Ty.Struct ts | Nodes.Ty.Sum ts -> List.for_all plain ts
        | Nodes.Ty.Array (t, _) | Nodes.Ty.Packed t -> plain t
        | _ -> false
      in
      let append ?at list from start count =
        let t =
          match element (Tty.strip_mode list.T.Expr.ty) with
          | Some t when plain (ty st span t) -> t
          | _ -> refuse span (Printf.sprintf "`%s` copies only elements that own no blocks" name)
        in
        (* Each operand runs once, in written order, as for `remove`: a
           list that is an element has its own operands run first and is
           located only after the range's start and count, so one that
           grows the list holding it moves it before the call finds it. *)
        let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
        let place e =
          let id = fresh st in
          if Lower_calls.subscripted e then
            let pins, e = Lower_calls.pinned w st ctx span e in
            (id, pins, [], [ Stat.Let { id; value = w.lend st ctx span e } ])
          else (id, [], [ Stat.Let { id; value = w.lend st ctx span e } ], [])
        in
        let l, l_pins, l_now, l_last = place list in
        let f, f_pins, f_now, f_last =
          match from with Some e -> place e | None -> (l, [], [], [])
        in
        let s = fresh st and c = fresh st and a = fresh st in
        let range =
          (match at with Some at -> [ Stat.Let { id = a; value = w.borrow st ctx span at } ] | None -> [])
          @ [ Stat.Let { id = s; value = w.borrow st ctx span start }; Stat.Let { id = c; value = w.borrow st ctx span count } ]
        in
        let local i = { Expr.node = Expr.Local i; ty = Nodes.Ty.I64 } in
        let call =
          match at with
          | Some _ ->
              Expr.Runtime
                { fn = Runtime.List_copy; args = [ local_ptr l; local a; local_ptr f; local s; local c; int (stride st span t) ] }
          | None ->
              Expr.Runtime { fn = Runtime.List_append; args = [ local_ptr l; local_ptr f; local s; local c; int (stride st span t) ] }
        in
        let body =
          l_pins @ l_now @ f_pins @ f_now @ range @ f_last @ l_last @ [ Stat.Eval { Expr.node = call; ty = Nodes.Ty.Void } ]
        in
        { Expr.node = Expr.Expand { label = fresh st; body; result = None }; ty = Nodes.Ty.Void }
      in
      match args with
      | [ T.Arg.Value list; T.Arg.Value at; T.Arg.Value from; T.Arg.Value start; T.Arg.Value count ]
        when name = "@primitives$copyRange" ->
          append ~at list (Some from) start count
      | [ T.Arg.Value list; T.Arg.Value from; T.Arg.Value start; T.Arg.Value count ] -> append list (Some from) start count
      | [ T.Arg.Value list; T.Arg.Value start; T.Arg.Value count ] -> append list None start count
      | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" name))
  | T.Expr.Call { callee = { owner = S.Intrinsic ("@primitives$sameRange" | "@primitives$hashRange" as name); _ }; args; handler = None }
    -> (
      (* EXPERIMENT (LangArena zane-vs-goose): the runtime reads the
         ranges' bytes, so the elements must own no blocks, and equal
         elements must be equal bytes: no floats, whose zeros differ. *)
      let rec plain (t : Nodes.Ty.t) =
        match t with
        | Nodes.Ty.I1 | Nodes.Ty.I8 | Nodes.Ty.I32 | Nodes.Ty.I64 -> true
        | Nodes.Ty.Struct [ t ] | Nodes.Ty.Packed (Nodes.Ty.Struct [ t ]) -> plain t
        | _ -> false
      in
      let stride_of list =
        match element (Tty.strip_mode list.T.Expr.ty) with
        | Some t when plain (ty st span t) -> stride st span t
        | _ -> refuse span (Printf.sprintf "`%s` reads only lists of integers" name)
      in
      let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Nodes.Ty.I64 } in
      let b = w.borrow st ctx span in
      match args with
      | [ T.Arg.Value list; T.Arg.Value start; T.Arg.Value other; T.Arg.Value other_start; T.Arg.Value count ] ->
          let s = stride_of list in
          {
            Expr.node =
              Expr.Runtime
                {
                  fn = Runtime.List_same;
                  args = [ w.lend st ctx span list; b start; w.lend st ctx span other; b other_start; b count; int s ];
                };
            ty = Nodes.Ty.I64;
          }
      | [ T.Arg.Value list; T.Arg.Value start; T.Arg.Value count ] ->
          let s = stride_of list in
          {
            Expr.node = Expr.Runtime { fn = Runtime.List_hash; args = [ w.lend st ctx span list; b start; b count; int s ] };
            ty = Nodes.Ty.I64;
          }
      | _ -> Diagnostic.bug ~span (Printf.sprintf "lowering: `%s` with the wrong arguments" name))
  | T.Expr.Call
      {
        callee = { owner = S.Intrinsic "@primitives$findPair"; _ };
        args = [ T.Arg.Value text; T.Arg.Value from; T.Arg.Value count; T.Arg.Value first; T.Arg.Value gap; T.Arg.Value second ];
        handler = None;
      } ->
      let b = w.borrow st ctx span in
      {
        Expr.node =
          Expr.Runtime
            {
              fn = Runtime.Text_find_pair;
              args = [ b text; b from; b count; w.lend st ctx span first; b gap; w.lend st ctx span second ];
            };
        ty = Nodes.Ty.I64;
      }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$hashBytes"; _ }; args = [ T.Arg.Value text ]; handler = None } ->
      { Expr.node = Expr.Runtime { fn = Runtime.Text_hash; args = [ w.borrow st ctx span text ] }; ty = Nodes.Ty.I64 }
  | T.Expr.Call
      {
        callee = { owner = S.Intrinsic "@primitives$findAny"; _ };
        args = [ T.Arg.Value text; T.Arg.Value from; T.Arg.Value count; T.Arg.Value set ];
        handler = None;
      } ->
      let b = w.borrow st ctx span in
      {
        Expr.node = Expr.Runtime { fn = Runtime.Text_find_any; args = [ b text; b from; b count; w.lend st ctx span set ] };
        ty = Nodes.Ty.I64;
      }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$sortBy"; _ }; args = [ T.Arg.Value list; T.Arg.Value keys ]; handler = None } ->
      (* EXPERIMENT (LangArena zane-vs-goose): the runtime sorts a list of
         `I32` indices stably by the `I64` keys they name. *)
      let rec width (t : Nodes.Ty.t) =
        match t with
        | Nodes.Ty.I32 -> Some 32
        | Nodes.Ty.I64 -> Some 64
        | Nodes.Ty.Struct [ t ] | Nodes.Ty.Packed (Nodes.Ty.Struct [ t ]) -> width t
        | _ -> None
      in
      let of_list (l : T.Expr.t) = Option.bind (element (Tty.strip_mode l.T.Expr.ty)) (fun t -> width (ty st span t)) in
      if of_list list <> Some 32 || of_list keys <> Some 64 then
        refuse span "`@primitives$sortBy` sorts a list of `I32` by a list of `I64` keys";
      {
        Expr.node = Expr.Runtime { fn = Runtime.List_sort_by; args = [ w.lend st ctx span list; w.lend st ctx span keys ] };
        ty = Nodes.Ty.Void;
      }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$sort"; _ }; args = [ T.Arg.Value list ]; handler = None } ->
      (* EXPERIMENT (LangArena zane-vs-goose): the runtime sorts the
         elements as integers of their width: `I32`, `I64` and `U8`, or a
         struct of one. *)
      let rec kind (t : Nodes.Ty.t) =
        match t with
        | Nodes.Ty.I32 -> Some 0L
        | Nodes.Ty.I64 -> Some 1L
        | Nodes.Ty.I8 -> Some 2L
        | Nodes.Ty.Struct [ t ] | Nodes.Ty.Packed (Nodes.Ty.Struct [ t ]) -> kind t
        | _ -> None
      in
      let k =
        match Option.bind (element (Tty.strip_mode list.T.Expr.ty)) (fun t -> kind (ty st span t)) with
        | Some k -> k
        | None -> refuse span "`@primitives$sort` sorts only a list of integers"
      in
      {
        Expr.node = Expr.Runtime { fn = Runtime.List_sort; args = [ w.lend st ctx span list; { Expr.node = Expr.Int k; ty = Nodes.Ty.I64 } ] };
        ty = Nodes.Ty.Void;
      }
  | T.Expr.Call { callee = { owner = S.Intrinsic "@primitives$size"; _ }; args; handler = None }
    -> (
      match args with
      | [ T.Arg.Value list ] ->
          let value = w.borrow st ctx span list in
          if value.Expr.ty = Nodes.Ty.Handle16 then
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
