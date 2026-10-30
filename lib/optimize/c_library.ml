(* The C library functions whose meaning is exact, which the C evaluator
   runs where C calls them with no body in the build (docs/design/ffi.md
   F16). Any other is unknown, and the fold stops there.

   `memcmp`, `strcmp` and `strncmp` promise only the sign of their
   result, which is what they give. An allocation of zero bytes may or may
   not be null, so making one stops; any other succeeds while it fits the
   budget, `malloc`'s bytes unwritten and `calloc`'s zero. *)

open Value
open C_memory

let ptr_of = function Ptr p -> p | Null -> stop "a null pointer passed to the C library" | _ -> stop "an address that names nothing"
let size_of = function Int (_, n) -> n | Addr _ -> stop C_ops.number | _ -> stop "a size that is not an integer"

(* A size as an OCaml int, refusing one larger than any allocation. *)
let small n = if n < 0L || n > Int64.of_int Sys.max_string_length then stop "a size larger than any allocation" else Int64.to_int n

(* Work that grows with a size costs a step for each 64 bytes (F19). *)
let charge spend n = if n >= 64 then spend (n / 64)

let overlapping p q n = p.alloc == q.alloc && p.off < q.off + n && q.off < p.off + n

let memcpy spend d s n =
  let n = small (size_of n) in
  charge spend n;
  let d = ptr_of d and s = ptr_of s in
  if n > 0 then begin
    if overlapping d s n then stop "a memcpy between overlapping bytes";
    copy ~dst:d ~src:s n
  end;
  Ptr d

let memmove spend d s n =
  let n = small (size_of n) in
  charge spend n;
  let d = ptr_of d and s = ptr_of s in
  if n > 0 then copy ~dst:d ~src:s n;
  Ptr d

let memset spend d c n =
  let n = small (size_of n) in
  charge spend n;
  let d = ptr_of d in
  (match c with Int (_, c) -> if n > 0 then fill d n (Int64.to_int c) | _ -> stop "a memset of something not a byte");
  Ptr d

let at p i = { p with off = p.off + i }

(* The sign of the first difference between the bytes at [a] and [b],
   reading at most [limit] of them, stopping after a zero byte when
   [strings]. *)
let compare_bytes spend ~strings ~limit a b =
  let a = ptr_of a and b = ptr_of b in
  let rec go i =
    if i >= limit then 0
    else begin
      if i land 63 = 0 then spend 1;
      let x = byte (at a i) and y = byte (at b i) in
      if x <> y then compare x y else if strings && x = 0 then 0 else go (i + 1)
    end
  in
  Sign (32, go 0)

let memchr spend p c n =
  let n = small (size_of n) and p = ptr_of p in
  let c = match c with Int (_, c) -> Int64.to_int c land 0xff | _ -> stop "a memchr for something not a byte" in
  let rec go i =
    if i >= n then Null
    else begin
      if i land 63 = 0 then spend 1;
      if byte (at p i) = c then Ptr (at p i) else go (i + 1)
    end
  in
  go 0

let strlen spend p =
  let p = ptr_of p in
  let rec go i =
    if i land 63 = 0 then spend 1;
    if byte (at p i) = 0 then i else go (i + 1)
  in
  Int (64, Int64.of_int (go 0))

let allocate spend n =
  if n = 0 then stop "an allocation of zero bytes, which may or may not be null";
  charge spend n;
  alloc Heap ~size:n ~align:16

let malloc spend n = Ptr { alloc = allocate spend (small (size_of n)); off = 0 }

let calloc spend count size =
  let hi, lo = C_ops.umul128 (size_of count) (size_of size) in
  if hi <> 0L || lo < 0L then Null
  else
    let a = allocate spend (small lo) in
    zero_fill a 0 a.size;
    Ptr { alloc = a; off = 0 }

(* Memory [malloc] and its kin gave, at its start and not yet freed. *)
let heap p =
  match p with
  | Ptr ({ alloc = { kind = Heap; freed = false; _ }; off = 0 } as p) -> p
  | _ -> stop "memory released that the C library did not give"

let realloc spend p n =
  match p with
  | Null -> malloc spend n
  | _ ->
      let old = heap p in
      let a = allocate spend (small (size_of n)) in
      copy ~dst:{ alloc = a; off = 0 } ~src:old (min a.size old.alloc.size);
      old.alloc.freed <- true;
      Ptr { alloc = a; off = 0 }

let free p = match p with Null -> () | _ -> (heap p).alloc.freed <- true

(* [abs], [labs] and [llabs], at the width the target gives the argument. *)
let abs = function
  | Int (bits, x) ->
      let v = C_ops.sext bits x in
      if v = C_ops.sext bits (Int64.shift_left 1L (bits - 1)) then stop "the absolute value of the most negative integer";
      int bits (Int64.abs v)
  | _ -> stop "an absolute value of something not an integer"

(* The function [name] called with [args], when it is one of the C
   library's this models. *)
let call ~spend name args =
  match (name, args) with
  | "memcpy", [ d; s; n ] -> Some (memcpy spend d s n)
  | "memmove", [ d; s; n ] -> Some (memmove spend d s n)
  | "memset", [ d; c; n ] -> Some (memset spend d c n)
  | "memcmp", [ a; b; n ] -> Some (compare_bytes spend ~strings:false ~limit:(small (size_of n)) a b)
  | "memchr", [ p; c; n ] -> Some (memchr spend p c n)
  | "strlen", [ p ] -> Some (strlen spend p)
  | "strcmp", [ a; b ] -> Some (compare_bytes spend ~strings:true ~limit:max_int a b)
  | "strncmp", [ a; b; n ] -> Some (compare_bytes spend ~strings:true ~limit:(small (size_of n)) a b)
  | "malloc", [ n ] -> Some (malloc spend n)
  | "calloc", [ c; s ] -> Some (calloc spend c s)
  | "realloc", [ p; n ] -> Some (realloc spend p n)
  | "free", [ p ] ->
      free p;
      Some Poison
  | ("abs" | "labs" | "llabs"), [ x ] -> Some (abs x)
  | _ -> None
