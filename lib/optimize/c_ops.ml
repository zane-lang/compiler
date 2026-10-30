(* LLVM's arithmetic, comparisons and casts on the C evaluator's values
   (docs/design/ffi.md F16), at the target's widths: integers wrap at
   their width, an `nsw` or `nuw` overflow, an inexact `exact` and an
   overlapping `disjoint` give poison, and division by zero is undefined
   behavior. A float is computed in OCaml's doubles, which round a
   float's sum, difference, product, quotient and square root exactly as
   single precision does; a NaN C arithmetic makes has unknown bits. An
   address-derived integer and a sign-only one fold only where their
   number cannot matter. *)

open Value
open C_memory

let sext bits x = if bits >= 64 then x else Int64.shift_right (Int64.shift_left x (64 - bits)) (64 - bits)
let ult a b = Int64.unsigned_compare a b < 0
let number = "the numeric value of an address, which only the running process has"
let sign_only = "a value C promises only the sign of"

(* ---------------------------------------------------------------------- *)
(* Integers                                                               *)
(* ---------------------------------------------------------------------- *)

(* The high and low words of the unsigned 128-bit product of [a] and
   [b]. *)
let umul128 a b =
  let lo32 x = Int64.logand x 0xffffffffL and hi32 x = Int64.shift_right_logical x 32 in
  let a0 = lo32 a and a1 = hi32 a and b0 = lo32 b and b1 = hi32 b in
  let p00 = Int64.mul a0 b0 and p01 = Int64.mul a0 b1 and p10 = Int64.mul a1 b0 and p11 = Int64.mul a1 b1 in
  let mid = Int64.add (Int64.add (hi32 p00) (lo32 p01)) (lo32 p10) in
  let lo = Int64.logor (lo32 p00) (Int64.shift_left mid 32) in
  let hi = Int64.add (Int64.add p11 (hi32 p01)) (Int64.add (hi32 p10) (hi32 mid)) in
  (hi, lo)

(* Whether the signed product of [x] and [y], of [bits] bits, fits. *)
let mul_fits_signed bits x y =
  let sx = sext bits x and sy = sext bits y in
  let hi, lo = umul128 sx sy in
  let hi = Int64.sub hi (Int64.add (if sx < 0L then sy else 0L) (if sy < 0L then sx else 0L)) in
  hi = Int64.shift_right lo 63 && sext bits lo = lo

let mul_fits_unsigned bits x y =
  let hi, lo = umul128 x y in
  hi = 0L && mask bits lo = lo

let int_binary opcode flags bits x y =
  let has f = flags land f <> 0 in
  let sx = sext bits x and sy = sext bits y in
  let r v = Int (bits, mask bits v) in
  let poison_if c v = if c then Poison else v in
  match opcode with
  | "add" ->
      let s = mask bits (Int64.add x y) in
      let signed_over = sext bits s <> Int64.add sx sy || (bits = 64 && (sx < 0L) = (sy < 0L) && (s < 0L) <> (sx < 0L)) in
      poison_if ((has C_ir.nsw && signed_over) || (has C_ir.nuw && ult s x)) (Int (bits, s))
  | "sub" ->
      let s = mask bits (Int64.sub x y) in
      let signed_over =
        sext bits s <> Int64.sub sx sy || (bits = 64 && (sx < 0L) <> (sy < 0L) && (s < 0L) <> (sx < 0L))
      in
      poison_if ((has C_ir.nsw && signed_over) || (has C_ir.nuw && ult x y)) (Int (bits, s))
  | "mul" ->
      poison_if
        ((has C_ir.nsw && not (mul_fits_signed bits x y)) || (has C_ir.nuw && not (mul_fits_unsigned bits x y)))
        (r (Int64.mul x y))
  | "udiv" | "urem" | "sdiv" | "srem" -> (
      if y = 0L then stop "a division by zero";
      let signed = opcode.[0] = 's' in
      if signed && sy = -1L && sx = sext bits (Int64.shift_left 1L (bits - 1)) then stop "a signed division that overflows";
      match opcode with
      | "udiv" -> poison_if (has C_ir.exact && Int64.unsigned_rem x y <> 0L) (r (Int64.unsigned_div x y))
      | "urem" -> r (Int64.unsigned_rem x y)
      | "sdiv" -> poison_if (has C_ir.exact && Int64.rem sx sy <> 0L) (r (Int64.div sx sy))
      | _ -> r (Int64.rem sx sy))
  | "shl" | "lshr" | "ashr" -> (
      if Int64.unsigned_compare y (Int64.of_int bits) >= 0 then Poison
      else
        let n = Int64.to_int y in
        match opcode with
        | "shl" ->
            let s = mask bits (Int64.shift_left x n) in
            poison_if
              ((has C_ir.nuw && Int64.shift_right_logical s n <> x) || (has C_ir.nsw && Int64.shift_right (sext bits s) n <> sx))
              (Int (bits, s))
        | "lshr" ->
            poison_if (has C_ir.exact && Int64.shift_left (Int64.shift_right_logical x n) n <> x) (r (Int64.shift_right_logical x n))
        | _ -> poison_if (has C_ir.exact && Int64.shift_left (Int64.shift_right sx n) n <> sx) (r (Int64.shift_right sx n)))
  | "and" -> r (Int64.logand x y)
  | "or" -> poison_if (has C_ir.disjoint && Int64.logand x y <> 0L) (r (Int64.logor x y))
  | "xor" -> r (Int64.logxor x y)
  | _ -> stop ("an integer operation the evaluator does not model: " ^ opcode)

(* An integer operation on values that may be addresses: an offset added
   to or taken from one keeps its allocation, and the distance between
   two of one allocation is a plain integer. *)
let rec binary_int opcode flags a b =
  match (opcode, a, b) with
  | ("udiv" | "sdiv" | "urem" | "srem"), _, Poison -> stop "a division by poison"
  | _, Poison, _ | _, _, Poison -> Poison
  | _, Int (bits, x), Int (_, y) -> int_binary opcode flags bits x y
  | "add", Addr (bits, p), Int (_, y) | "add", Int (_, y), Addr (bits, p) -> Addr (bits, moved p (sext bits y))
  | "sub", Addr (bits, p), Int (_, y) -> Addr (bits, moved p (Int64.neg (sext bits y)))
  | "sub", Addr (bits, p), Addr (_, q) when p.alloc == q.alloc -> int bits (Int64.of_int (p.off - q.off))
  | _, (Addr _ | Ptr _ | Null | Wild _), _ | _, _, (Addr _ | Ptr _ | Null | Wild _) -> stop number
  | _, Sign _, _ | _, _, Sign _ -> stop sign_only
  | _, Vec xs, Vec ys -> Vec (Array.map2 (binary_int opcode flags) xs ys)
  | _ -> stop "an integer operation on something not an integer"

(* ---------------------------------------------------------------------- *)
(* Floats                                                                 *)
(* ---------------------------------------------------------------------- *)

let to_float (f : fl) =
  if not f.known then Float.nan
  else if f.double then Int64.float_of_bits f.bits
  else Int32.float_of_bits (Int64.to_int32 f.bits)

(* [x] as a float or double: rounded to single precision for a float, a
   NaN with unknown bits. *)
let of_float double x =
  if Float.is_nan x then Fl { double; bits = 0L; known = false }
  else if double then Fl { double; bits = Int64.bits_of_float x; known = true }
  else Fl { double; bits = Int64.logand (Int64.of_int32 (Int32.bits_of_float x)) 0xffffffffL; known = true }

let fl_of = function Fl f -> f | _ -> stop "a float operation on something not a float"

let rec binary_float opcode a b =
  match (a, b) with
  | Poison, _ | _, Poison -> Poison
  | Vec xs, Vec ys -> Vec (Array.map2 (binary_float opcode) xs ys)
  | _ ->
      let fa = fl_of a and fb = fl_of b in
      let x = to_float fa and y = to_float fb in
      let r =
        match opcode with
        | "fadd" -> x +. y
        | "fsub" -> x -. y
        | "fmul" -> x *. y
        | "fdiv" -> x /. y
        | "frem" -> Float.rem x y
        | _ -> stop ("a float operation the evaluator does not model: " ^ opcode)
      in
      of_float fa.double r

let rec fneg = function
  | Poison -> Poison
  | Vec xs -> Vec (Array.map fneg xs)
  | Fl f when not f.known -> Fl f
  | Fl f -> Fl { f with bits = Int64.logxor f.bits (if f.double then Int64.min_int else 0x80000000L) }
  | _ -> stop "a negation of something not a float"

(* ---------------------------------------------------------------------- *)
(* Comparisons                                                            *)
(* ---------------------------------------------------------------------- *)

let int_compare pred bits x y =
  let c = match pred with 34 | 35 | 36 | 37 -> Int64.unsigned_compare x y | _ -> compare (sext bits x) (sext bits y) in
  match pred with
  | 32 -> c = 0
  | 33 -> c <> 0
  | 34 | 38 -> c > 0
  | 35 | 39 -> c >= 0
  | 36 | 40 -> c < 0
  | 37 | 41 -> c <= 0
  | _ -> stop "an integer comparison the evaluator does not model"

(* A pointer whose storage has ended, by `free` or by its frame or call
   returning, has no value C lets a program use. *)
let dangling = "a use of an address whose storage has ended"

let rec icmp pred a b =
  let equality = pred = 32 || pred = 33 in
  (* Two addresses into one allocation are equal as their offsets are. They
     are ordered as their offsets are only while both lie within it, up to
     one past its end: an allocation does not wrap around, and an offset
     outside it, as -1, is ordered against the others by the running
     address. *)
  let inside p = p.off >= 0 && p.off <= p.alloc.size in
  let offsets p q =
    if (not equality) && not (inside p && inside q) then
      stop "a comparison of addresses outside their allocation, whose order only the running process has";
    truth (int_compare pred 64 (Int64.of_int p.off) (Int64.of_int q.off))
  in
  match (a, b) with
  | Poison, _ | _, Poison -> Poison
  | Ptr p, _ when p.alloc.freed -> stop dangling
  | _, Ptr p when p.alloc.freed -> stop dangling
  | Vec xs, Vec ys -> Vec (Array.map2 (icmp pred) xs ys)
  | Int (bits, x), Int (_, y) -> truth (int_compare pred bits x y)
  | (Ptr p, Ptr q | Addr (_, p), Addr (_, q)) when p.alloc == q.alloc -> offsets p q
  | (Ptr p, Ptr q | Addr (_, p), Addr (_, q)) when equality -> truth (distinct p q = (pred = 33))
  | (Ptr p, Null | Null, Ptr p) when equality ->
      if maybe_null p then stop "a comparison of an empty view's address with null";
      truth (pred = 33)
  | Null, Null -> truth (int_compare pred 64 0L 0L)
  | (Wild x, Null) -> truth (int_compare pred 64 x 0L)
  | (Null, Wild y) -> truth (int_compare pred 64 0L y)
  | Wild x, Wild y -> truth (int_compare pred 64 x y)
  | Sign (_, s), Int (_, 0L) when pred <> 34 && pred <> 35 && pred <> 36 && pred <> 37 ->
      truth (int_compare pred 64 (Int64.of_int s) 0L)
  | Int (_, 0L), Sign (_, s) when pred <> 34 && pred <> 35 && pred <> 36 && pred <> 37 ->
      truth (int_compare pred 64 0L (Int64.of_int s))
  | (Sign _, _ | _, Sign _) -> stop sign_only
  | _ -> stop "a comparison of addresses whose order only the running process has"

let fcmp_holds pred x y =
  let unordered = Float.is_nan x || Float.is_nan y in
  let ordered r = (not unordered) && r and either r = unordered || r in
  match pred with
  | 0 -> false
  | 1 -> ordered (x = y)
  | 2 -> ordered (x > y)
  | 3 -> ordered (x >= y)
  | 4 -> ordered (x < y)
  | 5 -> ordered (x <= y)
  | 6 -> ordered (x <> y)
  | 7 -> not unordered
  | 8 -> unordered
  | 9 -> either (x = y)
  | 10 -> either (x > y)
  | 11 -> either (x >= y)
  | 12 -> either (x < y)
  | 13 -> either (x <= y)
  | 14 -> either (x <> y)
  | _ -> true

let rec fcmp pred a b =
  match (a, b) with
  | Poison, _ | _, Poison -> Poison
  | Vec xs, Vec ys -> Vec (Array.map2 (fcmp pred) xs ys)
  | _ -> truth (fcmp_holds pred (to_float (fl_of a)) (to_float (fl_of b)))

(* ---------------------------------------------------------------------- *)
(* Casts                                                                  *)
(* ---------------------------------------------------------------------- *)

let two63 = 9223372036854775808.

(* [x], of [bits] bits, read as unsigned when [unsigned], rounded to a
   float or double once: its significand rounded to odd at two bits more
   than the result holds (26 for a float, 55 for a double), which then
   rounds as a direct rounding would. *)
let int_to_float ~unsigned ~double bits x =
  let negative = (not unsigned) && sext bits x < 0L in
  let magnitude = if negative then Int64.neg (sext bits x) else if unsigned then x else sext bits x in
  (* [magnitude] as an unsigned 64-bit number, rounded to a significand of
     [keep] bits by rounding to odd, then to a double. *)
  let rounded keep =
    let rec width v n = if v = 0L then n else width (Int64.shift_right_logical v 1) (n + 1) in
    let w = width magnitude 0 in
    if w <= keep then Int64.to_float magnitude
    else
      let shift = w - keep in
      let kept = Int64.shift_right_logical magnitude shift in
      let sticky = if Int64.shift_left kept shift <> magnitude then 1L else 0L in
      Float.ldexp (Int64.to_float (Int64.logor kept sticky)) shift
  in
  let v = if double then rounded 55 else rounded 26 in
  of_float double (if negative then -.v else v)

let float_to_int ~unsigned bits (f : fl) =
  let x = Float.trunc (to_float f) in
  let lo, hi = if unsigned then (0., Float.ldexp 1. bits) else (-.Float.ldexp 1. (bits - 1), Float.ldexp 1. (bits - 1)) in
  if Float.is_nan x || x < lo || x >= hi then Poison
  else if x >= two63 then Int (bits, Int64.add (Int64.of_float (x -. two63)) Int64.min_int)
  else int bits (Int64.of_float x)

(* [v], of type [from], read as a value of [into] through its bytes. *)
let through_bytes (from : C_ir.ty) (into : C_ir.ty) v =
  let n = store_size from in
  if n <> store_size into then stop "a bitcast between types of different sizes";
  let a = alloc Stack ~size:n ~align:1 in
  store a 0 from v;
  load a 0 into

let rec cast opcode flags (from : C_ir.ty) (into : C_ir.ty) v =
  let has f = flags land f <> 0 in
  let each f = match (v, from, into) with Vec xs, C_ir.Vector (_, ef), C_ir.Vector (_, ei) -> Some (Vec (Array.map (f ef ei) xs)) | _ -> None in
  match (opcode, v) with
  | _, Poison -> Poison
  | ("bitcast" | "addrspacecast"), _ when from = into -> v
  | "bitcast", _ -> through_bytes from into v
  | _, Vec _ -> ( match each (cast opcode flags) with Some r -> r | None -> stop "a vector cast of mismatched types")
  | _ -> scalar_cast opcode has from into v

and scalar_cast opcode has (from : C_ir.ty) (into : C_ir.ty) v =
  let bits_of = function C_ir.Int b -> b | C_ir.Ptr -> 64 | _ -> stop "a cast to or from a type it does not take" in
  let into_double = into = C_ir.Double in
  match (opcode, v) with
  | "trunc", Int (b, x) ->
      let n = bits_of into in
      let r = mask n x in
      if (has C_ir.nuw && r <> x) || (has C_ir.nsw && sext n r <> sext b x) then Poison else Int (n, r)
  | "trunc", Addr (_, p) when bits_of into >= 64 -> Addr (bits_of into, p)
  | "trunc", Addr _ -> stop "an address truncated to fewer bits than it has"
  | "zext", Int (b, x) -> if has C_ir.nneg && sext b x < 0L then Poison else Int (bits_of into, x)
  | "sext", Int (b, x) -> int (bits_of into) (sext b x)
  | ("zext" | "sext"), Addr (_, p) -> Addr (bits_of into, p)
  | "sext", Sign (_, s) -> Sign (bits_of into, s)
  | ("fptrunc" | "fpext"), Fl f -> of_float into_double (to_float f)
  | "fptoui", Fl f -> float_to_int ~unsigned:true (bits_of into) f
  | "fptosi", Fl f -> float_to_int ~unsigned:false (bits_of into) f
  | "uitofp", Int (b, x) ->
      if has C_ir.nneg && sext b x < 0L then Poison else int_to_float ~unsigned:true ~double:into_double b x
  | "sitofp", Int (b, x) -> int_to_float ~unsigned:false ~double:into_double b x
  | "ptrtoint", Ptr p when p.alloc.freed -> stop dangling
  | "ptrtoint", Ptr p -> if bits_of into >= 64 then Addr (bits_of into, p) else stop "an address truncated to fewer bits than it has"
  | "ptrtoint", Null -> Int (bits_of into, 0L)
  | "ptrtoint", Wild x -> int (bits_of into) x
  | "inttoptr", Int (_, 0L) -> Null
  | "inttoptr", Int (b, x) -> Wild (mask b x)
  | "inttoptr", Addr (_, p) -> Ptr p
  | "addrspacecast", _ -> v
  | _, Sign _ -> stop sign_only
  | _ -> stop ("a cast the evaluator does not model: " ^ opcode)
