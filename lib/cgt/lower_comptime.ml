(* Lowering's `comptime` calls (spec effects.md §5.6, docs/design/comptime.md).
   A marked call names no local of the verb it is in (Tst.Comptime_check),
   so it is lifted out as a lambda of no parameters whose body returns the
   marked expression, handler included, and the call is lowered as a call
   of that lambda. Lowering makes it a function like any lambda (L14);
   Optimize.Comptime then runs the function and writes the value it gives in
   place of the call, in every build. *)

module T = Tst.Nodes
module Tty = Tst.Ty
open State

(* Each local [e] names. *)
let rec named (e : T.Expr.t) =
  (match e.T.Expr.node with T.Expr.Var (T.Name_ref.Local l) -> [ l.T.Local.id ] | _ -> [])
  @ List.concat_map
      (function
        | Tst.Traverse.Same x -> named x
        | Tst.Traverse.Arm b | Tst.Traverse.Handler b | Tst.Traverse.Block b | Tst.Traverse.Lambda b
          ->
            List.concat_map
              (fun s -> List.concat_map named (Tst.Traverse.stat_exprs s))
              b.T.Block.stats)
      (Tst.Traverse.parts e)

(* The lambda [inner] is lifted into, and its body, by which lowering names
   it (Program.name_lambdas). A foreign variable of the verb that [inner]
   names, one of [foreign] by local, is declared again at the top of the
   body, as it was in the verb: its value is the same C global. *)
let lambda ~foreign (inner : T.Expr.t) =
  let span = inner.T.Expr.span in
  let names = named inner in
  let declared =
    List.rev (List.filter_map (fun (id, s) -> if List.mem id names then Some s else None) foreign)
  in
  let body = { T.Block.stats = declared @ [ { T.Stat.node = T.Stat.Return inner; span } ]; span } in
  let ty =
    Tty.Verb { Tty.this_ = None; params = []; ret = inner.T.Expr.ty; abort = None; is_mut = false }
  in
  ({ T.Expr.node = T.Expr.Lambda { T.Lambda.params = []; body }; ty; span }, body)

(* The marked call [inner], at [span]: a call of its lambda. *)
let site w st ctx span (inner : T.Expr.t) =
  match List.assq_opt inner st.marked with
  | None -> Diagnostic.bug ~span "lowering: a `comptime` call it gave no lambda"
  | Some (lambda, _) ->
      w.expr st ctx
        {
          T.Expr.node = T.Expr.Call_value { callee = lambda; args = []; handler = None };
          ty = inner.T.Expr.ty;
          span;
        }
