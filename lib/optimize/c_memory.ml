(* What the C evaluator computes with and the memory it computes in
   (docs/design/ffi.md F16). C can tell where its bytes are, so memory is
   bytes: a set of allocations, each a byte array with a size, an
   alignment and a record of which bytes have been written. A pointer is
   an allocation and an offset into it, never a number.

   Some values have no bytes the evaluator can write: a pointer, an
   integer derived from one, a sign-only result and a NaN of unknown bits.
   Stored, each of their bytes is a fragment of the value, and a load
   gives the value back only when it reads all of its fragments in order
   as a type that holds it; reading them any other way reads what the
   running process alone knows, and stops the fold. *)

open Value

type kind =
  | Stack
  | Heap
  (* A global the module defines, and whether the optimizer or the linker
     may merge it with an equal one (`unnamed_addr`). *)
  | Global of { name : string; unnamed : bool }
  (* A global another object defines: its address and nothing else. *)
  | Extern of string
  (* A function's address: nothing is read or written there. *)
  | Function of string
  (* A copy of a string, array or list Zane lends C (F18), standing for
     storage whose identity the evaluator does not know. *)
  | View of { empty : bool }

type alloc = {
  id : int;
  size : int;
  align : int;
  kind : kind;
  data : Bytes.t;
  (* 1 where a byte has been written. *)
  written : Bytes.t;
  frags : (int, frag) Hashtbl.t;
  readonly : bool;
  mutable freed : bool;
}

(* A byte of a value with no bytes: the [index]th of [whole]. *)
and frag = { whole : value; index : int }

and value =
  (* An integer of [bits] bits, held in its low bits, the rest zero. *)
  | Int of int * int64
  | Fl of fl
  | Ptr of ptr
  | Null
  (* A pointer made from a nonzero integer, which points at nothing. *)
  | Wild of int64
  (* An integer of [bits] bits made from a pointer (`ptrtoint`): its
     allocation and offset, and nothing of the running address. *)
  | Addr of int * ptr
  (* What `memcmp` and its kin promise of their result: its sign alone. *)
  | Sign of int * int
  | Poison
  | Vec of value array
  | Agg of value array

(* A float or double by its bits; a NaN C arithmetic made has bits the
   target machine chooses, so [known] is false for it. *)
and fl = { double : bool; bits : int64; known : bool }

and ptr = { alloc : alloc; off : int }

(* [p] moved by [d] bytes. An offset kept in range can be held exactly
   and is never confused with another: one that leaves it, or a move of
   such a size, is one no allocation spans, whose wrapping only the
   running address would decide. *)
let moved p d =
  let limit = 0x1_0000_0000_0000L in
  let out x = x > limit || x < Int64.neg limit in
  if out d then stop "an address moved further than any allocation spans";
  let off = Int64.add (Int64.of_int p.off) d in
  if out off then stop "an address moved further than any allocation spans";
  { p with off = Int64.to_int off }

let mask bits x = if bits >= 64 then x else Int64.logand x (Int64.pred (Int64.shift_left 1L bits))
let int bits x = Int (bits, mask bits x)
let truth b = Int (1, if b then 1L else 0L)

(* The bytes a scalar of [t] takes in memory. *)
let rec store_size (t : C_ir.ty) =
  match t with
  | C_ir.Int bits -> (bits + 7) / 8
  | C_ir.Float -> 4
  | C_ir.Double | C_ir.Ptr -> 8
  (* LLVM packs a vector of elements narrower than a byte, as `<8 x i1>`,
     into bits, which this byte model does not lay out. *)
  | C_ir.Vector (_, C_ir.Int bits) when bits mod 8 <> 0 -> stop "a vector of elements narrower than a byte in memory"
  | C_ir.Vector (n, e) -> n * store_size e
  | C_ir.Struct { size; _ } -> size
  | C_ir.Array { count; stride; _ } -> count * stride
  | C_ir.Void -> 0
  | C_ir.Other -> stop "a C type the evaluator does not model"

(* ---------------------------------------------------------------------- *)
(* Allocations                                                            *)
(* ---------------------------------------------------------------------- *)

let next_id = ref 0

let alloc ?(readonly = false) kind ~size ~align =
  incr next_id;
  {
    id = !next_id;
    size;
    align = max 1 align;
    kind;
    data = Bytes.make size '\000';
    written = Bytes.make size '\000';
    frags = Hashtbl.create 0;
    readonly;
    freed = false;
  }

(* Each byte of [a] from [off] for [n] written as zero. *)
let zero_fill a off n =
  Bytes.fill a.data off n '\000';
  Bytes.fill a.written off n '\001';
  for i = off to off + n - 1 do
    Hashtbl.remove a.frags i
  done

(* Whether an access of [n] bytes at [p] with alignment [align] is defined:
   to a live allocation, inside it, and at an address the allocation's own
   alignment makes a multiple of [align]. *)
let check ?(write = false) p n align =
  let a = p.alloc in
  if a.freed then stop "an access through a freed allocation";
  if p.off < 0 || p.off + n > a.size then stop "an access outside an allocation";
  if write && a.readonly then stop "a store into memory C may not write";
  if align > 1 && (a.align mod align <> 0 || p.off mod align <> 0) then stop "a misaligned access"

(* ---------------------------------------------------------------------- *)
(* Bytes                                                                  *)
(* ---------------------------------------------------------------------- *)

let put_bytes a off n x =
  for i = 0 to n - 1 do
    Bytes.set a.data (off + i) (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical x (8 * i)) 0xffL)));
    Bytes.set a.written (off + i) '\001';
    Hashtbl.remove a.frags (off + i)
  done

let put_frags a off n v =
  for i = 0 to n - 1 do
    Bytes.set a.written (off + i) '\001';
    Hashtbl.replace a.frags (off + i) { whole = v; index = i }
  done

let rec store a off (t : C_ir.ty) v =
  match (t, v) with
  | _, Poison -> stop "poison stored"
  | C_ir.Int bits, Int (_, x) -> put_bytes a off ((bits + 7) / 8) x
  | C_ir.Int bits, (Addr _ | Sign _) -> put_frags a off ((bits + 7) / 8) v
  | (C_ir.Float | C_ir.Double), Fl f when f.known -> put_bytes a off (store_size t) f.bits
  | (C_ir.Float | C_ir.Double), Fl _ -> put_frags a off (store_size t) v
  | C_ir.Ptr, Null -> put_bytes a off 8 0L
  | C_ir.Ptr, Wild x -> put_bytes a off 8 x
  | C_ir.Ptr, Ptr _ -> put_frags a off 8 v
  | C_ir.Vector (_, e), Vec vs ->
      let s = store_size e in
      Array.iteri (fun i x -> store a (off + (i * s)) e x) vs
  | C_ir.Struct { fields; _ }, Agg vs -> Array.iteri (fun i (o, ft) -> store a (off + o) ft vs.(i)) fields
  | C_ir.Array { stride; elem; _ }, Agg vs -> Array.iteri (fun i x -> store a (off + (i * stride)) elem x) vs
  | _ -> stop "a store of a value its type does not hold"

let get_bytes a off n =
  let x = ref 0L in
  for i = n - 1 downto 0 do
    if Bytes.get a.written (off + i) = '\000' then stop "a read of a byte never written";
    x := Int64.logor (Int64.shift_left !x 8) (Int64.of_int (Char.code (Bytes.get a.data (off + i))))
  done;
  !x

(* The value whose fragments the [n] bytes at [off] are, all of it in
   order, if any byte there is a fragment. *)
let whole a off n =
  match Hashtbl.find_opt a.frags off with
  | None ->
      for i = 1 to n - 1 do
        if Hashtbl.mem a.frags (off + i) then stop "a read of part of an address or of an unknown NaN"
      done;
      None
  | Some { whole = w; index = 0 } ->
      for i = 1 to n - 1 do
        match Hashtbl.find_opt a.frags (off + i) with
        | Some f when f.whole == w && f.index = i -> ()
        | _ -> stop "a read of part of an address or of an unknown NaN"
      done;
      (match Hashtbl.find_opt a.frags (off + n) with
      | Some f when f.whole == w && f.index = n -> stop "a read of part of an address or of an unknown NaN"
      | _ -> ());
      Some w
  | Some _ -> stop "a read of part of an address or of an unknown NaN"

let rec load a off (t : C_ir.ty) =
  match t with
  | C_ir.Vector (n, e) ->
      let s = store_size e in
      Vec (Array.init n (fun i -> load a (off + (i * s)) e))
  | C_ir.Struct { fields; _ } -> Agg (Array.map (fun (o, ft) -> load a (off + o) ft) fields)
  | C_ir.Array { count; stride; elem; _ } -> Agg (Array.init count (fun i -> load a (off + (i * stride)) elem))
  | _ -> (
      let n = store_size t in
      match (whole a off n, t) with
      | None, C_ir.Int bits -> int bits (get_bytes a off n)
      | None, C_ir.Float -> Fl { double = false; bits = get_bytes a off 4; known = true }
      | None, C_ir.Double -> Fl { double = true; bits = get_bytes a off 8; known = true }
      | None, C_ir.Ptr -> ( match get_bytes a off 8 with 0L -> Null | x -> Wild x)
      | Some (Ptr p), C_ir.Ptr -> Ptr p
      | Some (Ptr p), C_ir.Int 64 -> Addr (64, p)
      | Some (Addr (_, p)), C_ir.Ptr -> Ptr p
      | Some (Addr (b, _) as w), C_ir.Int b' when b = b' -> w
      | Some (Sign (b, _) as w), C_ir.Int b' when b = b' -> w
      | Some (Fl f as w), (C_ir.Float | C_ir.Double) when f.double = (t = C_ir.Double) -> w
      | Some _, _ -> stop "a read of an address or of an unknown NaN's bits"
      | None, _ -> stop "a load of a type the evaluator does not model")

(* [n] bytes copied from [src] to [dst], with what each byte is: written
   or not, a byte or a fragment. *)
let copy ~dst ~src n =
  check ~write:true dst n 1;
  check src n 1;
  let saved =
    Array.init n (fun i ->
        let o = src.off + i in
        (Bytes.get src.alloc.data o, Bytes.get src.alloc.written o, Hashtbl.find_opt src.alloc.frags o))
  in
  Array.iteri
    (fun i (b, w, f) ->
      let o = dst.off + i in
      Bytes.set dst.alloc.data o b;
      Bytes.set dst.alloc.written o w;
      match f with Some f -> Hashtbl.replace dst.alloc.frags o f | None -> Hashtbl.remove dst.alloc.frags o)
    saved

(* The byte at [p], which must be a written byte and no fragment. *)
let byte p =
  check p 1 1;
  if Hashtbl.mem p.alloc.frags p.off then stop "a read of an address's bytes";
  Int64.to_int (get_bytes p.alloc p.off 1)

let fill p n b =
  check ~write:true p n 1;
  Bytes.fill p.alloc.data p.off n (Char.chr (b land 0xff));
  Bytes.fill p.alloc.written p.off n '\001';
  for i = p.off to p.off + n - 1 do
    Hashtbl.remove p.alloc.frags i
  done

(* ---------------------------------------------------------------------- *)
(* Comparing addresses                                                    *)
(* ---------------------------------------------------------------------- *)

(* Whether two pointers into different allocations are unequal, as C
   gives them, or whether their order is only the running process's: it
   is, where either allocation stands for storage of unknown identity, may
   be merged with an equal one, is pointed one past its end, which C lets
   equal the start of the object laid out next, or is pointed outside it
   by integer arithmetic. *)
let distinct p q =
  let merged a = match a.kind with View _ -> true | Global { unnamed; _ } -> unnamed | _ -> false in
  if merged p.alloc || merged q.alloc then stop "a comparison of addresses whose storage may be shared";
  if (p.off = p.alloc.size && p.alloc.size > 0) || (q.off = q.alloc.size && q.alloc.size > 0) then
    stop "a comparison of an address one past its allocation's end";
  (* An address moved outside its allocation, as integer arithmetic may,
     can equal one in any other. *)
  let outside r = r.off < 0 || r.off > r.alloc.size in
  if outside p || outside q then stop "a comparison of an address outside its allocation";
  true

(* Whether [p] may be null at run time: a pointer into an empty view, whose
   string or list may hold a null block or one it once used. *)
let maybe_null p = match p.alloc.kind with View { empty = true } -> true | _ -> false
