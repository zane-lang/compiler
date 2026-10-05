(* Lowering's verbs (docs/design/lowering.md): how a verb is keyed, found,
   named and queued, which verbs are written out where they are called (L11),
   and how a function value is called as a verb (L14). *)

module T = Tst.Nodes
module S = Tst.Signature
module Tty = Tst.Ty
open Nodes
open State
open Type_layout

(* A verb's symbol is its declaration as written (Symbol.verb). Asking for
   one queues the verb to be lowered, once. *)
let symbol st (v : verb) =
  match Hashtbl.find_opt st.symbols v.key with
  | Some s -> s
  | None ->
      let s = Symbol.verb ~stamp:st.stamp v.signature v.instance in
      Hashtbl.replace st.symbols v.key s;
      Queue.add v st.pending;
      s

(* L16: the address of a package constant, which a function of its own
   makes the first time it is called and gives from then on. Asking for one
   queues that function to be lowered, once. *)
let constant st decl =
  let c = Hashtbl.find st.constants decl in
  let key = "constant " ^ string_of_int decl in
  if not (Hashtbl.mem st.symbols key) then begin
    Hashtbl.replace st.symbols key c.symbol;
    Queue.add decl st.made
  end;
  { Expr.node = Expr.Call { fn = c.symbol; args = [] }; ty = Nodes.Ty.Ptr }

(* The next number of a function the compiler makes for itself, of the
   kind [count] counts: one more than those made so far. *)
let numbered count =
  incr count;
  !count

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

(* L6: a `mut` method's subject, a reference-type subject, and a borrowed
   reference-type argument are passed as the address of the caller's place;
   the caller stays a full owner (memory.md §2.9). A `^T` argument is the
   moved value itself. *)
let by_address st (v : verb) (p : T.Local.t) =
  (v.signature.S.is_mut && p.T.Local.name = "this")
  || (owned st p.T.Local.ty && not (Tty.is_roaming p.T.Local.ty))

(* L14: a function value is called as a verb of its type would be, so its
   type gives the verb it is called as: the subject first, named `this`, as a
   lambda's own is. A function value's subject is always lent by its
   address, since a lambda that does not declare `mut` may be held by a
   `mut` function type (functions.md §7.2), and one convention serves both. *)
let value_verb key (fv : Tty.verb) params body =
  let signature =
    {
      S.owner = S.Intrinsic "<lambda>";
      name = "lambda";
      home = S.Namespace "lambda";
      kind = S.Function;
      generics = [];
      params = [];
      ret = fv.Tty.ret;
      abort = fv.Tty.abort;
      is_mut = true;
    }
  in
  { decl = -1; key; instance = []; signature; params; body; literals = [] }

let value_params span (fv : Tty.verb) =
  let local name ty = { T.Local.id = -1; name; ty; span } in
  Option.to_list (Option.map (local "this") fv.Tty.this_)
  @ List.mapi (fun i t -> local (string_of_int i) t) fv.Tty.params
