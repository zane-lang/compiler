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

(* The C type a value of the Zane type [t] crosses as in a function value
   C calls (spec ffi.md §3.6, docs/design/ffi.md F11), when it is one: a
   scalar, a `Bool`, or a C-compatible value type (§3.3), one with no
   fields among them, which C declares as an empty struct. A value type
   that holds itself, through the types [seen] it is reached from, is
   none. *)
let rec c_shape ?(seen = []) st span (t : Tty.t) : Callback.shape option =
  let t = Tty.strip_mode t in
  match t with
  | Tty.Intrinsic { namespace = "primitives"; name = "Bool"; args = [] } -> Some Callback.Truth
  | _ when scalar t -> Some (Callback.Scalar (ty st span t))
  | Tty.Named _ when List.mem t seen -> None
  | Tty.Named _ -> (
      let c_shape = c_shape ~seen:(t :: seen) in
      match definition st t with
      | Some (T.Decl.Struct ms, false) ->
          let field (_, m) =
            match (array_of m, c_shape st span m) with
            | Some (e, n), _ when scalar e -> Some (Callback.Scalar (ty st span e), Some n)
            | None, Some ((Callback.Scalar _ | Callback.Record _) as s) -> Some (s, None)
            | _ -> None
          in
          let fields = List.map field ms in
          if List.for_all Option.is_some fields then Some (Callback.Record (List.filter_map Fun.id fields)) else None
      | _ -> None)
  | _ -> None

(* What C passes a function value as a parameter of the Zane type [t]
   (spec ffi.md §3.6): what [c_shape] gives, a string or a list as its
   view, an array as a pointer to its elements, and a data handle as its
   C object's pointer, a roaming owner's taken by the lambda. *)
let c_param st span (t : Tty.t) : Callback.shape option =
  let handle t = match definition st t with Some (T.Decl.Handle _, _) -> true | _ -> false in
  match t with
  | Tty.Roaming inner when handle inner -> Some (Callback.Object { owned = true })
  | Tty.Roaming _ | Tty.Reference _ -> None
  | _ -> (
      match c_shape st span t with
      | Some s -> Some s
      | None when (is_text t || is_list t) && not (is_list_ref t) ->
          let stride = match element t with Some e -> stride st span e | None -> 1 in
          Some (Callback.View { layout = layout st span t; text = is_text t; stride })
      | None -> (
          match array_of t with
          | Some (e, n) when scalar e && not (is_array_ref t) -> Some (Callback.Elements (Callback.Scalar (ty st span e), n))
          | _ -> if handle t then Some (Callback.Object { owned = false }) else None))

(* The C signature of the function type [fv], when C can call a value of
   it: no subject, no abort, and C types for its parameters and result, a
   `Unit` result returning nothing. *)
let c_signature st span (fv : Tty.verb) =
  if Option.is_some fv.Tty.this_ || Option.is_some fv.Tty.abort then None
  else
    let takes = List.map (c_param st span) fv.Tty.params in
    let gives =
      match Tty.strip_mode fv.Tty.ret with
      | Tty.Intrinsic { namespace = "primitives"; name = "Unit"; args = [] } -> Some Callback.Nothing
      | r -> c_shape st span r
    in
    match gives with
    | Some gives when List.for_all Option.is_some takes -> Some (List.filter_map Fun.id takes, gives)
    | _ -> None

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
  (* A function value hands C its lambda's C entry (F11), which only a
     lambda of a type [c_signature] reads has. *)
  | Tty.Verb fv when Option.is_some (c_signature st span fv) -> Foreign.Function
  | Tty.Verb _ -> Diagnostic.bug ~span ("lowering: C cannot call `" ^ Tty.to_string t ^ "`, which semantics let cross")
  | Tty.Named _ -> (
      match definition st t with Some (T.Decl.Handle _, _) -> Foreign.Handle | _ -> Foreign.Value)
  | _ -> Diagnostic.bug ~span ("lowering: `" ^ Tty.to_string t ^ "` crosses into C as nothing it lays out")

(* The thunk of the verb whose function is [symbol]. *)
let thunk symbol = symbol ^ ".ffi"

(* A handle C returned: stamped as it is made (docs/design/ffi.md F12),
   and a null pointer, which the runtime stamps 0, aborts the call with
   `Unit` when the verb declares that abort, and otherwise stops the
   program (spec ffi.md §3.5). *)
let made st ctx span (v : verb) (call : Expr.t) =
  let node t node = { Expr.node; ty = t } in
  let pointer = fresh st and stamp = fresh st in
  let pointer_ = node Nodes.Ty.Ptr (Expr.Local pointer) and stamp_ = node Nodes.Ty.I64 (Expr.Local stamp) in
  let made = node Nodes.Ty.I64 (Expr.Runtime { fn = Runtime.Handle_made; args = [ pointer_ ] }) in
  let zero = node Nodes.Ty.I64 (Expr.Int 0L) in
  let null = node Nodes.Ty.I1 (Expr.Binary { op = Expr.Eq; left = stamp_; right = zero }) in
  let refused =
    match v.signature.S.abort with
    | Some _ -> ctx.abort span (node Nodes.Ty.Void Expr.Unit)
    | None -> [ Stat.Eval (node Nodes.Ty.Void (Expr.Runtime { fn = Runtime.No_object; args = [] })) ]
  in
  let handle = node (ty st span v.signature.S.ret) (Expr.Record [ (0, pointer_); (1, stamp_) ]) in
  [
    Stat.Let { id = pointer; value = call };
    Stat.Let { id = stamp; value = made };
    Stat.If { cond = null; body = refused };
    Stat.Return (st.returns handle);
  ]

(* The function's body: [params] are its parameters' locals, as [env]
   binds them, and [f] is the C function the verb names. *)
let body st ctx env span (v : verb) (f : T.Foreign.t) : Stat.t list =
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
  (* A string whose C parameter is a `const char *` crosses terminated. *)
  let c_params = match f.T.Foreign.c_function with C_interface.Function { params; _ } -> params | _ -> [] in
  let terminated i (c, value) =
    match (c, List.nth_opt c_params i) with
    | Foreign.View, Some p when C_interface.is_c_string p -> (Foreign.Terminated, value)
    | _ -> (c, value)
  in
  let args = List.mapi terminated (List.map arg v.params) in
  let ret = v.signature.S.ret in
  let result = crossing st span ret in
  let call_ty =
    match result with Foreign.Unit -> Nodes.Ty.Void | Foreign.Handle -> Nodes.Ty.Ptr | _ -> ty st span ret
  in
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
      capability = f.T.Foreign.access <> T.Foreign.Pure;
    }
    :: st.thunks;
  match result with
  | Foreign.Unit -> [ Stat.Eval call ]
  (* A string C returns is taken before anything else runs (F10): the
     block `zane_bytes_alloc` gave C during the call as it is, and any
     other bytes, C's own, copied into a block of the string's own. *)
  | Foreign.View ->
      let runtime fn args ty = { Expr.node = Expr.Runtime { fn; args }; ty } in
      [
        Stat.Eval (runtime Runtime.Text_expect [] Nodes.Ty.Void);
        Stat.Return (st.returns (runtime Runtime.Text_taken [ call ] Nodes.Ty.Handle));
      ]
  | Foreign.Handle -> made st ctx span v call
  | _ -> [ Stat.Return (st.returns call) ]
