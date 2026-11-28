(* Function values C can call (docs/design/ffi.md F11): after lowering,
   each lambda defined in this object whose type C can call
   (Lower_foreign.c_signature) gains its adapter. The glue defines the
   lambdas' C entries, and codegen puts each entry's offset in the word
   before its lambda's code, where a call into C reads it. *)

open Nodes

(* The runtime's context of the running thread, which is null on a thread
   C started (runtime/arena.c). The adapter only checks whether the context
   is null, so it is declared as a word. *)
let context = { Global.symbol = "zane_self"; linkage = Linkage.Imported; ty = Ty.I64; per_thread = true }

(* The adapter of the lambda [f], which C calls as [c]: it takes the
   address of a table of the addresses of slots holding [f]'s arguments,
   and the address of a slot for its result, calls [f] with the arguments
   and stores [f]'s result in that slot, each struct in C's layout
   (Callback.of_c, Callback.to_c). On a thread without a context, the adapter
   has the runtime make a context for the call, and give it back afterwards,
   before the adapter makes any argument: a string or a list that C lent is
   copied into a value of the program's own, an array is read through its
   pointer, and a handle's C object is stamped as a handle
   (docs/design/ffi.md F12); a null C object stops the program, as it does
   for a foreign verb. C's entry calls the adapter, so the adapter is
   exported from this object, and C names it by its symbol; the adapter is
   shared when [f] is not exported, since each object that lifts [f]
   defines the adapter.

   An exported lambda's adapter also passes C-held objects (packages.md
   §8.5, runtime/held.c), each as the pointer to its bytes: a borrowed
   object or a subject as that pointer, which is the address of its place
   (docs/design/lowering.md L6), and an object a `^T` parameter ends as
   the value read through the pointer, whose top-level scope drains once
   the lambda's scope has. A `this T mut` subject first ends the values
   the calls before lent C. A `^T` result is written into a new top-level
   scope, its blocks settled there, and C is given its pointer; a list a
   `this T mut` subject's lambda returns is kept in the subject's scope,
   and C is given its handle, whose first two words are its view. *)
let adapter (c : Callback.t) (f : Func.t) : Func.t =
  let ptr node = { Expr.node; ty = Ty.Ptr } in
  let table = Ty.Struct (List.map (fun _ -> Ty.Ptr) f.Func.params) in
  let slot i = ptr (Expr.Deref (ptr (Expr.Offset { base = ptr (Expr.Local 0); within = table; path = [ i ] }))) in
  let next = ref 3 in
  let fresh () = let id = !next in incr next; id in
  let runtime fn args ty = { Expr.node = Expr.Runtime { fn; args }; ty } in
  let made = ref [] and before = ref [] and after = ref [] and subject = ref None in
  let int n = { Expr.node = Expr.Int (Int64.of_int n); ty = Ty.I64 } in
  let layout_of l = ptr (Expr.Layout l) in
  let scope = fresh () in
  let arg i (_, t) (shape : Callback.shape) =
    match shape with
    (* A copy of the view, held in the call's arena, which ends the copy
       once the lambda has run. *)
    | Callback.View { layout; _ } ->
        let id = fresh () in
        let value = { Expr.node = Expr.Copy { value = { Expr.node = Expr.Deref (slot i); ty = t }; layout }; ty = t } in
        made := !made @ [ Stat.Hold { id; scope; value; layout } ];
        { Expr.node = Expr.Local id; ty = t }
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
           the handle, and a roaming owner as the handle itself. *)
        if t = Ty.Ptr then begin
          let place = fresh () in
          made := !made @ [ Stat.Let { id = place; value = handle } ];
          ptr (Expr.Address place)
        end
        else handle
    | Callback.Held { role; _ } -> (
        let held = fresh () in
        let at = ptr (Expr.Local held) in
        before := !before @ [ Stat.Let { id = held; value = ptr (Expr.Deref (slot i)) } ];
        match role with
        | Callback.Ended ->
            after := !after @ [ Stat.Eval (runtime Runtime.C_held_end [ at ] Ty.Void) ];
            { Expr.node = Expr.Deref at; ty = t }
        | Callback.Written ->
            subject := Some at;
            before := !before @ [ Stat.Eval (runtime Runtime.C_held_renew [ at ] Ty.Void) ];
            at
        | Callback.Borrowed | Callback.Made -> at)
    | Callback.Lent _ -> Diagnostic.bug "lowering: a function value C calls takes a lent list"
    | s when Callback.moved s -> Callback.of_c s { Expr.node = Expr.Deref (slot i); ty = Callback.c s }
    | Callback.Scalar _ | Callback.Truth | Callback.Nothing | Callback.Record _ -> { Expr.node = Expr.Deref (slot i); ty = t }
  in
  let args = List.mapi (fun i (p, s) -> arg i p s) (List.combine f.Func.params c.Callback.takes) in
  let call = { Expr.node = Expr.Call { fn = f.Func.symbol; args }; ty = f.Func.ret } in
  let gives = Callback.moved c.Callback.gives in
  let result = fresh () in
  let self = { Expr.node = Expr.Deref (ptr (Expr.Global context.Global.symbol)); ty = Ty.I64 } in
  let fresh_context = { Expr.node = Expr.Local 2; ty = Ty.I1 } in
  let around fn = Stat.If { cond = fresh_context; body = [ Stat.Eval (runtime fn [] Ty.Void) ] } in
  let into_c value = Stat.Store { address = ptr (Expr.Local 1); value } in
  let returned = { Expr.node = Expr.Local result; ty = f.Func.ret } in
  let finish =
    match c.Callback.gives with
    | Callback.Held { ty; layout; _ } ->
        let held = fresh () in
        let at = ptr (Expr.Local held) in
        let size, align = Ty.size_align ty in
        (if f.Func.ret = Ty.Void then [ Stat.Eval call ] else [ Stat.Let { id = result; value = call } ])
        @ [ Stat.Let { id = held; value = runtime Runtime.C_held_new [ int size; int align ] Ty.Ptr } ]
        @ (if f.Func.ret = Ty.Void then [] else [ Stat.Store { address = at; value = returned } ])
        @ [ Stat.Eval (runtime Runtime.C_held_settle [ at; layout_of layout ] Ty.Void); into_c at ]
    | Callback.Lent { layout } ->
        let at =
          match !subject with
          | Some at -> at
          | None -> Diagnostic.bug "lowering: an exported lambda lends a list from no `this T mut` subject"
        in
        [
          Stat.Let { id = result; value = call };
          Stat.Eval
            (runtime Runtime.C_held_lend
               [ at; ptr (Expr.Address result); int (fst (Ty.size_align f.Func.ret)); layout_of layout ]
               Ty.Void);
          into_c returned;
        ]
    | _ when f.Func.ret = Ty.Void -> [ Stat.Eval call ]
    | _ when gives -> [ Stat.Let { id = result; value = call }; into_c (Callback.to_c c.Callback.gives returned) ]
    | _ -> [ into_c call ]
  in
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
      @ !before
      @ [ Stat.Scope { id = scope; body = !made @ finish } ]
      @ !after
      @ [ around Runtime.Callback_detach ];
    values = [];
  }

(* Whether [f] is defined in this object, rather than reached in another
   object. *)
let defined (f : Func.t) = match f.Func.linkage with Linkage.Imported | Linkage.Available -> false | _ -> true

(* [funcs] with the adapters of those [callbacks] (the lambdas C can call)
   that this object defines; each callback marked by whether this object
   defines it, and given an entry named after [package], this object's
   package, when other objects may define the callback too; and the globals
   the adapters read. *)
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
    List.filter_map
      (fun (c : Callback.t) ->
        if c.Callback.here then Option.map (adapter c) (Hashtbl.find_opt here c.Callback.symbol) else None)
      callbacks
  in
  (funcs @ lifted, (if lifted = [] then [] else [ context ]), callbacks)
