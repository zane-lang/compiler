(* Function values C can call (docs/design/ffi.md F11): after lowering,
   each lambda defined in this object whose type C can call
   (Lower_foreign.c_signature) gains its adapter. The glue defines the
   lambdas' C entries, and codegen puts each entry's offset in the word
   before its lambda's code, which a call into C reads. *)

open Nodes

(* The runtime's context of the running thread, which is null on a thread
   C started (runtime/arena.c). Only its being null is read, so it is
   declared as a word. *)
let context = { Global.symbol = "zane_self"; linkage = Linkage.Imported; ty = Ty.I64; per_thread = true }

(* The adapter of the lambda [f]: it takes the address of a table of the
   addresses of slots holding [f]'s arguments, and the address of a slot
   for its result, calls [f] with the arguments and stores what it gives.
   On a thread without a context, it has the runtime make one for the call
   and give it back after. C's entry calls it, so it is exported from this
   object, and C names it by its symbol; it is shared when [f] is not
   exported, since each object that lifts [f] defines it. *)
let adapter (f : Func.t) : Func.t =
  let ptr node = { Expr.node; ty = Ty.Ptr } in
  let table = Ty.Struct (List.map (fun _ -> Ty.Ptr) f.Func.params) in
  let arg i (_, t) =
    let at = ptr (Expr.Offset { base = ptr (Expr.Local 0); within = table; path = [ i ] }) in
    { Expr.node = Expr.Deref (ptr (Expr.Deref at)); ty = t }
  in
  let call = { Expr.node = Expr.Call { fn = f.Func.symbol; args = List.mapi arg f.Func.params }; ty = f.Func.ret } in
  let self = { Expr.node = Expr.Deref (ptr (Expr.Global context.Global.symbol)); ty = Ty.I64 } in
  let fresh = { Expr.node = Expr.Local 2; ty = Ty.I1 } in
  let runtime fn = Stat.If { cond = fresh; body = [ Stat.Eval { Expr.node = Expr.Runtime { fn; args = [] }; ty = Ty.Void } ] } in
  {
    Func.symbol = Callback.adapter f.Func.symbol;
    linkage = (if f.Func.linkage = Linkage.Exported then Linkage.Exported else Linkage.Shared);
    params = [ (0, Ty.Ptr); (1, Ty.Ptr) ];
    places = [];
    ret = Ty.Void;
    body =
      [
        Stat.Let
          { id = 2; value = { Expr.node = Expr.Binary { op = Expr.Eq; left = self; right = { Expr.node = Expr.Int 0L; ty = Ty.I64 } }; ty = Ty.I1 } };
        runtime Runtime.Callback_attach;
        (if f.Func.ret = Ty.Void then Stat.Eval call else Stat.Store { address = ptr (Expr.Local 1); value = call });
        runtime Runtime.Callback_detach;
      ];
    values = [];
  }

(* Whether [f] is defined in this object, rather than reached in another
   one's. *)
let defined (f : Func.t) = match f.Func.linkage with Linkage.Imported | Linkage.Available -> false | _ -> true

(* [funcs] with the adapters of [callbacks], the lambdas C can call, that
   this object defines, each callback marked by whether it does, with an
   entry named after [package], this object's, when other objects may
   define it too, and the globals the adapters read. *)
let add package (callbacks : Callback.t list) funcs =
  let here = Hashtbl.create 16 in
  List.iter (fun (f : Func.t) -> if defined f then Hashtbl.replace here f.Func.symbol f) funcs;
  let marked (c : Callback.t) =
    match Hashtbl.find_opt here c.Callback.symbol with
    | Some f when f.Func.linkage = Linkage.Exported -> { c with Callback.here = true }
    | Some _ -> { c with Callback.here = true; entry = Callback.shared_entry package c.Callback.symbol }
    | None -> c
  in
  let callbacks = List.map marked callbacks in
  let lifted =
    List.filter_map (fun (c : Callback.t) -> if c.Callback.here then Hashtbl.find_opt here c.Callback.symbol else None) callbacks
  in
  (funcs @ List.map adapter lifted, (if lifted = [] then [] else [ context ]), callbacks)
