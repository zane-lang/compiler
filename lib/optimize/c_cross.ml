(* Values crossing between stage 5's two evaluators in the target's C
   layout (docs/design/ffi.md F18). A foreign call's arguments, known
   values of [Eval], are each written into an allocation of the C
   evaluator's laid out as codegen lays out the slot (F10), padding bytes
   zero; the thunk runs; and the result slot is read back. A string,
   array or list C reads is a read-only copy of its bytes standing for
   storage whose identity is unknown, so C comparing its address with
   another's stops. A function value C takes is its C entry (F11), and the
   entry's call of the lambda's adapter is the Zane evaluator's. *)

open Cgt.Nodes
open Value
module M = C_memory

type Value.foreign += C of M.value

(* What the program's foreign calls need: its C, each thunk by its symbol,
   and each function value C can call by its lambda's symbol. *)
type program = {
  ir : C_ir.t option;
  thunks : (string, Foreign.t) Hashtbl.t;
  callbacks : (string, Callback.t) Hashtbl.t;
}

let program ir (foreign : Foreign.t list) (callbacks : Callback.t list) =
  let thunks = Hashtbl.create 16 and by_symbol = Hashtbl.create 16 in
  List.iter (fun (f : Foreign.t) -> Hashtbl.replace thunks f.Foreign.thunk f) foreign;
  List.iter (fun (c : Callback.t) -> if c.Callback.here then Hashtbl.replace by_symbol c.Callback.symbol c) callbacks;
  { ir; thunks; callbacks = by_symbol }

(* ---------------------------------------------------------------------- *)
(* Zane values in C memory                                                *)
(* ---------------------------------------------------------------------- *)

let stride t =
  let size, align = Ty.size_align t in
  Ty.round_up size align

(* A view of [size] bytes, which [write] writes into a read-only
   allocation of their own, and its address. *)
let view ~size ~align write =
  let a = M.alloc ~readonly:true (M.View { empty = size = 0 }) ~size ~align in
  write a;
  M.Ptr { M.alloc = a; off = 0 }

let rec write prog c (p : M.ptr) (t : Ty.t) (v : v) =
  let at o = { p with M.off = p.M.off + o } in
  let scalar ty x = M.store p.M.alloc p.M.off ty x in
  match (t, v) with
  | Ty.I1, VBool b -> scalar (C_ir.Int 8) (M.Int (8, if b then 1L else 0L))
  | Ty.I32, VInt i -> scalar (C_ir.Int 32) (M.int 32 i)
  | Ty.I64, VInt i -> scalar (C_ir.Int 64) (M.Int (64, i))
  (* A NaN of the Zane side has whatever bits the running program gave it,
     which no Zane program can tell apart (O5) and C can. *)
  | Ty.F32, VFloat x -> scalar C_ir.Float (C_ops.of_float false x)
  | Ty.F64, VFloat x -> scalar C_ir.Double (C_ops.of_float true x)
  | Ty.Ptr, VNull -> scalar C_ir.Ptr M.Null
  | Ty.Ptr, VForeign (C x) -> scalar C_ir.Ptr x
  | Ty.Ptr, VFunc s -> scalar C_ir.Ptr (entry prog c s)
  (* An array lent where it is (F10): C reads a copy of its elements. *)
  | Ty.Ptr, VPtr q -> (
      match ty_at q.cell.ty q.path with
      | Ty.Array (e, n) ->
          let s = stride e in
          let elems = match load q with VRecord a -> a | _ -> stop "an array that holds no elements" in
          scalar C_ir.Ptr
            (view ~size:(s * n) ~align:(snd (Ty.size_align e)) (fun a ->
                 Array.iteri (fun i x -> write prog c { M.alloc = a; off = i * s } e x) elems))
      | _ -> stop "an address C cannot read")
  | Ty.Handle, VText s ->
      let n = String.length s in
      scalar C_ir.Ptr (view ~size:n ~align:1 (fun a -> String.iteri (fun i ch -> M.put_bytes a i 1 (Int64.of_int (Char.code ch))) s));
      M.store p.M.alloc (p.M.off + 8) (C_ir.Int 64) (M.Int (64, Int64.of_int n))
  | Ty.Handle, VList l ->
      let items = Array.sub l.items 0 l.count in
      let align = Array.fold_left (fun a (x : cell) -> max a (snd (Ty.size_align x.ty))) 1 items in
      scalar C_ir.Ptr
        (view ~size:(l.stride * l.count) ~align (fun a ->
             Array.iteri (fun i (x : cell) -> write prog c { M.alloc = a; off = i * l.stride } x.ty x.value) items));
      M.store p.M.alloc (p.M.off + 8) (C_ir.Int 64) (M.Int (64, Int64.of_int l.count))
  | Ty.Struct ts, VRecord a -> List.iteri (fun i (t, o) -> write prog c (at o) t a.(i)) (List.combine ts (Ty.offsets ts))
  | Ty.Array (e, _), VRecord a ->
      let s = stride e in
      Array.iteri (fun i x -> write prog c (at (i * s)) e x) a
  | _ -> stop "a value C cannot take"

(* The C entry of the function value [symbol] (F11). *)
and entry prog c symbol =
  match (Hashtbl.find_opt prog.callbacks symbol, prog.ir) with
  | Some cb, Some ir -> C_eval.function_address c (C_ir.labelled ir cb.Callback.entry)
  | _ -> stop "a function value with no C entry in this build"

let rec read (p : M.ptr) (t : Ty.t) =
  let at o = { p with M.off = p.M.off + o } in
  let scalar ty = M.load p.M.alloc p.M.off ty in
  let number = function
    | M.Int (_, x) -> x
    | M.Addr _ -> stop C_ops.number
    | M.Sign _ -> stop C_ops.sign_only
    | _ -> stop "C gave a value its type does not hold"
  in
  match t with
  | Ty.I1 -> VBool (number (scalar (C_ir.Int 8)) <> 0L)
  | Ty.I32 -> VInt (C_ops.sext 32 (number (scalar (C_ir.Int 32))))
  | Ty.I64 -> VInt (number (scalar (C_ir.Int 64)))
  | Ty.F32 | Ty.F64 -> (
      match scalar (if t = Ty.F32 then C_ir.Float else C_ir.Double) with
      | M.Fl f -> VFloat (C_ops.to_float f)
      | _ -> stop "C gave a float that is not one")
  | Ty.Ptr -> (
      match scalar C_ir.Ptr with
      | M.Null -> VNull
      | M.Ptr _ as x -> VForeign (C x)
      | _ -> stop "C gave an address that names nothing")
  (* A string C returns, as the `zane_bytes` it wrote: its bytes copied. *)
  | Ty.Handle -> (
      let n = Int64.to_int (number (M.load p.M.alloc (p.M.off + 8) (C_ir.Int 64))) in
      if n = 0 then VText ""
      else
        match scalar C_ir.Ptr with
        | M.Ptr q ->
            M.check q n 1;
            VText (String.init n (fun i -> Char.chr (M.byte { q with M.off = q.M.off + i })))
        | _ -> stop "C gave a string whose bytes are nowhere")
  | Ty.Struct ts -> VRecord (Array.of_list (List.map2 (fun t o -> read (at o) t) ts (Ty.offsets ts)))
  | Ty.Array (e, n) ->
      let s = stride e in
      VRecord (Array.init n (fun i -> read (at (i * s)) e))
  | _ -> stop "a result C cannot give"

(* A slot of [t]'s C layout holding [v], its padding bytes zero, as
   codegen's slots are (F10). *)
let slot prog c t v =
  let size, align = Ty.size_align t in
  let a = M.alloc M.Stack ~size:(max size 1) ~align in
  M.zero_fill a 0 a.M.size;
  let p = { M.alloc = a; off = 0 } in
  write prog c p t v;
  p

(* ---------------------------------------------------------------------- *)
(* Calls                                                                  *)
(* ---------------------------------------------------------------------- *)

let pointer p = M.Ptr p

(* The thunk [f] run on [args], each with its CGT type, giving a value of
   [ret]: each argument in a slot of its own, a table of their addresses,
   and a zeroed slot for the result, which is read back. *)
let call prog c (f : Foreign.t) (args : (v * Ty.t) list) (ret : Ty.t) =
  let ir = match prog.ir with Some ir -> ir | None -> stop "a call into C whose body is not in the build" in
  let slots = List.map (fun (v, t) -> slot prog c t v) args in
  let table = M.alloc M.Stack ~size:(8 * max 1 (List.length slots)) ~align:8 in
  List.iteri (fun i s -> M.store table (8 * i) C_ir.Ptr (pointer s)) slots;
  let result = match ret with Ty.Void -> None | t -> Some (slot prog c t (Value.zero t)) in
  let result_arg = match result with Some r -> pointer r | None -> M.Null in
  ignore (C_eval.call c (C_ir.labelled ir f.Foreign.thunk) [ pointer { M.alloc = table; off = 0 }; result_arg ]);
  match result with Some r -> read r ret | None -> VUnit

(* The CGT type a value of shape [s] has as a function value's argument or
   result (F11): a value type of one field has its field's type. *)
let rec shape_ty (s : Callback.shape) =
  match s with
  | Callback.Scalar t -> t
  | Callback.Truth -> Ty.I1
  | Callback.Nothing -> Ty.Void
  | Callback.Record [ (f, None) ] -> shape_ty f
  | Callback.Record [ (f, Some n) ] -> Ty.Array (shape_ty f, n)
  | Callback.Record fs -> Ty.Struct (List.map (fun (f, n) -> match n with Some n -> Ty.Array (shape_ty f, n) | None -> shape_ty f) fs)

(* A call C makes of a function value's adapter, when [name] is one: its
   arguments read from the slots whose addresses the table holds, the
   lambda run by [zane], and its result written into the result slot. *)
let adapter prog c name args zane =
  match prog.ir with
  | None -> None
  | Some ir -> (
      let symbol = C_ir.unlabelled ir name in
      let suffix = ".adapter" in
      let lambda =
        if String.ends_with ~suffix symbol then
          Hashtbl.find_opt prog.callbacks (String.sub symbol 0 (String.length symbol - String.length suffix))
        else None
      in
      match (lambda, args) with
      | Some cb, [ M.Ptr table; result ] ->
          let arg i s =
            match M.load table.M.alloc (table.M.off + (8 * i)) C_ir.Ptr with
            | M.Ptr q -> read q (shape_ty s)
            | _ -> stop "an argument slot that is nowhere"
          in
          let values = List.mapi arg cb.Callback.takes in
          let r = zane cb.Callback.symbol values in
          (match (cb.Callback.gives, result) with
          | Callback.Nothing, _ -> ()
          | s, M.Ptr q ->
              (* The entry's C reads the result slot as C lays it out,
                 with its padding bytes zeroed. *)
              let t = shape_ty s in
              M.zero_fill q.M.alloc q.M.off (fst (Ty.size_align t));
              write prog c q t r
          | _ -> stop "a result slot that is nowhere");
          Some M.Poison
      | _ -> None)
