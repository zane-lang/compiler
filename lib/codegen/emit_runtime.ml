(* The runtime's functions as the emitted code declares and calls them, the
   alias tags its accesses carry, `@math$`'s functions and string literals
   (docs/design/lowering.md L2, §9): the second part of Emit, which includes
   it after Emit_types. *)

open Cgt.Nodes
open Loop_shapes
open Call_pieces
open Llvm_extra
open Emit_types
open Loop_copies


(* The runtime's functions, declared the first time a call needs one, with
   the signature [Cgt.Runtime] gives each. *)
let runtime env fn =
  let name = Cgt.Runtime.name fn in
  match Hashtbl.find_opt env.funcs name with
  | Some f -> f
  | None ->
      let abi = function
        | Cgt.Runtime.Void -> Llvm.void_type env.ctx
        | Cgt.Runtime.I32 -> Llvm.i32_type env.ctx
        | Cgt.Runtime.I64 -> env.i64
        | Cgt.Runtime.F32 -> Llvm.float_type env.ctx
        | Cgt.Runtime.F64 -> Llvm.double_type env.ctx
        | Cgt.Runtime.Ptr -> env.ptr
      in
      let ret, params = Cgt.Runtime.signature fn in
      let fty = Llvm.function_type (abi ret) (Array.of_list (List.map abi params)) in
      let f = Llvm.declare_function name fty env.m in
      (* The known facts of the runtime's body (Runtime_facts). *)
      Runtime_facts.apply f fn;
      Hashtbl.replace env.funcs name (f, fty);
      (f, fty)

let walks env = Option.get env.walks

(* Type-based alias information (LLVM's `!tbaa`), from which LLVM concludes
   that a write of an element's field leaves the list's header as it was. A
   handle, the header of a list or a string, is never a member or an element
   of a scalar's place, nor one inside it, since a path through a place's
   members stops at a handle (Cgt.Nodes.Expr.Offset), so a handle's fields and
   a place of a scalar type are disjoint storage. An access made here as one
   of the two is marked so by its tag: a handle's fields read and written
   where an element is located, pushed or removed, and a handle loaded or
   stored whole, as the first; a scalar loaded or stored through an address,
   and the elements a removal moves when no handle is among their bytes
   ([remove]), as the second. A scalar's tag is one for every scalar type,
   since storage the program reads as one type it may have written as another
   the same size, as a snapshot does. Everything else, a frame's or a walk's
   access, a copy of an aggregate and the runtime's own, carries no tag, which
   LLVM takes as one that may touch both. *)
let tags ctx =
  let root = Llvm.mdnode ctx [| Llvm.mdstring ctx "zane" |] in
  let tag name =
    let zero = Llvm.const_int (Llvm.i64_type ctx) 0 in
    let node = Llvm.mdnode ctx [| Llvm.mdstring ctx name; root; zero |] in
    Llvm.mdnode ctx [| node; node; zero |]
  in
  (tag "zane handle", tag "zane scalar")

(* The most passes of a constant-count loop unrolled whole. *)
let unrolled_whole = 8

(* A scalar's tag by its size, a child of the scalar tag: one byte (Bool,
   U8), four and eight apart, since a place is only read back as a type of
   the size it was written as. A one-byte store then leaves the wider
   scalars read around it in place. *)
let sized_tag ctx name =
  let zero = Llvm.const_int (Llvm.i64_type ctx) 0 in
  let root = Llvm.mdnode ctx [| Llvm.mdstring ctx "zane" |] in
  let scalar = Llvm.mdnode ctx [| Llvm.mdstring ctx "zane scalar"; root; zero |] in
  let node = Llvm.mdnode ctx [| Llvm.mdstring ctx name; scalar; zero |] in
  Llvm.mdnode ctx [| node; node; zero |]

let access env (t : Ty.t) instr =
  let tag =
    match t with
    | Ty.Handle | Ty.Handle16 -> Some env.handle_tag
    | Ty.I1 | Ty.I8 -> Some (sized_tag env.ctx "zane byte")
    | Ty.I32 | Ty.F32 -> Some (sized_tag env.ctx "zane word4")
    | Ty.I64 | Ty.F64 | Ty.Ptr -> Some (sized_tag env.ctx "zane word8")
    | Ty.Ref | Ty.Box32 -> Some env.value_tag
    | Ty.Void | Ty.Struct _ | Ty.Sum _ | Ty.Array _ | Ty.Packed _ -> None
  in
  Option.iter (Llvm.set_metadata instr (Llvm.mdkind_id env.ctx "tbaa")) tag;
  instr

(* A handle's field: what [element], [push] and [remove] read and write. *)
let handle_field env instr =
  Llvm.set_metadata instr (Llvm.mdkind_id env.ctx "tbaa") env.handle_tag;
  instr

(* A list's count or room read from its header, which is never negative. *)
let count_field env instr =
  let range =
    Llvm.mdnode env.ctx [| Llvm.const_int env.i64 0; Llvm.const_of_int64 env.i64 Int64.min_int false |]
  in
  Llvm.set_metadata instr (Llvm.mdkind_id env.ctx "range") range;
  handle_field env instr

(* A math function of `@math$` (math.md §2) on operands of type [t]. An
   exact one is an instruction or an LLVM intrinsic: a shift's count is
   taken modulo the width first, since LLVM gives no result for a count at
   or past it, and a rotation is a funnel shift of the value with itself,
   which takes its count modulo the width already. `roundEven` is `rint`,
   which rounds as the rounding mode does, and a program never leaves the
   default one, to nearest with ties to even. An approximate one is a call
   to the C math library's function of that name, `f`-suffixed for an
   `F32`, marked `nobuiltin` so that LLVM neither computes it nor rewrites
   it: its result is the library's where the program runs (math.md §2.6). *)
let math env b (fn : Cgt.Math.fn) (t : Ty.t) args =
  let lt = lltype env t in
  let declare name params ret =
    match Llvm.lookup_function name env.m with
    | Some f -> (f, Llvm.function_type ret params)
    | None ->
        let fty = Llvm.function_type ret params in
        (Llvm.declare_function name fty env.m, fty)
  in
  let intrinsic base args =
    let suffix =
      match t with
      | Ty.I32 -> "i32"
      | Ty.I64 -> "i64"
      | Ty.F32 -> "f32"
      | Ty.F64 -> "f64"
      | _ -> Diagnostic.bug ("codegen: a math function on " ^ Ty.to_string t)
    in
    let f, fty =
      declare ("llvm." ^ base ^ "." ^ suffix) (Array.of_list (List.map Llvm.type_of args)) lt
    in
    Llvm.build_call fty f (Array.of_list args) "" b
  in
  let no = Llvm.const_int (Llvm.i1_type env.ctx) 0 in
  let count c =
    let width = match t with Ty.I32 -> 32 | _ -> 64 in
    Llvm.build_and c (Llvm.const_int lt (width - 1)) "" b
  in
  let library name =
    let name = if t = Ty.F32 then name ^ "f" else name in
    let f, fty = declare name (Array.of_list (List.map Llvm.type_of args)) lt in
    let call = Llvm.build_call fty f (Array.of_list args) "" b in
    Llvm.add_call_site_attr call (Llvm.create_enum_attr env.ctx "nobuiltin" 0L) Llvm.AttrIndex.Function;
    call
  in
  let float = match t with Ty.F32 | Ty.F64 -> true | _ -> false in
  match (fn, args) with
  | Cgt.Math.Bit_and, [ l; r ] -> Llvm.build_and l r "" b
  | Cgt.Math.Bit_or, [ l; r ] -> Llvm.build_or l r "" b
  | Cgt.Math.Bit_xor, [ l; r ] -> Llvm.build_xor l r "" b
  | Cgt.Math.Bit_not, [ v ] -> Llvm.build_not v "" b
  | Cgt.Math.Shift_left, [ v; c ] -> Llvm.build_shl v (count c) "" b
  | Cgt.Math.Shift_right, [ v; c ] -> Llvm.build_ashr v (count c) "" b
  | Cgt.Math.Shift_right_logical, [ v; c ] -> Llvm.build_lshr v (count c) "" b
  | Cgt.Math.Rotate_left, [ v; c ] -> intrinsic "fshl" [ v; v; c ]
  | Cgt.Math.Rotate_right, [ v; c ] -> intrinsic "fshr" [ v; v; c ]
  | Cgt.Math.Pop_count, [ v ] -> intrinsic "ctpop" [ v ]
  | Cgt.Math.Leading_zeros, [ v ] -> intrinsic "ctlz" [ v; no ]
  | Cgt.Math.Trailing_zeros, [ v ] -> intrinsic "cttz" [ v; no ]
  | Cgt.Math.Abs, [ v ] when float -> intrinsic "fabs" [ v ]
  | Cgt.Math.Abs, [ v ] -> intrinsic "abs" [ v; no ]
  | Cgt.Math.Min, [ l; r ] when float -> intrinsic "minimum" [ l; r ]
  | Cgt.Math.Min, [ l; r ] -> intrinsic "smin" [ l; r ]
  | Cgt.Math.Max, [ l; r ] when float -> intrinsic "maximum" [ l; r ]
  | Cgt.Math.Max, [ l; r ] -> intrinsic "smax" [ l; r ]
  | Cgt.Math.Sqrt, [ v ] -> intrinsic "sqrt" [ v ]
  | Cgt.Math.Floor, [ v ] -> intrinsic "floor" [ v ]
  | Cgt.Math.Ceil, [ v ] -> intrinsic "ceil" [ v ]
  | Cgt.Math.Trunc, [ v ] -> intrinsic "trunc" [ v ]
  | Cgt.Math.Round_even, [ v ] -> intrinsic "rint" [ v ]
  | Cgt.Math.Fma, [ l; r; a ] -> intrinsic "fma" [ l; r; a ]
  | Cgt.Math.Copy_sign, [ m; s ] ->
      (* A NaN's sign is not the program's to see (math.md §2.5), so a NaN
         sign operand counts as positive. *)
      let nan = Llvm.build_fcmp Llvm.Fcmp.Uno s s "" b in
      Llvm.build_select nan (intrinsic "fabs" [ m ]) (intrinsic "copysign" [ m; s ]) "" b
  | fn, _ when library_math fn -> library (Cgt.Math.name fn)
  | _ -> Diagnostic.bug ("codegen: `@math$" ^ Cgt.Math.name fn ^ "` with the wrong operands")


(* A layout's table of walks, or none when it lists nothing. *)
let layout env (l : Layout.t) = Walks.table (walks env) l
let listed env (l : Layout.t) = Walks.listed (walks env) l

(* A string literal is constant bytes the module owns, with no terminator,
   and owns no block. *)
let text env s =
  let bytes = Llvm.const_string env.ctx s in
  let g = Llvm.define_global "zane.text" bytes env.m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  Llvm.set_unnamed_addr true g;
  let n = Llvm.const_int env.i64 in
  Llvm.const_struct env.ctx [| g; n (String.length s); n 0 |]
