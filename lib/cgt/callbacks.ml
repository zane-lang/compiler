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

(* The adapter of the lambda [f], which C calls as [c]: it takes the
   address of a table of the addresses of slots holding [f]'s arguments,
   and the address of a slot for its result, calls [f] with the arguments
   and stores what it gives. On a thread without a context, it has the
   runtime make one for the call and give it back after, before it makes
   any argument: a string or a list C lent is copied into a value of the
   program's own, an array read through its pointer, and a handle's C
   object stamped as a handle is made (docs/design/ffi.md F12), a null
   one stopping the program as a foreign verb's does. C's entry calls it,
   so it is exported from this object, and C names it by its symbol; it is
   shared when [f] is not exported, since each object that lifts [f]
   defines it. *)
let adapter (c : Callback.t) (f : Func.t) : Func.t =
  let ptr node = { Expr.node; ty = Ty.Ptr } in
  let table = Ty.Struct (List.map (fun _ -> Ty.Ptr) f.Func.params) in
  let slot i = ptr (Expr.Deref (ptr (Expr.Offset { base = ptr (Expr.Local 0); within = table; path = [ i ] }))) in
  let next = ref 3 in
  let fresh () = let id = !next in incr next; id in
  let runtime fn args ty = { Expr.node = Expr.Runtime { fn; args }; ty } in
  let made = ref [] in
  let arg i (_, t) (shape : Callback.shape) =
    match shape with
    | Callback.View { layout; _ } -> { Expr.node = Expr.Copy { value = { Expr.node = Expr.Deref (slot i); ty = t }; layout }; ty = t }
    | Callback.Elements _ -> { Expr.node = Expr.Deref (ptr (Expr.Deref (slot i))); ty = t }
    | Callback.Object _ ->
        let pointer = fresh () and stamp = fresh () in
        let pointer_ = ptr (Expr.Local pointer) and stamp_ = { Expr.node = Expr.Local stamp; ty = Ty.I64 } in
        let null = { Expr.node = Expr.Binary { op = Expr.Eq; left = stamp_; right = { Expr.node = Expr.Int 0L; ty = Ty.I64 } }; ty = Ty.I1 } in
        made :=
          !made
          @ [
              Stat.Let { id = pointer; value = ptr (Expr.Deref (slot i)) };
              Stat.Let { id = stamp; value = runtime Runtime.Handle_made [ pointer_ ] Ty.I64 };
              Stat.If { cond = null; body = [ Stat.Eval (runtime Runtime.No_object [] Ty.Void) ] };
            ];
        let handle = { Expr.node = Expr.Record [ (0, pointer_); (1, stamp_) ]; ty = Ty.Struct [ Ty.Ptr; Ty.I64 ] } in
        (* A borrowed handle is passed as the address of a place holding
           it, a roaming owner as the handle itself. *)
        if t = Ty.Ptr then begin
          let place = fresh () in
          made := !made @ [ Stat.Let { id = place; value = handle } ];
          ptr (Expr.Address place)
        end
        else handle
    | Callback.Scalar _ | Callback.Truth | Callback.Nothing | Callback.Record _ -> { Expr.node = Expr.Deref (slot i); ty = t }
  in
  let args = List.mapi (fun i (p, s) -> arg i p s) (List.combine f.Func.params c.Callback.takes) in
  let call = { Expr.node = Expr.Call { fn = f.Func.symbol; args }; ty = f.Func.ret } in
  let self = { Expr.node = Expr.Deref (ptr (Expr.Global context.Global.symbol)); ty = Ty.I64 } in
  let fresh_context = { Expr.node = Expr.Local 2; ty = Ty.I1 } in
  let around fn = Stat.If { cond = fresh_context; body = [ Stat.Eval (runtime fn [] Ty.Void) ] } in
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
        around Runtime.Callback_attach;
      ]
      @ !made
      @ [
          (if f.Func.ret = Ty.Void then Stat.Eval call else Stat.Store { address = ptr (Expr.Local 1); value = call });
          around Runtime.Callback_detach;
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
  let adapters =
    List.filter_map
      (fun (c : Callback.t) -> if c.Callback.here then Option.map (adapter c) (Hashtbl.find_opt here c.Callback.symbol) else None)
      callbacks
  in
  (funcs @ adapters, (if adapters = [] then [] else [ context ]), callbacks)
