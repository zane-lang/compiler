(* A list's handle, read and written field by field: its items, its count
   of elements and its room in bytes. With Ref32 (experimental,
   docs/experiments/goose-comparison) each field takes 32 bits and the
   items are stored as their address shifted right by 3, which the cage
   keeps below 2^35 (runtime/region.c); otherwise the handle is a pointer
   and two 64-bit integers. The fields read as a pointer and two `i64`s
   either way. [tag] marks each load and store the way the caller marks a
   handle's accesses. *)

let on () = Cgt.Ref32.on ()

let header ctx =
  let i64 = Llvm.i64_type ctx and i32 = Llvm.i32_type ctx in
  if on () then Llvm.struct_type ctx [| i32; i32; i32 |]
  else Llvm.struct_type ctx [| Llvm.pointer_type ctx; i64; i64 |]

let field ctx b h i = Llvm.build_struct_gep (header ctx) h i "" b

let narrow ctx b v = Llvm.build_trunc v (Llvm.i32_type ctx) "" b
let widen ctx b v = Llvm.build_zext v (Llvm.i64_type ctx) "" b

(* A pointer from its 32-bit form, and the 32-bit form of a pointer. *)
let decode ctx b v =
  Llvm.build_inttoptr (Llvm.build_shl (widen ctx b v) (Llvm.const_int (Llvm.i64_type ctx) 3) "" b)
    (Llvm.pointer_type ctx) "" b

let encode ctx b p =
  narrow ctx b (Llvm.build_lshr (Llvm.build_ptrtoint p (Llvm.i64_type ctx) "" b) (Llvm.const_int (Llvm.i64_type ctx) 3) "" b)

let items ?(tag = Fun.id) ctx b h =
  if on () then decode ctx b (tag (Llvm.build_load (Llvm.i32_type ctx) (field ctx b h 0) "" b))
  else tag (Llvm.build_load (Llvm.pointer_type ctx) (field ctx b h 0) "" b)

let integer ?(tag = Fun.id) ctx b h i =
  if on () then widen ctx b (tag (Llvm.build_load (Llvm.i32_type ctx) (field ctx b h i) "" b))
  else tag (Llvm.build_load (Llvm.i64_type ctx) (field ctx b h i) "" b)

let count ?tag ctx b h = integer ?tag ctx b h 1
let room ?tag ctx b h = integer ?tag ctx b h 2

let set_items ?(tag = Fun.id) ctx b p h =
  ignore (tag (Llvm.build_store (if on () then encode ctx b p else p) (field ctx b h 0) b))

let set_integer ?(tag = Fun.id) ctx b v h i =
  ignore (tag (Llvm.build_store (if on () then narrow ctx b v else v) (field ctx b h i) b))

let set_count ?tag ctx b v h = set_integer ?tag ctx b v h 1
let set_room ?tag ctx b v h = set_integer ?tag ctx b v h 2
