(* Lowering's lambdas (docs/design/lowering.md): each lambda is lifted out as
   a function of its own, which [Program] lowers like any verb. *)

module T = Tst.Nodes
module Tty = Tst.Ty
open State
open Verbs

(* L14. A lambda captures nothing (functions.md §7.4), so it is lifted out
   as a function of its own, once, and its value is that function's address.
   A call through the lambda ends only in the ways its type allows, which is
   why a lambda's body may not exit (control-flow.md §4.2). *)
let lambda ?(export = false) st span t (l : T.Lambda.t) =
  match (List.assq_opt l.T.Lambda.body st.lambdas, t) with
  | None, _ -> Diagnostic.bug ~span "lowering: a lambda it gave no name"
  | Some s, Tty.Verb fv ->
      let key = "lambda " ^ s in
      let entry (takes, gives) =
        st.callbacks <-
          { Nodes.Callback.symbol = s; takes; gives; here = false; entry = Nodes.Callback.entry s }
          :: List.filter (fun (c : Nodes.Callback.t) -> c.Nodes.Callback.symbol <> s) st.callbacks
      in
      if not (Hashtbl.mem st.symbols key) then begin
        Hashtbl.replace st.symbols key s;
        (* A `comptime` call's lambda is called once, at compile time, and
           C never calls it. *)
        if not (Hashtbl.mem st.comptime s) then Option.iter entry (Lower_foreign.c_signature st span fv);
        Queue.add (value_verb key fv l.T.Lambda.params l.T.Lambda.body) st.pending
      end;
      (* An exported lambda's C entry also passes C-held objects
         (packages.md §8.5), which no function value C calls passes. *)
      if export then Option.iter entry (Lower_foreign.export_signature st span fv);
      s
  | Some _, _ -> Diagnostic.bug ~span "lowering expected a function type here"
