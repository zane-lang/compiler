(* What codegen needs of LLVM that its OCaml bindings lack or get wrong,
   bound in llvm_stubs.c. *)

external set_ordering : Llvm.llvalue -> bool -> unit = "zane_set_ordering"

(* Whether a load or store is atomic (llvm_stubs.c). *)
external is_atomic : Llvm.llvalue -> bool = "zane_is_atomic"

(* An array type and its length with all 64 bits of the count, where the
   bindings' own truncate it to 32 (llvm_stubs.c). *)
external array_type : Llvm.lltype -> int -> Llvm.lltype = "zane_array_type"
external array_length : Llvm.lltype -> int = "zane_array_length"

(* A type attribute, such as `sret(T)`, which the bindings cannot make
   (llvm_stubs.c). *)
external type_attr : Llvm.llcontext -> string -> Llvm.lltype -> Llvm.llattribute = "zane_type_attr"

(* A loop's `llvm.loop` node, naming itself and then holding [options],
   each an option's node such as `!{!"llvm.loop.unroll.count", i32 2}`,
   which the bindings cannot make (llvm_stubs.c). *)
external loop_id : Llvm.llcontext -> Llvm.llvalue array -> Llvm.llvalue = "zane_loop_id"

(* A function's own type (llvm_stubs.c). *)
external value_type : Llvm.llvalue -> Llvm.lltype = "zane_global_value_type"

(* The `align` attribute on a function's parameter, 1 for none (llvm_stubs.c). *)
external param_align : Llvm.llvalue -> int -> int = "zane_param_align"

(* The type a getelementptr steps through (llvm_stubs.c). *)
external gep_source_type : Llvm.llvalue -> Llvm.lltype = "zane_gep_source_type"

(* `llvm.assume` with `dereferenceable` and `align` bundles on an address,
   at the end of a block, which the bindings cannot build (llvm_stubs.c):
   the block, `llvm.assume` and its type, the address, its size and its
   alignment. *)
external assume_dereferenceable :
  Llvm.llbasicblock -> Llvm.lltype -> Llvm.llvalue -> Llvm.llvalue -> Llvm.llvalue -> Llvm.llvalue -> unit
  = "zane_assume_dereferenceable_bytecode" "zane_assume_dereferenceable"

(* The bindings' `param_types`, `struct_element_types` and `function_attrs`,
   correct when they give nothing (llvm_stubs.c). Codegen uses these
   instead. *)
external param_types : Llvm.lltype -> Llvm.lltype array = "zane_param_types"
external struct_element_types : Llvm.lltype -> Llvm.lltype array = "zane_struct_element_types"
external function_attrs_at : Llvm.llvalue -> int -> Llvm.llattribute array = "zane_function_attrs"

let function_attrs f (i : Llvm.AttrIndex.t) =
  function_attrs_at f (match i with Llvm.AttrIndex.Function -> -1 | Return -> 0 | Param n -> n + 1)
