(* How a call can end (docs/design/lowering.md L12), and the sum a function
   that can end more than one way returns. *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout

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
