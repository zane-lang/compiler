(* Function values C can call (docs/design/ffi.md F11): after lowering,
   each lambda defined in this object whose type C can call
   ([Nodes.Callback.crosses]) gains its adapter, and each call through a
   function value of such a type its invoker. The glue defines the
   lambdas' C entries and the invokers; codegen takes a lambda's value as
   its C entry's address and calls through the invoker. *)

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
   object, and C names it by its symbol. *)
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
    linkage = Linkage.Exported;
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

(* Each call through a function value of a type C can call in [funcs], by
   its types, once. *)
let calls funcs =
  let found = ref [] in
  let call (e : Expr.t) =
    match e.Expr.node with
    | Expr.Call_value { args; _ } ->
        let sg = (List.map (fun (a : Expr.t) -> a.Expr.ty) args, e.Expr.ty) in
        if Callback.crosses (fst sg) (snd sg) && not (List.mem sg !found) then found := sg :: !found
    | _ -> ()
  in
  List.iter (fun (f : Func.t) -> Traverse.walk_stats call ignore f.Func.body) funcs;
  List.rev !found

(* [funcs] with the adapters of [lambdas], the symbols of the program's
   lambdas, the globals they read, and the callbacks and invokers of the
   object whose symbols start with [package]. *)
let add ~package ~lambdas funcs =
  let lambda (f : Func.t) =
    defined f && List.mem f.Func.symbol lambdas && Callback.crosses (List.map snd f.Func.params) f.Func.ret
  in
  let lifted = List.filter lambda funcs in
  let callbacks =
    List.map (fun (f : Func.t) -> { Callback.symbol = f.Func.symbol; params = List.map snd f.Func.params; ret = f.Func.ret }) lifted
  in
  let invokers =
    List.map (fun (params, ret) -> { Callback.symbol = Callback.invoker package params ret; params; ret }) (calls funcs)
  in
  (funcs @ List.map adapter lifted, (if lifted = [] then [] else [ context ]), callbacks, invokers)
