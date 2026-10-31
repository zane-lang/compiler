(* A list's handle, read and written field by field: its items, its count
   of elements and its room in bytes. With Ref32 (experimental,
   docs/experiments/goose-comparison) each field takes 32 bits and the
   items are stored as their address shifted right by 3, which the cage
   keeps below 2^35 (runtime/region.c); with frame references the items are
   a pointer and the count and the room take 32 bits each, the room counted
   in elements ([elements]); otherwise the
   handle is a pointer and two 64-bit integers. The fields read as a
   pointer and two `i64`s either way. [tag] marks each load and store the
   way the caller marks a handle's accesses. *)

(* Whether the count and the room take 32 bits, and whether the items are
   shifted too. *)
let on () = Cgt.Ref32.on () || Cgt.Ref32.frames ()
let shifted () = Cgt.Ref32.on ()

let header ctx =
  let i64 = Llvm.i64_type ctx and i32 = Llvm.i32_type ctx in
  if shifted () then Llvm.struct_type ctx [| i32; i32; i32 |]
  else if on () then Llvm.struct_type ctx [| Llvm.pointer_type ctx; i32; i32 |]
  else Llvm.struct_type ctx [| Llvm.pointer_type ctx; i64; i64 |]

let field ctx b h i = Llvm.build_struct_gep (header ctx) h i "" b

let narrow ctx b v = Llvm.build_trunc v (Llvm.i32_type ctx) "" b
let widen ctx b v = Llvm.build_zext v (Llvm.i64_type ctx) "" b

(* The program image's start, which a frame reference counts from
   (runtime/region.c): a symbol the linker defines, hidden so that its
   address is computed relative to the code, without a load. *)
let image b =
  let m = Llvm.global_parent (Llvm.block_parent (Llvm.insertion_block b)) in
  match Llvm.lookup_global "__ehdr_start" m with
  | Some g -> g
  | None ->
      let g = Llvm.declare_global (Llvm.i8_type (Llvm.module_context m)) "__ehdr_start" m in
      Llvm.set_visibility Llvm.Visibility.Hidden g;
      g

(* With `ZANE_FRAME_REFS_CHECK=1` when compiling, an encoded frame
   reference is checked to fit 32 bits, and the program traps if not. *)
let checked () = Sys.getenv_opt "ZANE_FRAME_REFS_CHECK" = Some "1"

(* A pointer from its 32-bit form, and the 32-bit form of a pointer: its
   address shifted by 3 with Ref32, else its distance from the image. *)
let decode ctx b v =
  if shifted () then
    Llvm.build_inttoptr (Llvm.build_shl (widen ctx b v) (Llvm.const_int (Llvm.i64_type ctx) 3) "" b)
      (Llvm.pointer_type ctx) "" b
  else Llvm.build_gep (Llvm.i8_type ctx) (image b) [| Llvm.build_sext v (Llvm.i64_type ctx) "" b |] "" b

let encode ctx b p =
  let i64 = Llvm.i64_type ctx in
  if shifted () then narrow ctx b (Llvm.build_lshr (Llvm.build_ptrtoint p i64 "" b) (Llvm.const_int i64 3) "" b)
  else
    let distance = Llvm.build_sub (Llvm.build_ptrtoint p i64 "" b) (Llvm.build_ptrtoint (image b) i64 "" b) "" b in
    let v = narrow ctx b distance in
    if checked () then begin
      let fn = Llvm.block_parent (Llvm.insertion_block b) in
      let bad = Llvm.append_block ctx "" fn and good = Llvm.append_block ctx "" fn in
      let fits = Llvm.build_icmp Llvm.Icmp.Eq (Llvm.build_sext v i64 "" b) distance "" b in
      ignore (Llvm.build_cond_br fits good bad b);
      Llvm.position_at_end bad b;
      let m = Llvm.global_parent fn in
      let t = Llvm.function_type (Llvm.void_type ctx) [||] in
      let trap = match Llvm.lookup_function "llvm.trap" m with Some f -> f | None -> Llvm.declare_function "llvm.trap" t m in
      ignore (Llvm.build_call t trap [||] "" b);
      ignore (Llvm.build_unreachable b);
      Llvm.position_at_end good b
    end;
    v

let items ?(tag = Fun.id) ctx b h =
  if shifted () then decode ctx b (tag (Llvm.build_load (Llvm.i32_type ctx) (field ctx b h 0) "" b))
  else tag (Llvm.build_load (Llvm.pointer_type ctx) (field ctx b h 0) "" b)

let integer ?(tag = Fun.id) ctx b h i =
  if on () then widen ctx b (tag (Llvm.build_load (Llvm.i32_type ctx) (field ctx b h i) "" b))
  else tag (Llvm.build_load (Llvm.i64_type ctx) (field ctx b h i) "" b)

let count ?tag ctx b h = integer ?tag ctx b h 1
let room ?tag ctx b h = integer ?tag ctx b h 2

let set_items ?(tag = Fun.id) ctx b p h =
  ignore (tag (Llvm.build_store (if shifted () then encode ctx b p else p) (field ctx b h 0) b))

let set_integer ?(tag = Fun.id) ctx b v h i =
  ignore (tag (Llvm.build_store (if on () then narrow ctx b v else v) (field ctx b h i) b))

let set_count ?tag ctx b v h = set_integer ?tag ctx b v h 1

(* Whether a list's room counts its elements, as with frame references,
   rather than its bytes (runtime/zane.h, ZL_ELEMENTS). *)
let elements () = Cgt.Ref32.frames ()

(* The room, in a list's unit, of a block of [bytes] bytes of elements
   [stride] wide, and the bytes of a block of [room] units: the bytes the
   block was taken with, to return it with. Constants both. *)
let units ~bytes ~stride = if elements () then bytes / stride else bytes
let block_bytes ~room ~stride = if elements () then (room * stride + 7) / 8 * 8 else room

(* The bytes of the block of the list at [h], whose elements are [stride]
   bytes wide, an [i64] constant. *)
let room_bytes ?tag ctx b h stride =
  let r = integer ?tag ctx b h 2 in
  if elements () then
    let i64 = Llvm.i64_type ctx in
    Llvm.build_and
      (Llvm.build_add (Llvm.build_mul r stride "" b) (Llvm.const_int i64 7) "" b)
      (Llvm.const_int i64 (-8)) "" b
  else r
let set_room ?tag ctx b v h = set_integer ?tag ctx b v h 2
