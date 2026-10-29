(* Lowering's lambdas (docs/design/lowering.md): each is lifted out as a
   function of its own, which [Program] lowers like any verb. *)

module T = Tst.Nodes
module Tty = Tst.Ty
open State
open Verbs

(* L14. A lambda captures nothing (functions.md §7.4), so it is lifted out
   as a function of its own, once, and its value is that function's address.
   A call through it ends only the ways its type says, which is why a
   lambda's body may not exit (control-flow.md §4.2). *)
let lambda st span t (l : T.Lambda.t) =
  match (List.assq_opt l.T.Lambda.body st.lambdas, t) with
  | None, _ -> Diagnostic.bug ~span "lowering: a lambda it gave no name"
  | Some s, Tty.Verb fv ->
      let key = "lambda " ^ s in
      if not (Hashtbl.mem st.symbols key) then begin
        Hashtbl.replace st.symbols key s;
        Option.iter
          (fun (takes, gives) -> st.callbacks <- { Nodes.Callback.symbol = s; takes; gives; here = false; entry = Nodes.Callback.entry s } :: st.callbacks)
          (Lower_foreign.c_signature st span fv);
        Queue.add (value_verb key fv l.T.Lambda.params l.T.Lambda.body) st.pending
      end;
      s
  | Some _, _ -> Diagnostic.bug ~span "lowering expected a function type here"
