(* A foreign verb's function (docs/design/ffi.md F10): it takes its
   arguments as any verb's function does, lays each out for C, and calls
   the thunk the glue defines for it, whose symbol is the verb's with
   `.ffi` after it (F8). Every call of the verb calls this function, which
   an optimized build inlines, and the thunk with it once the glue is
   linked in (F13). *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout

(* How a value of the Zane type [t] crosses into C (spec ffi.md §3.3), as
   semantics has already checked it does. *)
let crossing st span (t : Tty.t) : Foreign.crossing =
  let t = Tty.strip_mode t in
  match t with
  | Tty.Intrinsic { namespace = "primitives"; name = "Bool"; args = [] } -> Foreign.Bool
  | Tty.Intrinsic { namespace = "primitives"; name = "Unit"; args = [] } -> Foreign.Unit
  | _ when scalar t -> Foreign.Scalar (ty st span t)
  | _ when is_text t || is_list t -> Foreign.View
  | _ when Option.is_some (array_of t) -> Foreign.Address
  | Tty.Verb _ -> refuse span "lowering does not pass a function value to C yet (docs/design/ffi.md §7)"
  | Tty.Named _ -> Foreign.Value
  | _ -> Diagnostic.bug ~span ("lowering: `" ^ Tty.to_string t ^ "` crosses into C as nothing it lays out")

(* The thunk of the verb whose function is [symbol]. *)
let thunk symbol = symbol ^ ".ffi"

(* The function's body: [params] are its parameters' locals, as [env]
   binds them, and [f] is the C function the verb names. *)
let body st env span (v : verb) (f : T.Foreign.t) : Stat.t list =
  let symbol = Verbs.symbol st v in
  let arg (p : T.Local.t) =
    let t = ty st span p.T.Local.ty in
    let value =
      match Hashtbl.find_opt env p.T.Local.id with
      | Some (Slot id) -> { Expr.node = Expr.Local id; ty = t }
      | Some (Pointer id) -> { Expr.node = Expr.Deref { Expr.node = Expr.Local id; ty = Nodes.Ty.Ptr }; ty = t }
      | _ -> Diagnostic.bug ~span "lowering: a foreign verb's parameter has no slot"
    in
    match (crossing st span p.T.Local.ty, value.Expr.node) with
    (* An array is lent where it is (F10): C reads it through its address. *)
    | Foreign.Address, Expr.Local id -> (Foreign.Address, { Expr.node = Expr.Address id; ty = Nodes.Ty.Ptr })
    | Foreign.Address, Expr.Deref p -> (Foreign.Address, p)
    | c, _ -> (c, value)
  in
  let args = List.map arg v.params in
  let ret = v.signature.S.ret in
  let result = crossing st span ret in
  let call_ty = match result with Foreign.Unit -> Nodes.Ty.Void | _ -> ty st span ret in
  let call =
    { Expr.node = Expr.Foreign_call { thunk = thunk symbol; args = List.map snd args }; ty = call_ty }
  in
  let package = match v.signature.S.home with S.Package p -> p | S.Namespace n -> n in
  st.thunks <-
    {
      Foreign.thunk = thunk symbol;
      package;
      c_function = f.T.Foreign.symbol;
      params = List.map fst args;
      result;
    }
    :: st.thunks;
  match result with
  | Foreign.Unit -> [ Stat.Eval call ]
  (* C's bytes are C's: the string is copied into a block of its own
     before anything else runs (F10), by joining the view C returned, which
     owns nothing, to an empty one. *)
  | Foreign.View ->
      let empty = { Expr.node = Expr.Text ""; ty = Nodes.Ty.Handle } in
      [ Stat.Return (st.returns { Expr.node = Expr.Runtime { fn = Runtime.Text_join; args = [ call; empty ] }; ty = Nodes.Ty.Handle }) ]
  | _ -> [ Stat.Return (st.returns call) ]
