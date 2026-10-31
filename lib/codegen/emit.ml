(* The CGT as an LLVM module (docs/design/lowering.md L1, L2). Every CGT function is
   one LLVM function and every CGT type one LLVM type; nothing is decided
   here that the tree has not already said. *)

open Cgt.Nodes

external set_ordering : Llvm.llvalue -> bool -> unit = "zane_set_ordering"

(* An array type and its length with all 64 bits of the count, where the
   bindings' own truncate it to 32 (llvm_stubs.c). *)
external array_type : Llvm.lltype -> int -> Llvm.lltype = "zane_array_type"
external array_length : Llvm.lltype -> int = "zane_array_length"

(* A type attribute, such as `sret(T)`, which the bindings cannot make
   (llvm_stubs.c). *)
external type_attr : Llvm.llcontext -> string -> Llvm.lltype -> Llvm.llattribute = "zane_type_attr"

(* A function's own type (llvm_stubs.c). *)
external value_type : Llvm.llvalue -> Llvm.lltype = "zane_global_value_type"

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

(* How a value of a type crosses a call (docs/design/lowering.md §9): as
   itself, in as many registers as it has pieces; as the address of a slot
   that holds it; or, with packing, as that many 8-byte words. *)
type passing = Itself | Address | Words of int

(* A function's signature as it crosses: how each parameter that is not
   `Unit` passes, in order, and how the result comes back. *)
type abi = { params : (Ty.t * passing) list; ret : Ty.t * passing }

type env = {
  ctx : Llvm.llcontext;
  m : Llvm.llmodule;
  ptr : Llvm.lltype;
  i64 : Llvm.lltype;
  funcs : (string, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  (* How each of the program's functions is called, by symbol. *)
  abis : (string, abi) Hashtbl.t;
  (* How many registers a value may take and still pass as itself, from
     the target (see [registers]), whether small aggregates are packed into
     words, and how each type passes, worked out once per type. *)
  registers : int;
  pack : bool;
  passings : (Ty.t, passing) Hashtbl.t;
  (* The same for a result (see [results]). *)
  results : int * int;
  returnings : (Ty.t, passing) Hashtbl.t;
  globals : (string, Llvm.llvalue) Hashtbl.t;
  (* The walks of each layout the program names that lists a position. *)
  mutable walks : Walks.known option;
  (* The type-based alias tags of a handle's fields and of any other
     scalar (see [access]). *)
  handle_tag : Llvm.llvalue;
  value_tag : Llvm.llvalue;
  (* Whether a loop over elements is emitted twice (see [versioned]), which
     only the passes of an optimized build use. *)
  version : bool;
}

(* ---------------------------------------------------------------------- *)
(* Types                                                                  *)
(* ---------------------------------------------------------------------- *)

(* A value this many bytes or larger is moved as memory (Big_moves). *)
let large = 4096

let size_align = Ty.size_align
let words = Ty.words

(* Experimental packed nodes (Ty.Packed): the address of a place inside a
   packed type is named [unaligned_name], and so is one inside such a
   place, so that once a function is emitted every load and store through
   one is marked as at any byte. *)
let unaligned_name = "packed"

let is_unaligned v =
  match Llvm.classify_value v with
  | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> String.starts_with ~prefix:unaligned_name (Llvm.value_name v)
  | _ -> false

let unaligned fn =
  Llvm.iter_blocks
    (Llvm.iter_instrs (fun i ->
         match Llvm.instr_opcode i with
         | Llvm.Opcode.Load when is_unaligned (Llvm.operand i 0) -> Llvm.set_alignment 1 i
         | Llvm.Opcode.Store when is_unaligned (Llvm.operand i 1) -> Llvm.set_alignment 1 i
         | _ -> ()))
    fn

let rec lltype env (t : Ty.t) =
  match t with
  | Ty.Void -> Llvm.void_type env.ctx
  | Ty.I1 -> Llvm.i1_type env.ctx
  | Ty.I32 -> Llvm.i32_type env.ctx
  | Ty.I64 -> env.i64
  | Ty.F32 -> Llvm.float_type env.ctx
  | Ty.F64 -> Llvm.double_type env.ctx
  | Ty.Handle -> Llvm.struct_type env.ctx [| env.ptr; env.i64; env.i64 |]
  | Ty.Handle16 -> List_handle.header env.ctx
  | Ty.Ptr -> env.ptr
  | Ty.Ref | Ty.Box32 -> Llvm.i32_type env.ctx
  | Ty.Struct ts -> Llvm.struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Sum ts when Ty.niche ts -> Llvm.struct_type env.ctx [| Llvm.i32_type env.ctx |]
  | Ty.Sum ts -> (
      let tag = Llvm.i32_type env.ctx in
      match words ts with
      | 0 -> Llvm.struct_type env.ctx [| tag |]
      | n -> Llvm.struct_type env.ctx [| tag; array_type env.i64 n |])
  | Ty.Array (t, n) -> array_type (stored env t) n
  | Ty.Packed (Ty.Struct ts) -> Llvm.packed_struct_type env.ctx (Array.of_list (List.map (stored env) ts))
  | Ty.Packed (Ty.Sum ts) -> (
      let tag = Llvm.i8_type env.ctx in
      match Ty.room ts with
      | 0 -> Llvm.packed_struct_type env.ctx [| tag |]
      | n -> Llvm.packed_struct_type env.ctx [| tag; array_type (Llvm.i8_type env.ctx) n |])
  | Ty.Packed t -> lltype env t

(* A `Unit` member takes no room, but keeps its index. *)
and stored env t = if t = Ty.Void then Llvm.struct_type env.ctx [||] else lltype env t

(* ---------------------------------------------------------------------- *)
(* How a value crosses a call                                             *)
(* ---------------------------------------------------------------------- *)

(* The registers a value of type [t] takes as itself: the scalar pieces LLVM
   splits it into, one per register. A struct's and a sum's are their
   members', a sum's tag and each word of its payload room one apiece, an
   array's its element's times its length, and `Unit` none. Counted on the
   CGT type, not LLVM's, so the count does not depend on [data_layout].
   Never more than the type's size in bytes, which is below Ty.limit. *)
let rec pieces (t : Ty.t) =
  match t with
  | Ty.Void -> 0
  | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 | Ty.Ptr | Ty.Ref | Ty.Box32 -> 1
  | Ty.Handle | Ty.Handle16 -> 3
  | Ty.Struct ts -> List.fold_left (fun n t -> n + pieces t) 0 ts
  | Ty.Sum ts when Ty.niche ts -> 1
  | Ty.Sum ts -> 1 + words ts
  | Ty.Array (t, n) -> n * pieces t
  | Ty.Packed t -> (fst (Ty.size_align (Ty.Packed t)) + 7) / 8

(* How many of [pieces t] are floating-point. *)
let rec floats (t : Ty.t) =
  match t with
  | Ty.F32 | Ty.F64 -> 1
  | Ty.Struct ts -> List.fold_left (fun n t -> n + floats t) 0 ts
  | Ty.Array (t, n) -> n * floats t
  | _ -> 0

(* The registers a value may take and still pass as itself, which is what
   the target's C calling convention gives one aggregate: 2 on x86-64
   Linux and macOS and on AArch64, 1 on x86-64 Windows. Every target is
   64-bit (Build.sixty_four_bit). *)
let registers triple =
  match String.split_on_char '-' triple with
  | ("x86_64" | "amd64") :: rest when List.exists (String.starts_with ~prefix:"windows") rest -> 1
  | _ -> 2

(* The pieces a result may take and still come back as itself, and how many
   of them may be floating-point: what LLVM returns in registers. That is
   3 and 2 on x86-64 (rax, rdx and rcx, xmm0 and xmm1) on every system, and
   at least as many on AArch64, so a string or list handle comes back in
   registers. A third floating-point piece on x86-64 would come back
   through the x87 stack, and a fourth piece through memory LLVM
   allocates itself. Elsewhere it is the limit for an argument. *)
let results triple =
  match String.split_on_char '-' triple with
  | ("x86_64" | "x86_64h" | "amd64" | "aarch64" | "arm64" | "arm64e") :: _ -> (3, 2)
  | _ ->
      let n = registers triple in
      (n, n)

let aggregate = function
  | Ty.Struct _ | Ty.Sum _ | Ty.Array _ | Ty.Handle | Ty.Handle16 | Ty.Packed _ -> true
  | _ -> false

(* How a value of type [t] crosses a call: as itself when it takes no more
   registers than [env.registers], and by the address of a slot otherwise.
   With [env.pack], an aggregate that fits in that many 8-byte words passes
   as them instead, every word an integer, as clang passes a small C
   struct. Fixed by the type, so every call site and every callee agree,
   and a function value's call too. *)
let passing env (t : Ty.t) =
  match Hashtbl.find_opt env.passings t with
  | Some p -> p
  | None ->
      let p =
        let size = fst (size_align t) in
        let words = (size + 7) / 8 in
        if env.pack && aggregate t && size > 0 then if words <= env.registers then Words words else Address
        else if pieces t <= env.registers then Itself
        else Address
      in
      Hashtbl.replace env.passings t p;
      p

(* How a result of type [t] comes back from a call: as [passing] decides
   for an argument, but within [env.results], so a result may take more
   registers than an argument. A larger one is written through an `sret`
   pointer to a slot of the caller's. *)
let returning env (t : Ty.t) =
  match Hashtbl.find_opt env.returnings t with
  | Some p -> p
  | None ->
      let most, most_floats = env.results in
      let p =
        let size = fst (size_align t) in
        let words = (size + 7) / 8 in
        if env.pack && aggregate t && size > 0 then if words <= most then Words words else Address
        else if pieces t <= most && floats t <= most_floats then Itself
        else Address
      in
      Hashtbl.replace env.returnings t p;
      p

(* The LLVM type [n] words travel as: one `i64`, or a struct of them. *)
let words_type env n = if n = 1 then env.i64 else Llvm.struct_type env.ctx (Array.make n env.i64)

(* A signature as it crosses (see [passing]). `Unit` has no storage, so a
   `Unit` parameter passes nothing. *)
let abi env params ret =
  let kept = List.filter (fun t -> t <> Ty.Void) params in
  let crossing t = if t = Ty.Void then Itself else returning env t in
  { params = List.map (fun t -> (t, passing env t)) kept; ret = (ret, crossing ret) }

(* The LLVM function type of [a]: a result passed by address is written
   through a leading pointer, and returns nothing. *)
let abi_type env a =
  let ret, ret_passing = a.ret in
  let result, leading =
    match ret_passing with
    | Itself -> (lltype env ret, [])
    | Address -> (Llvm.void_type env.ctx, [ env.ptr ])
    | Words n -> (words_type env n, [])
  in
  let param (t, p) =
    match p with Itself -> [ lltype env t ] | Address -> [ env.ptr ] | Words n -> List.init n (fun _ -> env.i64)
  in
  Llvm.function_type result (Array.of_list (leading @ List.concat_map param a.params))

let fn_type env params ret = abi_type env (abi env params ret)

(* What a signature tells LLVM, as attributes on each LLVM parameter, by
   index. A parameter passed by address is a borrow (memory.md §2.9), and
   nothing in the call writes what it borrows (§2.9.1), so it is `readonly`
   and `noalias`, aligned and dereferenceable for its whole size: the
   optimizer may take the value behind it for a private copy. It is not
   `nocapture`, since a call the callee spawns may hold the address for as
   long as it runs. A result passed by address is written through an
   `sret` pointer to a fresh slot of the caller's, which nothing else
   names, so that one is `noalias` too. *)
let abi_attrs env a =
  let enum name v = Llvm.create_enum_attr env.ctx name v in
  let aligned t = enum "align" (Int64.of_int (snd (size_align t))) in
  let ret, ret_passing = a.ret in
  let leading =
    match ret_passing with
    | Address -> [ [ type_attr env.ctx "sret" (lltype env ret); enum "noalias" 0L; aligned ret ] ]
    | Itself | Words _ -> []
  in
  let param (t, p) =
    match p with
    | Itself -> [ [] ]
    | Words n -> List.init n (fun _ -> [])
    | Address ->
        [
          [
            enum "readonly" 0L;
            enum "noalias" 0L;
            aligned t;
            enum "dereferenceable" (Int64.of_int (fst (size_align t)));
          ];
        ]
  in
  List.mapi (fun i attrs -> (i, attrs)) (leading @ List.concat_map param a.params)

let declare_abi env f a =
  List.iter
    (fun (i, attrs) -> List.iter (fun at -> Llvm.add_function_attr f at (Llvm.AttrIndex.Param i)) attrs)
    (abi_attrs env a)

(* What a function's [places] (Func) tell LLVM: each is the address of a
   whole slot that outlives the call, so it is `nonnull`, aligned and
   dereferenceable for the slot's size. That lets the optimizer read
   through it ahead of a branch, as it hoists a list's length and storage
   out of a loop that checks its indices. Nothing more is promised: the
   function may write the slot, and another parameter may name it too. *)
let declare_places env fn (f : Func.t) a =
  let enum name v = Llvm.create_enum_attr env.ctx name v in
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  let width = function Itself | Address -> 1 | Words n -> n in
  let first = if snd a.ret = Address then 1 else 0 in
  ignore
    (List.fold_left2
       (fun i (id, _) (_, passing) ->
         (match List.assoc_opt id f.Func.places with
         | Some t when passing = Itself && fst (size_align t) > 0 ->
             let size, align = size_align t in
             List.iter
               (fun at -> Llvm.add_function_attr fn at (Llvm.AttrIndex.Param i))
               [ enum "nonnull" 0L; enum "align" (Int64.of_int align); enum "dereferenceable" (Int64.of_int size) ]
         | _ -> ());
         i + width passing)
       first kept a.params)

(* ---------------------------------------------------------------------- *)
(* The runtime and its layouts                                            *)
(* ---------------------------------------------------------------------- *)

(* LLVM's attributes of a function that reads any memory and writes none,
   and of a pointer parameter it only reads through and keeps no copy of.
   How each is spelled inside LLVM changes between releases, so LLVM's
   parser makes them rather than this file. *)
let reads_only ctx =
  let source =
    "declare void @f(ptr nocapture readonly) memory(read) nounwind willreturn nosync nofree"
  in
  let m = Llvm_irreader.parse_ir ctx (Llvm.MemoryBuffer.of_string source) in
  let f = Option.get (Llvm.lookup_function "f" m) in
  let attrs =
    (function_attrs f Llvm.AttrIndex.Function, function_attrs f (Llvm.AttrIndex.Param 0))
  in
  Llvm.dispose_module m;
  attrs

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
      (* What the runtime's body is known to do, as LLVM attributes, which
         are a contract on it rather than a hint. An index out of range and
         a nest of scopes too deep stop the program, so the path to either
         is cold and nothing follows it. Comparing two strings only reads
         them, and what their handles point to. *)
      let attr index a = Llvm.add_function_attr f (Llvm.create_enum_attr env.ctx a 0L) index in
      (match fn with
      | Cgt.Runtime.Out_of_range | Cgt.Runtime.Too_deep ->
          List.iter (attr Llvm.AttrIndex.Function) [ "noreturn"; "cold"; "nounwind" ]
      | Cgt.Runtime.Text_equal ->
          let fn_attrs, param = reads_only env.ctx in
          Array.iter (fun a -> Llvm.add_function_attr f a Llvm.AttrIndex.Function) fn_attrs;
          List.iter
            (fun i -> Array.iter (fun a -> Llvm.add_function_attr f a (Llvm.AttrIndex.Param i)) param)
            [ 0; 1 ]
      | _ -> ());
      Hashtbl.replace env.funcs name (f, fty);
      (f, fty)

let walks env = Option.get env.walks

(* Type-based alias information (LLVM's `!tbaa`), which tells LLVM that a
   write of an element's field leaves the list's header as it was. A handle,
   the header of a list or a string, is never a member or an element of a
   scalar's place, nor one inside it, since a path through a place's members
   stops at a handle (Cgt.Nodes.Expr.Offset), so a handle's fields and a
   place of a scalar type are disjoint storage. An access made here as one
   of the two says so with its tag: a handle's fields read and written where
   an element is located, pushed or removed, and a handle loaded or stored
   whole, as the first; a scalar loaded or stored through an address, and
   the elements a removal moves when no handle is among their bytes
   ([remove]), as the second. A scalar's tag is one for every scalar type,
   since storage the program reads as one type it may have written as
   another the same size, as a snapshot does. Everything else, a frame's or
   a walk's access, a copy of an aggregate and the runtime's own, carries no
   tag, which LLVM takes as one that may touch both. *)
let tags ctx =
  let root = Llvm.mdnode ctx [| Llvm.mdstring ctx "zane" |] in
  let tag name =
    let zero = Llvm.const_int (Llvm.i64_type ctx) 0 in
    let node = Llvm.mdnode ctx [| Llvm.mdstring ctx name; root; zero |] in
    Llvm.mdnode ctx [| node; node; zero |]
  in
  (tag "zane handle", tag "zane scalar")

let access env (t : Ty.t) instr =
  let tag =
    match t with
    | Ty.Handle | Ty.Handle16 -> Some env.handle_tag
    | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 | Ty.Ptr | Ty.Ref | Ty.Box32 -> Some env.value_tag
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
  | ( ( Cgt.Math.Cbrt | Cgt.Math.Sin | Cgt.Math.Cos | Cgt.Math.Tan | Cgt.Math.Asin | Cgt.Math.Acos
      | Cgt.Math.Atan | Cgt.Math.Atan2 | Cgt.Math.Exp | Cgt.Math.Log | Cgt.Math.Pow
      | Cgt.Math.Hypot ) as fn ),
    _ ->
      library (Cgt.Math.name fn)
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

(* ---------------------------------------------------------------------- *)
(* Frames and slots                                                       *)
(* ---------------------------------------------------------------------- *)

(* Where a list's run of pushes stands ([runs]): [Ahead n] before its first
   push, which makes room for all [n]; [Room n] while the next [n] have
   room already. *)
type run = Ahead of int | Room of int

(* What a function being built keeps: its symbol, its slots, the exit
   block of each expansion it is inside with how many arenas were open when
   it began, each open arena's record, the arenas open where it is building,
   innermost first (L8), where in its arena's frame each slot is, how
   many loops it is building inside, and its runs of pushes. *)
type frame = {
  fn : Llvm.llvalue;
  symbol : string;
  locals : (int, Llvm.llvalue * Llvm.lltype) Hashtbl.t;
  labels : (int, Llvm.llbasicblock * int) Hashtbl.t;
  arenas : (int, Llvm.llvalue) Hashtbl.t;
  mutable open_ : Llvm.llvalue list;
  offsets : (int, int) Hashtbl.t;
  (* The function's result type and how it comes back, and the slot it is
     written to when that is by address. *)
  ret : Ty.t * passing;
  sret : Llvm.llvalue option;
  mutable loops : int;
  (* Each fresh list a run of pushes follows ([runs]), with where its run
     stands. *)
  runs : (int, run) Hashtbl.t;
  (* Experimental (ZANE_HOIST_HANDLES): the lists whose items and count the
     loop being emitted read once before it ([invariant_lists]), each by the
     expression of its address, and how a local of the loop's body names one. *)
  mutable hoisted : (Expr.t * (Llvm.llvalue * Llvm.llvalue)) list;
  names : (int, Expr.t) Hashtbl.t;
  (* The element addresses the loop being emitted checks before it ([ranged]). *)
  mutable unchecked : Expr.t list;
}

let call_runtime env b name args =
  let f, fty = runtime env name in
  Llvm.build_call fty f args "" b

let block env fr = Llvm.append_block env.ctx "" fr.fn

let open_scope env = Walks.zane_open env.m env.ptr

(* Whether drains are checked (runtime/main.c). *)
let checking env =
  match Llvm.lookup_global "zane_checking" env.m with
  | Some g -> g
  | None -> Llvm.declare_global (Llvm.i32_type env.ctx) "zane_checking" env.m

let byte_at env b p offset =
  if offset = 0 then p
  else Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) p [| Llvm.const_int env.i64 offset |] "" b

let field env b t p offset = Llvm.build_load t (byte_at env b p offset) "" b
let set_field env b v p offset = ignore (Llvm.build_store v (byte_at env b p offset) b)

let zero env b p size =
  if size > 0 then begin
    let name = "llvm.memset.p0.i64" in
    let i1 = Llvm.i1_type env.ctx and i8 = Llvm.i8_type env.ctx in
    let t = Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; i8; env.i64; i1 |] in
    let f = match Llvm.lookup_function name env.m with Some f -> f | None -> Llvm.declare_function name t env.m in
    ignore
      (Llvm.build_call t f [| p; Llvm.const_int i8 0; Llvm.const_int env.i64 size; Llvm.const_int i1 0 |] "" b)
  end

(* A branch that is almost never taken, as LLVM's branch weights say it, so
   its code is laid out away from the path that is. *)
let unlikely env br =
  let i32 = Llvm.i32_type env.ctx in
  let weights =
    Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "branch_weights"; Llvm.const_int i32 1; Llvm.const_int i32 2000 |]
  in
  Llvm.set_metadata br (Llvm.mdkind_id env.ctx "prof") weights

(* A loop's test, [br], weighted as going round [trips] times for each time
   it leaves. *)
let weigh env br trips =
  let i32 = Llvm.i32_type env.ctx in
  let weights =
    Llvm.mdnode env.ctx [| Llvm.mdstring env.ctx "branch_weights"; Llvm.const_int i32 trips; Llvm.const_int i32 1 |]
  in
  Llvm.set_metadata br (Llvm.mdkind_id env.ctx "prof") weights

(* The count from which a [versioned] loop runs its long copy, and how often
   each copy is said to go round: the long one as a hot loop, the short one
   fewer times than IRCE splits a loop's checks for (Passes.llvm_options). *)
let long_loop = 16
let long_trips = 1000
let short_trips = 4

(* Whether a loop with [body] in the function [symbol] is emitted twice
   (Stat.Repeat): it holds no loop, no spawned call and no call back into
   [symbol], whose cost would dwarf a check, nothing leaves it before its
   count runs out, and it reads or writes a list's element, whose check IRCE
   may take out of it. *)
let versioned ~symbol body =
  let inside = Hashtbl.create 8 in
  Cgt.Traverse.walk_stats
    (fun e -> match e.Expr.node with Expr.Expand { label; _ } -> Hashtbl.replace inside label () | _ -> ())
    ignore body;
  let indexes = function Cgt.Runtime.List_at | Cgt.Runtime.Array_at -> true | _ -> false in
  (not
     (Cgt.Traverse.exists_in body
        ~expr:(fun e -> match e.Expr.node with Expr.Call { fn; _ } -> fn = symbol | _ -> false)
        ~stat:(function
          | Stat.Repeat _ | Stat.Spawn _ | Stat.Join _ | Stat.Return _ -> true
          | Stat.Leave label -> not (Hashtbl.mem inside label)
          | _ -> false)))
  && Cgt.Traverse.exists_in body
       ~expr:(fun e -> match e.Expr.node with Expr.Runtime { fn; _ } -> indexes fn | _ -> false)
       ~stat:(fun _ -> false)

(* Offsets into a scope's record and a context (runtime/zane_abi.h). *)
let record_context = Abi.mark_context
and record_depth = Abi.mark_depth
and record_outer = Abi.mark_outer
and record_skip = Abi.mark_skip
and record_tasks = Abi.mark_tasks
and record_mappings = Abi.mark_mappings
and record_stacks = Abi.mark_stacks
and context_frontier = Abi.context_frontier
and context_top = Abi.context_top
and context_limit = Abi.context_limit

(* A scope opens with a frame of [size] bytes (Frames), and its record's
   address names it. While no call this thread's context spawned is out,
   nothing else can reach the context, so the code places the frame itself:
   the record goes at the frontier, which moves past the frame, and links to
   the scope around it and to the one it skips to (runtime/zane_internal.h).
   A frame larger than the guard after the range is checked against the
   range's end first; a smaller one that does not fit faults in the guard.
   Otherwise the runtime places it under the context's lock.

   Either way, reading any slot of the open scope's frame is safe: in the
   range the runtime makes the slot's memory usable, and in the guard it
   stops the program, which a frame that does not fit owes it at whichever
   slot is touched first. The frame is on a 16-byte boundary, since every
   frame is a multiple of 16 bytes (Frames) placed where the one before it
   ended. The open scope tells LLVM both, so it may read a slot ahead of a
   branch, as it hoists a list's count out of a loop that checks its
   indices (docs/optimizations.md). *)
let enter env fr b size =
  let ptr = env.ptr and i64 = env.i64 in
  let outer = Llvm.build_load ptr (open_scope env) "" b in
  let inline = block env fr and shared = block env fr and opened = block env fr in
  ignore
    (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ne outer (Llvm.const_null ptr) "" b) inline shared b);
  Llvm.position_at_end inline b;
  let c = field env b ptr outer record_context in
  let m = field env b ptr c context_frontier in
  if size > Frames.guard then begin
    (* The room left is compared, not the frame's end, which would be an
       address past the range when the frame does not fit. *)
    let limit = field env b ptr c context_limit in
    let room = Llvm.build_sub (Llvm.build_ptrtoint limit i64 "" b) (Llvm.build_ptrtoint m i64 "" b) "" b in
    let over = Llvm.build_icmp Llvm.Icmp.Ult room (Llvm.const_int i64 size) "" b in
    let stop = block env fr and fits = block env fr in
    unlikely env (Llvm.build_cond_br over stop fits b);
    Llvm.position_at_end stop b;
    ignore (call_runtime env b Cgt.Runtime.Too_deep [||]);
    ignore (Llvm.build_unreachable b);
    Llvm.position_at_end fits b
  end;
  set_field env b (byte_at env b m size) c context_frontier;
  zero env b m Frames.record;
  set_field env b c m record_context;
  let depth = field env b i64 outer record_depth in
  set_field env b (Llvm.build_add depth (Llvm.const_int i64 1) "" b) m record_depth;
  set_field env b outer m record_outer;
  let a = field env b ptr outer record_skip in
  let a_depth = field env b i64 a record_depth in
  let b_ = field env b ptr a record_skip in
  let b_depth = field env b i64 b_ record_depth in
  let equal =
    Llvm.build_icmp Llvm.Icmp.Eq
      (Llvm.build_sub depth a_depth "" b)
      (Llvm.build_sub a_depth b_depth "" b)
      "" b
  in
  set_field env b (Llvm.build_select equal b_ outer "" b) m record_skip;
  set_field env b m c context_top;
  ignore (Llvm.build_store m (open_scope env) b);
  let inline_end = Llvm.insertion_block b in
  ignore (Llvm.build_br opened b);
  Llvm.position_at_end shared b;
  let placed = call_runtime env b Cgt.Runtime.Scope_enter [| Llvm.const_int i64 size |] in
  ignore (Llvm.build_br opened b);
  Llvm.position_at_end opened b;
  let frame = Llvm.build_phi [ (m, inline_end); (placed, shared) ] "" b in
  let assume, assume_ty =
    match Llvm.lookup_function "llvm.assume" env.m with
    | Some f -> (f, value_type f)
    | None ->
        let t = Llvm.function_type (Llvm.void_type env.ctx) [| Llvm.i1_type env.ctx |] in
        (Llvm.declare_function "llvm.assume" t env.m, t)
  in
  assume_dereferenceable (Llvm.insertion_block b) assume_ty assume frame (Llvm.const_int i64 size)
    (Llvm.const_int i64 16);
  frame

(* A scope drains (L8). One that spawned nothing and has no dynamic chunk,
   while its context is this thread's alone and drains are not checked, has
   nothing to wait for or give back but its frame, so the code moves the
   frontier back to its record itself. Otherwise the runtime drains it. *)
let drain_scope env fr b m =
  let ptr = env.ptr in
  let null = Llvm.const_null ptr in
  let innermost = Llvm.build_icmp Llvm.Icmp.Eq (Llvm.build_load ptr (open_scope env) "" b) m "" b in
  let look = block env fr and inline = block env fr and runtime_ = block env fr and drained = block env fr in
  ignore (Llvm.build_cond_br innermost look runtime_ b);
  Llvm.position_at_end look b;
  let empty p = Llvm.build_icmp Llvm.Icmp.Eq p null "" b in
  let unchecked =
    Llvm.build_icmp Llvm.Icmp.Eq
      (Llvm.build_load (Llvm.i32_type env.ctx) (checking env) "" b)
      (Llvm.const_int (Llvm.i32_type env.ctx) 0)
      "" b
  in
  let plain =
    Llvm.build_and
      (Llvm.build_and (empty (field env b ptr m record_tasks)) (empty (field env b ptr m record_mappings)) "" b)
      unchecked "" b
  in
  ignore (Llvm.build_cond_br plain inline runtime_ b);
  Llvm.position_at_end inline b;
  let c = field env b ptr m record_context in
  set_field env b m c context_frontier;
  let outer = field env b ptr m record_outer in
  set_field env b outer c context_top;
  ignore (Llvm.build_store outer (open_scope env) b);
  ignore (Llvm.build_br drained b);
  Llvm.position_at_end runtime_ b;
  ignore (call_runtime env b Cgt.Runtime.Scope_drain [| m |]);
  ignore (Llvm.build_br drained b);
  Llvm.position_at_end drained b

(* Drain the arenas opened since [depth] were open, innermost first: what a
   way out of them does before it jumps. *)
let drain env fr b depth =
  List.iteri (fun i arena -> if i < List.length fr.open_ - depth then drain_scope env fr b arena) fr.open_

(* Experimental (docs/experiments/goose-comparison): unless
   ZANE_LIGHT_SCOPES=0, a scope nothing can put a block in -- every slot it
   places holds scalars, and nothing in its body boxes, copies, makes a list
   or a string, spawns, or calls a function or the runtime in a way that
   could leave a block in the innermost region -- opens no region: its frame,
   when it is no larger than 4 KiB, is a slot on the machine stack. *)
let light id body =
  Sys.getenv_opt "ZANE_LIGHT_SCOPES" <> Some "0"
  &&
  let rec scalar (t : Ty.t) =
    match t with
    | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
    | Ty.Struct ts | Ty.Sum ts -> List.for_all scalar ts
    | Ty.Array (t, _) | Ty.Packed t -> scalar t
    | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> false
  in
  let quiet = function
    | Cgt.Runtime.List_push | List_room | List_reserve | List_at | Array_at | Out_of_range | Text_equal
    | Parse_i64 | Parse_f64 | List_remove { scalars = true } | List_swap_remove { scalars = true } ->
        true
    | _ -> false
  in
  not
    (Cgt.Traverse.exists_in body
       ~expr:(fun e ->
         match e.Expr.node with
         | Expr.Box _ | Expr.Text _ -> true
         | Expr.Runtime { fn; _ } -> not (quiet fn)
         | Expr.Call _ | Expr.Call_value _ | Expr.Copy _ | Expr.Take _ | Expr.Escape _ -> not (scalar e.Expr.ty)
         | _ -> false)
       ~stat:(function
         | Stat.Spawn _ | Stat.Join _ -> true
         | Stat.Hold { scope; value; _ } -> scope = id && not (scalar value.Expr.ty)
         | Stat.Reserve { scope; ty; _ } -> scope = id && not (scalar ty)
         | _ -> false))

(* Experimental (docs/experiments/goose-comparison): unless
   ZANE_HOIST_HANDLES=0, the lists a loop's [body] indexes when nothing in
   it can change a list's handle -- it calls no function, calls the runtime
   only to index, spawns nothing, and writes only scalars -- each by the
   expression of its address, with the locals the body binds to such an
   expression. Each address is made of addresses and offsets of slots made
   before the loop, so it can be computed, and the list's items and count
   read, before the loop: its checks then compare with a count the loop does
   not change, which IRCE needs. *)
let invariant_lists body =
  if Sys.getenv_opt "ZANE_HOIST_HANDLES" = Some "0" then ([], Hashtbl.create 1)
  else
    let rec scalar (t : Ty.t) =
      match t with
      | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true
      | Ty.Struct ts | Ty.Sum ts -> List.for_all scalar ts
      | Ty.Array (t, _) | Ty.Packed t -> scalar t
      | Ty.Handle | Ty.Handle16 | Ty.Ptr | Ty.Ref | Ty.Box32 -> false
    in
    let bound = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; _ } | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace bound id ()
        | Stat.Assign { place; _ } -> Hashtbl.replace bound place.Expr.local ()
        | _ -> ())
      body;
    let names = Hashtbl.create 8 in
    let rec address (e : Expr.t) =
      match e.Expr.node with
      | Expr.Address x -> if Hashtbl.mem bound x then None else Some e
      | Expr.Local x -> (
          match Hashtbl.find_opt names x with
          | Some a -> Some a
          | None -> if Hashtbl.mem bound x then None else Some e)
      | Expr.Offset ({ base; _ } as o) ->
          Option.map (fun base -> { e with Expr.node = Expr.Offset { o with base } }) (address base)
      | _ -> None
    in
    let assigned = Hashtbl.create 8 in
    Cgt.Traverse.walk_stats ignore
      (function Stat.Assign { place; _ } -> Hashtbl.replace assigned place.Expr.local () | _ -> ())
      body;
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; value } when not (Hashtbl.mem assigned id) ->
            Option.iter (Hashtbl.replace names id) (address value)
        | _ -> ())
      body;
    let changes =
      Cgt.Traverse.exists_in body
        ~expr:(fun e ->
          match e.Expr.node with
          | Expr.Call _ | Expr.Call_value _ | Expr.Box _ | Expr.Escape _ | Expr.Take _ | Expr.Copy _ -> true
          | Expr.Runtime { fn; _ } -> (
              match fn with Cgt.Runtime.List_at | Array_at | Out_of_range -> false | _ -> true)
          | _ -> false)
        ~stat:(function
          | Stat.Spawn _ | Stat.Join _ -> true
          (* A local assigned is never part of a hoisted address ([bound]). *)
          | Stat.Assign { place; value } -> place.Expr.deref && not (scalar value.Expr.ty)
          | Stat.Store { value; _ } | Stat.Place { value; _ } | Stat.Overwrite { value; _ } -> not (scalar value.Expr.ty)
          | Stat.Hold { value; _ } -> not (scalar value.Expr.ty)
          | Stat.Reserve { ty; _ } -> not (scalar ty)
          | _ -> false)
    in
    if changes then ([], names)
    else begin
      let lists = ref [] in
      Cgt.Traverse.walk_stats
        (fun e ->
          match e.Expr.node with
          | Expr.Runtime { fn = Cgt.Runtime.List_at; args = l :: _ } -> (
              match address l with Some a when not (List.mem a !lists) -> lists := a :: !lists | _ -> ())
          | _ -> ())
        ignore body;
      (List.rev !lists, names)
    end

(* Experimental (docs/experiments/goose-comparison): with
   ZANE_LOOP_RANGES=1 as well, the element reads and writes of a loop's
   [body] whose list [invariant_lists] found and whose index moves by a
   constant -1, 0 or 1 each time round: each with that step and its index's
   value on the first time round, as an expression of what is known before
   the loop. The index's last value is then its first plus the step times
   one less than the count, and between them it passes through every value
   once, so the loop checks the two ends before it starts and, when both are
   in range, runs a copy of itself that checks none of these.

   The step is found from the body's last statement, which assigns the
   loop's counter its value plus a constant ([Repeat] of `to`): a local
   assigned nowhere else in the body. A local the body binds once is its
   value, and an expansion's result, assigned once among the first
   statements of its body, is that value. *)
let ranged body lists names =
  if Sys.getenv_opt "ZANE_LOOP_RANGES" <> Some "1" || lists = [] then []
  else
    let lets = Hashtbl.create 16 and assigns = Hashtbl.create 16 and defined = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats ignore
      (function
        | Stat.Let { id; value } ->
            Hashtbl.replace lets id value;
            Hashtbl.replace defined id ()
        | Stat.Hold { id; _ } | Stat.Reserve { id; _ } -> Hashtbl.replace defined id ()
        | Stat.Assign { place; value } -> Hashtbl.add assigns place.Expr.local (place, value)
        | _ -> ())
      body;
    let results = Hashtbl.create 16 in
    Cgt.Traverse.walk_stats
      (fun e ->
        match e.Expr.node with
        | Expr.Expand { body = eb; result = Some r; _ } ->
            let rec first = function
              | Stat.Let _ :: rest -> first rest
              | Stat.Assign { place = { Expr.local; path = []; deref = false; _ }; value } :: _ when local = r ->
                  Hashtbl.replace results r value
              | _ -> ()
            in
            first eb
        | _ -> ())
      ignore body;
    let i64 node = { Expr.node; ty = Ty.I64 } in
    let rec affine counter (e : Expr.t) =
      match e.Expr.node with
      | Expr.Int k -> Some (0, e)
      | Expr.Local y -> (
          match counter with
          | Some (x, step) when x = y -> Some (step, e)
          | _ -> (
              match (Hashtbl.find_all assigns y, Hashtbl.find_opt lets y) with
              | [], None -> if Hashtbl.mem defined y then None else Some (0, e)
              | [], Some v -> affine counter v
              | [ _ ], None when Hashtbl.mem results y -> affine counter (Hashtbl.find results y)
              | _ -> None))
      | Expr.Expand { result = Some r; _ } -> affine counter (i64 (Expr.Local r))
      | Expr.Binary { op = Expr.Add; left; right } -> (
          match (affine counter left, affine counter right) with
          | Some (a, l), Some (c, r) -> Some (a + c, i64 (Expr.Binary { op = Expr.Add; left = l; right = r }))
          | _ -> None)
      | Expr.Binary { op = Expr.Mul; left; right } -> (
          match (affine counter left, affine counter right) with
          | Some (a, l), Some (0, ({ Expr.node = Expr.Int k; _ } as r))
          | Some (0, ({ Expr.node = Expr.Int k; _ } as r)), Some (a, l) ->
              Some (a * Int64.to_int k, i64 (Expr.Binary { op = Expr.Mul; left = l; right = r }))
          | _ -> None)
      | Expr.Flip v -> Option.map (fun (a, base) -> (-a, i64 (Expr.Flip base))) (affine counter v)
      | _ -> None
    in
    let counter =
      match List.rev body with
      | Stat.Assign { place = { Expr.local = x; path = []; deref = false; _ }; value } :: _
        when List.length (Hashtbl.find_all assigns x) = 1 && not (Hashtbl.mem defined x) -> (
          match affine (Some (x, 0)) value with
          | Some (0, { Expr.node = Expr.Binary { op = Expr.Add; left = { Expr.node = Expr.Local y; _ }; right = { Expr.node = Expr.Int c; _ } }; _ })
            when y = x ->
              Some (x, Int64.to_int c)
          | _ -> None)
      | _ -> None
    in
    match counter with
    | Some (_, step) when abs step <= 1 ->
        let found = ref [] in
        Cgt.Traverse.walk_stats
          (fun e ->
            match e.Expr.node with
            | Expr.Runtime { fn = Cgt.Runtime.List_at; args = [ l; index; _ ] } -> (
                let key = match l.Expr.node with Expr.Local x -> Option.value ~default:l (Hashtbl.find_opt names x) | _ -> l in
                match affine counter index with
                | Some (a, first) when abs a <= 1 && List.mem key lists -> found := (e, key, a, first) :: !found
                | _ -> ())
            | _ -> ())
          ignore body;
        !found
    | _ -> []

(* A slot in its scope's frame, where Frames put it. *)
let frame_slot env fr b scope id =
  byte_at env b (Hashtbl.find fr.arenas scope) (Hashtbl.find fr.offsets id)

(* With checked drains, a slot whose value may own blocks is listed as its
   value arrives, so the drain can return them (runtime/slot.c). *)
let hold env fr b slot l =
  if listed env l then begin
    let on =
      Llvm.build_icmp Llvm.Icmp.Ne
        (Llvm.build_load (Llvm.i32_type env.ctx) (checking env) "" b)
        (Llvm.const_int (Llvm.i32_type env.ctx) 0)
        "" b
    in
    let listing = block env fr and after = block env fr in
    unlikely env (Llvm.build_cond_br on listing after b);
    Llvm.position_at_end listing b;
    ignore (call_runtime env b Cgt.Runtime.Hold [| slot; layout env l |]);
    ignore (Llvm.build_br after b);
    Llvm.position_at_end after b
  end

(* Every local is a stack slot in the entry block (L3); LLVM's `mem2reg`
   promotes the ones that can live in registers. *)
let alloca env fr t =
  let top = Llvm.builder_at env.ctx (Llvm.instr_begin (Llvm.entry_block fr.fn)) in
  Llvm.build_alloca t "" top

let slot env fr id t =
  let s = alloca env fr t in
  Hashtbl.replace fr.locals id (s, t);
  s

(* A value of type [t] moved into a fresh place: stored, tagged as [access]
   tags it, and the blocks it owns that the place's region outlives move
   into it (memory.md §3.5). *)
let place env b t p v l =
  (match t with
  (* Experimental (Loop_pushes, unless ZANE_LOOP_PUSHES=0): a struct of scalars is stored member
     by member, each tagged as a scalar, so that LLVM knows the stores never
     touch a list's handle and can keep its count in a register through a
     loop of pushes. *)
  | Ty.Struct ts
    when Sys.getenv_opt "ZANE_LOOP_PUSHES" <> Some "0"
         && List.for_all (function Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> true | _ -> false) ts ->
      List.iteri
        (fun i m ->
          let at = Llvm.build_struct_gep (lltype env t) p i "" b in
          ignore (access env m (Llvm.build_store (Llvm.build_extractvalue v i "" b) at b)))
        ts
  | _ -> ignore (access env t (Llvm.build_store v p b)));
  if listed env l then ignore (call_runtime env b Cgt.Runtime.Arrive [| p; layout env l |])

(* A value stored where its address can be passed. *)
let spill env fr b v =
  let p = alloca env fr (Llvm.type_of v) in
  ignore (Llvm.build_store v p b);
  p

let has_terminator b =
  match Llvm.block_terminator (Llvm.insertion_block b) with Some _ -> true | None -> false

(* How a snapshot of a value of type [t] is read (§9). An 8-byte value
   aligned to 8 is one load: a write-back stores those 8 bytes in a single
   store of the same 8 bytes (runtime/snapshot.c), since its pieces are
   aligned blocks of at most 8 and no smaller place lies inside such a value
   for a write-back to target, so the load is the snapshot. A narrower value
   can sit inside a wider piece a write-back stores whole, an access of
   another size that LLVM gives no atomicity with it, so it is read by the
   runtime. A value that holds an address,
   such as a box's, is read with acquire ordering, so what the address names,
   written before the write-back's release fence published it, is seen with
   it; one that holds none needs only `unordered`, which LLVM moves and
   merges like a plain load. A wider value is read by the runtime,
   which retries a torn read and fences the same way. *)
let snapshot_read t =
  let rec names_block = function
    | Ty.Ptr | Ty.Ref | Ty.Box32 | Ty.Handle | Ty.Handle16 -> true
    | Ty.Struct ts | Ty.Sum ts -> List.exists names_block ts
    | Ty.Array (t, _) | Ty.Packed t -> names_block t
    | Ty.Void | Ty.I1 | Ty.I32 | Ty.I64 | Ty.F32 | Ty.F64 -> false
  in
  if size_align t <> (8, 8) then `Runtime
  else if names_block t then `Acquire
  else `Unordered

(* The address of a list's or an array's element, counted from 1, checked
   against its count here rather than in the runtime, so LLVM sees the count,
   the index and the address the way it sees any arithmetic. Only an index
   outside calls the runtime, which stops the program (§9). One unsigned
   compare of the index less one covers both ends. *)
let element ?cached ?(unchecked = false) env fr b fn args =
  let base, index, count, stride =
    match (fn, args, cached) with
    | Cgt.Runtime.List_at, [ _; index; stride ], Some (items, count) -> (items, index, count, stride)
    | Cgt.Runtime.List_at, [ list; index; stride ], None ->
        let tag = handle_field env and count_tag = if List_handle.on () then handle_field env else count_field env in
        (List_handle.items ~tag env.ctx b list, index, List_handle.count ~tag:count_tag env.ctx b list, stride)
    | Cgt.Runtime.Array_at, [ array; index; count; stride ], _ -> (array, index, count, stride)
    | _ -> Diagnostic.bug "codegen: an element address with the wrong arguments"
  in
  let offset = Llvm.build_sub index (Llvm.const_int env.i64 1) "" b in
  if unchecked then Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) base [| Llvm.build_nsw_mul offset stride "" b |] "" b
  else
  let outside = Llvm.build_icmp Llvm.Icmp.Uge offset count "" b in
  let stop = block env fr and inside = block env fr in
  ignore (Llvm.build_cond_br outside stop inside b);
  Llvm.position_at_end stop b;
  let f, fty = runtime env Cgt.Runtime.Out_of_range in
  ignore (Llvm.build_call fty f [||] "" b);
  ignore (Llvm.build_unreachable b);
  Llvm.position_at_end inside b;
  let bytes = Llvm.build_nsw_mul offset stride "" b in
  Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) base [| bytes |] "" b

(* Whether the address [p] is, by how it was made, in the innermost scope's
   region while that scope is open: a slot of the function's innermost
   frame, or of its machine stack, which the runtime counts as the
   innermost scope's (runtime/arena.c). Anything else is found at run time. *)
let innermost fr p =
  let rec base v =
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> base (Llvm.operand v 0)
    | _ -> v
  in
  let p = base p in
  (match Llvm.classify_value p with Llvm.ValueKind.Instruction Llvm.Opcode.Alloca -> true | _ -> false)
  || match fr.open_ with frame :: _ -> p == frame | [] -> false

(* An empty list's first block of [first] bytes, made here when its handle
   holds no block (its room is 0, as runtime/list.c reads it: the push's
   fast path loads the room already, while a look at the items would load
   them ahead of its check) and is in the innermost scope's region, the
   open one, as the runtime would make it (runtime/list.c): the top of the
   scope's size class of [first] bytes when it holds a returned block; else
   the next word-aligned bytes in the scope's heap when it has them; or,
   when nothing has yet been allocated in the scope, the first word-aligned
   bytes past its frame, which stretches by ZANE_STRETCH bytes for them. The handle is checked to be in
   the frame unless [innermost] knows it is in the scope's region already.
   Any check that fails goes to [fail]; otherwise the push is made and the
   element's address is returned. *)
(* The bytes of a list's first block when its first push asks for [bytes]
   of elements [stride] wide, as runtime/list.c sizes it. *)
let first_room ~bytes ~stride =
  let room = min Abi.list_first (max Abi.list_least (4 * stride)) in
  let room = (max room bytes + 7) / 8 * 8 in
  (* Counted in elements, the block is the bytes of the whole elements that
     fit, which runtime/list.c takes too. *)
  List_handle.block_bytes ~room:(List_handle.units ~bytes:room ~stride) ~stride

let first_block env fr b ~header ~list ~fail ~first ~stride =
  let ptr = env.ptr and i64 = env.i64 in
  let n x = Llvm.const_int i64 x in
  let check cond =
    let next = block env fr in
    ignore (Llvm.build_cond_br cond next fail b);
    Llvm.position_at_end next b
  in
  let address p = Llvm.build_ptrtoint p i64 "" b in
  let aligned p =
    Llvm.build_and
      (Llvm.build_add p (n (Abi.list_align - 1)) "" b)
      (Llvm.const_of_int64 i64 (Int64.of_int (-Abi.list_align)) true)
      "" b
  in
  ignore header;
  let room = List_handle.room ~tag:(handle_field env) env.ctx b list in
  check (Llvm.build_icmp Llvm.Icmp.Eq room (n 0) "" b);
  let m = Llvm.build_load ptr (open_scope env) "" b in
  check (Llvm.build_icmp Llvm.Icmp.Ne m (Llvm.const_null ptr) "" b);
  let c = field env b ptr m record_context in
  let record = address m in
  if not (innermost fr list) then begin
    let at = address list in
    let from = address (field env b ptr c context_frontier) in
    check
      (Llvm.build_and
         (Llvm.build_icmp Llvm.Icmp.Uge at record "" b)
         (Llvm.build_icmp Llvm.Icmp.Ult at from "" b)
         "" b)
  end;
  let class_at = byte_at env b m (8 * ((first / 8) - 1)) in
  let top = Llvm.build_load ptr class_at "" b in
  let pop = block env fr and look = block env fr in
  let fresh = block env fr and used = block env fr and taken = block env fr and bumped = block env fr in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Ne top (Llvm.const_null ptr) "" b) pop look b);
  Llvm.position_at_end pop b;
  ignore (Llvm.build_store (Llvm.build_load ptr top "" b) class_at b);
  ignore (Llvm.build_br taken b);
  Llvm.position_at_end look b;
  let bump = field env b ptr m Walks.frontier in
  ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Eq bump (Llvm.const_null ptr) "" b) fresh used b);
  Llvm.position_at_end used b;
  let start_used = aligned (address bump) in
  let ends = address (field env b ptr m Walks.frontier_end) in
  check (Llvm.build_icmp Llvm.Icmp.Ule (Llvm.build_add start_used (n first) "" b) ends "" b);
  let used_end = Llvm.insertion_block b in
  ignore (Llvm.build_br bumped b);
  Llvm.position_at_end fresh b;
  let frontier = field env b ptr c context_frontier in
  let stretched = byte_at env b frontier Abi.stretch in
  check (Llvm.build_icmp Llvm.Icmp.Ule (Llvm.build_sub (address stretched) record "" b) (n Abi.stretched) "" b);
  check (Llvm.build_icmp Llvm.Icmp.Ule (address stretched) (address (field env b ptr c context_limit)) "" b);
  set_field env b stretched c context_frontier;
  set_field env b stretched m Walks.frontier_end;
  let start_fresh = aligned (address frontier) in
  let fresh_end = Llvm.insertion_block b in
  ignore (Llvm.build_br bumped b);
  Llvm.position_at_end bumped b;
  let start = Llvm.build_phi [ (start_used, used_end); (start_fresh, fresh_end) ] "" b in
  let start = Llvm.build_inttoptr start ptr "" b in
  set_field env b (byte_at env b start first) m Walks.frontier;
  ignore (Llvm.build_br taken b);
  Llvm.position_at_end taken b;
  let start = Llvm.build_phi [ (top, pop); (start, bumped) ] "" b in
  let live = field env b i64 m Walks.live in
  set_field env b (Llvm.build_add live (n 1) "" b) m Walks.live;
  let tag = handle_field env in
  List_handle.set_items ~tag env.ctx b start list;
  List_handle.set_count ~tag env.ctx b (n 1) list;
  List_handle.set_room ~tag env.ctx b (n (List_handle.units ~bytes:first ~stride)) list;
  start

(* Room for one more element at the end of a list, [stride] bytes wide: the
   address the element is then moved into. While the list's block has room,
   the push is made here, so LLVM sees the count and the address the way it
   sees any arithmetic, and so is an empty list's first block in the
   innermost scope ([first_block]) in a function with a scope of its own
   open; otherwise the runtime grows the block and makes the push (§9). A
   function with none keeps the call, so its code stays small enough for
   LLVM to unroll a loop of a few pushes, as a recursive build makes.

   The first push of a run ([runs]) makes room for the [ahead] pushes of
   the run, its own and those after it, and each of the others is made
   [unchecked], with no look at the room at all. *)
let push env fr b ?(ahead = 1) ?(unchecked = false) list stride =
  let header = List_handle.header env.ctx in
  let tag = handle_field env in
  let count = List_handle.count ~tag env.ctx b list in
  let room = List_handle.room ~tag env.ctx b list in
  let next = Llvm.build_nsw_add count (Llvm.const_int env.i64 1) "" b in
  let in_room () =
    let items = List_handle.items ~tag env.ctx b list in
    let offset = Llvm.build_nsw_mul count stride "" b in
    let at = Llvm.build_in_bounds_gep (Llvm.i8_type env.ctx) items [| offset |] "" b in
    List_handle.set_count ~tag env.ctx b next list;
    at
  in
  if unchecked then in_room ()
  else
    let wanted =
      if ahead = 1 then next else Llvm.build_nsw_add count (Llvm.const_int env.i64 ahead) "" b
    in
    let full =
      if List_handle.elements () then Llvm.build_icmp Llvm.Icmp.Sgt wanted room "" b
      else Llvm.build_icmp Llvm.Icmp.Sgt (Llvm.build_nsw_mul wanted stride "" b) room "" b
    in
    let grow = block env fr and fits = block env fr and pushed = block env fr in
    unlikely env (Llvm.build_cond_br full grow fits b);
    Llvm.position_at_end fits b;
    let at = in_room () in
    ignore (Llvm.build_br pushed b);
    Llvm.position_at_end grow b;
    let runtime_ = block env fr in
    let firsts =
      match Llvm.int64_of_const stride with
      | Some s when s >= 1L && Int64.mul s (Int64.of_int ahead) <= Int64.of_int Abi.list_first && fr.open_ <> [] ->
          let first = first_room ~bytes:(Int64.to_int s * ahead) ~stride:(Int64.to_int s) in
          let made = first_block env fr b ~header ~list ~fail:runtime_ ~first ~stride:(Int64.to_int s) in
          let made_end = Llvm.insertion_block b in
          ignore (Llvm.build_br pushed b);
          [ (made, made_end) ]
      | _ ->
          ignore (Llvm.build_br runtime_ b);
          []
    in
    Llvm.position_at_end runtime_ b;
    let grown =
      if ahead = 1 then
        let f, fty = runtime env Cgt.Runtime.List_push in
        Llvm.build_call fty f [| list; stride |] "" b
      else
        let f, fty = runtime env Cgt.Runtime.List_reserve in
        Llvm.build_call fty f [| list; stride; Llvm.const_int env.i64 ahead |] "" b
    in
    (* The paths above are the runtime's own fast ones, so its body would
       only repeat them here (Runtime_bodies). *)
    Llvm.add_call_site_attr grown
      (Llvm.create_enum_attr env.ctx "noinline" 0L)
      Llvm.AttrIndex.Function;
    ignore (Llvm.build_br pushed b);
    Llvm.position_at_end pushed b;
    Llvm.build_phi ((at, fits) :: (grown, runtime_) :: firsts) "" b

(* Whether [s] names the local [id] anywhere in it, a spawned call's result
   coming home to it included. *)
let names id s =
  Cgt.Traverse.exists_in [ s ]
    ~expr:(fun e -> match e.Expr.node with Expr.Local l | Expr.Address l -> l = id | _ -> false)
    ~stat:(function
      | Stat.Assign { place; _ } -> place.Expr.local = id
      | Stat.Let { id = l; _ } | Stat.Hold { id = l; _ } | Stat.Reserve { id = l; _ } -> l = id
      | Stat.Spawn { dest; _ } -> dest = Some id
      | _ -> false)

let new_list (e : Expr.t) =
  match e.Expr.node with Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] } -> true | _ -> false

(* Whether [e] makes a new list: the runtime's call, or an expansion that
   assigns it to its result and does nothing else. *)
let fresh_list (e : Expr.t) =
  match e.Expr.node with
  | Expr.Expand
      {
        body = [ Stat.Assign { place = { Expr.local; path = []; deref = false; _ }; value } ];
        result = Some r;
        _;
      } ->
      local = r && new_list value
  | _ -> new_list e

(* The stride of [s] when it is one push onto the list in [id]: an
   expansion whose own body makes the push, after nothing that may leave
   it, and names the list nowhere else. *)
let leaving ss =
  Cgt.Traverse.exists_in ss ~expr:(fun _ -> false) ~stat:(function
    | Stat.Leave _ | Stat.Return _ -> true
    | _ -> false)

let push_of id (s : Stat.t) =
  match s with
  | Stat.Eval { Expr.node = Expr.Expand { body; _ }; _ } ->
      let rec go before = function
        | Stat.Let
            {
              value =
                {
                  Expr.node =
                    Expr.Runtime
                      {
                        fn = Cgt.Runtime.List_push;
                        args = [ { Expr.node = Expr.Address l; _ }; { Expr.node = Expr.Int stride; _ } ];
                      };
                  _;
                };
              _;
            }
          :: after
          when l = id ->
            if List.exists (names id) (before @ after) || leaving before then None else Some stride
        | s :: rest -> go (s :: before) rest
        | [] -> None
      in
      go [] body
  | _ -> None

(* The runs of pushes in [body], each as the list's local and the pushes in
   it, when they are two or more: a new list's statement, then the pushes
   onto it that follow in [body] up to the first other statement that names
   it or may leave. Nothing else can reach a new list, so only those pushes add to it
   in the run, each at most once, and the run's first push, which comes
   before every other, can make room for all of them. *)
let runs body =
  let rec length id n = function
    | s :: rest -> (
        match push_of id s with
        | Some _ -> length id (n + 1) rest
        | None -> if names id s || leaving [ s ] then n else length id n rest)
    | [] -> n
  in
  let rec scan acc = function
    | (Stat.Hold { id; value; _ } | Stat.Let { id; value }) :: rest when fresh_list value ->
        let n = length id 0 rest in
        scan (if n >= 2 then (id, n) :: acc else acc) rest
    | _ :: rest -> scan acc rest
    | [] -> acc
  in
  scan [] body

(* Experimental (Loop_pushes, unless ZANE_LOOP_PUSHES=0): the lists a loop's
   [body] pushes onto once each time round, each with its stride: a push
   among [body]'s statements, unconditional, onto a list no other
   statement of [body] names. Room for every time round is made before the
   loop, and each push is then a plain store. *)
(* Whether [s] may change some list's count other than through its own
   local: a call of a function that may (Cgt.List_pure), which may be handed
   a reference to it, a spawned call, or the runtime pushing, making room in
   or removing from a list, which may be the same list reached through a
   reference. Room made for a loop's pushes would be taken by any of them. *)
let may_grow s =
  Cgt.Traverse.exists_in [ s ]
    ~expr:(fun e ->
      match e.Expr.node with
      | Expr.Call { fn; _ } -> not (Hashtbl.mem Cgt.List_pure.functions fn)
      | Expr.Call_value _ -> true
      | Expr.Runtime { fn; _ } -> (
          match fn with
          | Cgt.Runtime.List_push | List_room | List_reserve | List_remove _ | List_swap_remove _ | Overwrite | Copy
          | Promote | Arrive ->
              true
          | _ -> false)
      | _ -> false)
    ~stat:(function Stat.Spawn _ | Stat.Join _ | Stat.Overwrite _ -> true | _ -> false)

let looped_pushes body =
  if Sys.getenv_opt "ZANE_LOOP_PUSHES" = Some "0" then []
  else
    let lists =
      List.sort_uniq compare
        (List.filter_map
           (function
             | Stat.Eval { Expr.node = Expr.Expand { body; _ }; _ } ->
                 List.find_map
                   (function
                     | Stat.Let
                         {
                           value =
                             {
                               Expr.node =
                                 Expr.Runtime { fn = Cgt.Runtime.List_push; args = { Expr.node = Expr.Address l; _ } :: _ };
                               _;
                             };
                           _;
                         } ->
                         Some l
                     | _ -> None)
                   body
             | _ -> None)
           body)
    in
    List.filter_map
      (fun id ->
        match List.partition (fun s -> Option.is_some (push_of id s)) body with
        | [ s ], rest when not (List.exists (names id) rest || List.exists may_grow rest) ->
            Option.map (fun stride -> (id, stride)) (push_of id s)
        | _ -> None)
      lists

let remove env fr b fn list index stride =
  let i8 = Llvm.i8_type env.ctx and one = Llvm.const_int env.i64 1 in
  let tag = handle_field env in
  let count = List_handle.count ~tag env.ctx b list in
  let items = List_handle.items ~tag env.ctx b list in
  let slot n = Llvm.build_in_bounds_gep i8 items [| Llvm.build_nsw_mul n stride "" b |] "" b in
  let at = slot (Llvm.build_nsw_sub index one "" b) in
  let move name dst src size =
    let i1 = Llvm.i1_type env.ctx in
    let t = Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr; env.ptr; env.i64; i1 |] in
    let f =
      match Llvm.lookup_function name env.m with
      | Some f -> f
      | None -> Llvm.declare_function name t env.m
    in
    let moved = Llvm.build_call t f [| dst; src; size; Llvm.const_int i1 0 |] "" b in
    match fn with
    | Cgt.Runtime.List_remove { scalars = true } | Cgt.Runtime.List_swap_remove { scalars = true } ->
        Llvm.set_metadata moved (Llvm.mdkind_id env.ctx "tbaa") env.value_tag
    | _ -> ()
  in
  (match fn with
  | Cgt.Runtime.List_remove _ -> (
      let later = Llvm.build_nsw_mul (Llvm.build_nsw_sub count index "" b) stride "" b in
      let from = Llvm.build_in_bounds_gep i8 at [| stride |] "" b in
      (* A move of more than 4 KiB by less than 64 bytes is made 2 KiB at a
         time, lowest first, so that glibc copies each piece with its vector
         loop rather than `rep movsb`, which it takes from 4 KiB on with
         AVX2 and which some Intel processors run at a byte a cycle when the
         source is that close past the destination (runtime/list.c,
         `zane_shift_down`). Each piece writes below what the next reads. *)
      match Llvm.int64_of_const stride with
      | Some s when s < 64L ->
          let piece = Llvm.const_int env.i64 2048 in
          let large = Llvm.build_icmp Llvm.Icmp.Sgt later (Llvm.const_int env.i64 4096) "" b in
          let entry = Llvm.insertion_block b in
          let pieces = block env fr and small = block env fr and moved = block env fr in
          ignore (Llvm.build_cond_br large pieces small b);
          Llvm.position_at_end pieces b;
          let i = Llvm.build_phi [ (Llvm.const_int env.i64 0, entry) ] "" b in
          let rest = Llvm.build_sub later i "" b in
          let size = Llvm.build_select (Llvm.build_icmp Llvm.Icmp.Slt rest piece "" b) rest piece "" b in
          move "llvm.memmove.p0.p0.i64" (Llvm.build_gep i8 at [| i |] "" b) (Llvm.build_gep i8 from [| i |] "" b) size;
          let next = Llvm.build_add i piece "" b in
          Llvm.add_incoming (next, Llvm.insertion_block b) i;
          ignore (Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt next later "" b) pieces moved b);
          Llvm.position_at_end small b;
          move "llvm.memmove.p0.p0.i64" at from later;
          ignore (Llvm.build_br moved b);
          Llvm.position_at_end moved b
      | _ -> move "llvm.memmove.p0.p0.i64" at from later)
  | _ ->
      let before = Llvm.build_icmp Llvm.Icmp.Slt index count "" b in
      let moving = block env fr and moved = block env fr in
      ignore (Llvm.build_cond_br before moving moved b);
      Llvm.position_at_end moving b;
      move "llvm.memcpy.p0.p0.i64" at (slot (Llvm.build_nsw_sub count one "" b)) stride;
      ignore (Llvm.build_br moved b);
      Llvm.position_at_end moved b);
  List_handle.set_count ~tag env.ctx b (Llvm.build_nsw_sub count one "" b) list

(* ---------------------------------------------------------------------- *)
(* Arithmetic                                                             *)
(* ---------------------------------------------------------------------- *)

(* LLVM leaves an integer division by zero undefined, and the one quotient an
   integer cannot hold too. The first gives zero and the second wraps, as `+`
   and `*` do (operators.md §2.6). Both divisors, 0 and -1, are the two that
   `r + 1` takes below 2 unsigned, and they branch away to an unlikely block,
   so the [sdiv] sees neither and starts without waiting on the test. *)
let divide env fr b l r =
  let t = Llvm.type_of l in
  let zero = Llvm.const_int t 0 and one = Llvm.const_int t 1 in
  let special = block env fr and ordinary = block env fr and joined = block env fr in
  let exceptional = Llvm.build_icmp Llvm.Icmp.Ult (Llvm.build_add r one "" b) (Llvm.const_int t 2) "" b in
  unlikely env (Llvm.build_cond_br exceptional special ordinary b);
  Llvm.position_at_end ordinary b;
  let quotient = Llvm.build_sdiv l r "" b in
  ignore (Llvm.build_br joined b);
  Llvm.position_at_end special b;
  let by_zero = Llvm.build_icmp Llvm.Icmp.Eq r zero "" b in
  let replaced = Llvm.build_select by_zero zero (Llvm.build_sub zero l "" b) "" b in
  ignore (Llvm.build_br joined b);
  Llvm.position_at_end joined b;
  Llvm.build_phi [ (quotient, ordinary); (replaced, special) ] "" b

(* A scalar converted from [from] to [into] (Cgt.Nodes.Scalar). A float
   truncated to an integer saturates (types.md §2.9): a NaN gives zero, and
   one whose integer part the target cannot hold gives the target's nearest
   end. That is what LLVM's `llvm.fptosi.sat` gives, so the target's own
   saturating conversion is what runs. *)
let convert env b (from : Ty.t) (into : Ty.t) v =
  let target = lltype env into in
  let is_float = function Ty.F32 | Ty.F64 -> true | _ -> false in
  match (from, into) with
  (* Experimental (Ref32): a box's block stored in 32 bits, and back. *)
  | Ty.Ptr, Ty.Ref -> List_handle.encode env.ctx b v
  | Ty.Ref, Ty.Ptr -> List_handle.decode env.ctx b v
  | Ty.Ptr, Ty.Box32 -> List_handle.encode_box env.ctx b v
  | Ty.Box32, Ty.Ptr -> List_handle.decode_box env.ctx b v
  | _ -> (
  match (is_float from, is_float into) with
  | false, false ->
      if Scalar.bits from < Scalar.bits into then Llvm.build_sext v target "" b
      else if Scalar.bits from > Scalar.bits into then Llvm.build_trunc v target "" b
      else v
  | false, true -> Llvm.build_sitofp v target "" b
  | true, true -> (
      match (from, into) with
      | Ty.F32, Ty.F64 -> Llvm.build_fpext v target "" b
      | Ty.F64, Ty.F32 -> Llvm.build_fptrunc v target "" b
      | _ -> v)
  | true, false ->
      let suffix = function Ty.I32 -> "i32" | Ty.I64 -> "i64" | Ty.F32 -> "f32" | _ -> "f64" in
      let name = Printf.sprintf "llvm.fptosi.sat.%s.%s" (suffix into) (suffix from) in
      let fty = Llvm.function_type target [| Llvm.type_of v |] in
      let f =
        match Llvm.lookup_function name env.m with
        | Some f -> f
        | None -> Llvm.declare_function name fty env.m
      in
      Llvm.build_call fty f [| v |] "" b)

let binary env fr b (op : Expr.binop) (t : Ty.t) l r =
  match (t, op) with
  | (Ty.I64 | Ty.I32), Expr.Add -> Llvm.build_add l r "" b
  | (Ty.I64 | Ty.I32), Expr.Mul -> Llvm.build_mul l r "" b
  | (Ty.I64 | Ty.I32), Expr.Div -> divide env fr b l r
  | (Ty.I64 | Ty.I32 | Ty.I1), Expr.Eq -> Llvm.build_icmp Llvm.Icmp.Eq l r "" b
  | (Ty.I64 | Ty.I32), Expr.Less -> Llvm.build_icmp Llvm.Icmp.Slt l r "" b
  | (Ty.F64 | Ty.F32), Expr.Add -> Llvm.build_fadd l r "" b
  | (Ty.F64 | Ty.F32), Expr.Mul -> Llvm.build_fmul l r "" b
  | (Ty.F64 | Ty.F32), Expr.Div -> Llvm.build_fdiv l r "" b
  | (Ty.F64 | Ty.F32), Expr.Eq -> Llvm.build_fcmp Llvm.Fcmp.Oeq l r "" b
  | (Ty.F64 | Ty.F32), Expr.Less -> Llvm.build_fcmp Llvm.Fcmp.Olt l r "" b
  | Ty.I1, Expr.Add -> Llvm.build_or l r "" b
  | Ty.I1, Expr.Mul -> Llvm.build_and l r "" b
  | _ ->
      Diagnostic.bug
        (Printf.sprintf "codegen: no `%s` on %s" (Expr.binop_to_string op) (Ty.to_string t))

(* ---------------------------------------------------------------------- *)
(* Expressions and statements                                             *)
(* ---------------------------------------------------------------------- *)

(* An expression that has a value: anything but a [Void] one, which lowering
   never puts where a value is used. *)
let rec value_of env fr b (e : Expr.t) : Llvm.llvalue =
  match expr env fr b e with
  | Some v -> v
  | None ->
      Diagnostic.bug
        (Printf.sprintf "codegen: a %s of type %s has no value" (Expr.kind e.Expr.node)
           (Ty.to_string e.Expr.ty))

and expr env fr b (e : Expr.t) : Llvm.llvalue option =
  match e.Expr.node with
  | Expr.Int i -> Some (Llvm.const_of_int64 (lltype env e.Expr.ty) i true)
  | Expr.Offset { base; within; path } ->
      let base = value_of env fr b base in
      (* A place inside a packed type may be at any byte: its address is
         named so that `unaligned` marks what reads and writes it. *)
      let gep t p i =
        let packed = (match t with Ty.Packed _ -> true | _ -> false) || is_unaligned p in
        Llvm.build_struct_gep (lltype env t) p i (if packed then unaligned_name else "") b
      in
      let at, _ =
        List.fold_left
          (fun (p, t) i ->
            match t with
            | Ty.Struct ts | Ty.Packed (Ty.Struct ts) -> (gep t p i, List.nth ts i)
            (* A sum's payload room holds case [i]'s payload. *)
            | (Ty.Sum ts | Ty.Packed (Ty.Sum ts)) when List.nth ts i = Ty.Void -> (p, Ty.Void)
            | Ty.Sum ts when Ty.niche ts -> (gep t p 0, List.nth ts i)
            | Ty.Sum ts | Ty.Packed (Ty.Sum ts) -> (gep t p 1, List.nth ts i)
            | _ -> Diagnostic.bug "codegen: an offset through something not a struct")
          (base, within) path
      in
      Some at
  | Expr.Take { address; layout = l } -> (
      let p = value_of env fr b address in
      match e.Expr.ty with
      | Ty.Void -> None
      | t ->
          let v = Llvm.build_load (lltype env t) p "" b in
          Option.iter
            (fun f ->
              ignore
                (Llvm.build_call
                   (Llvm.function_type (Llvm.void_type env.ctx) [| env.ptr |])
                   f [| p |] "" b))
            (Walks.vacater (walks env) l);
          Some v)
  | Expr.Copy { value; layout = l } ->
      Option.map
        (fun v ->
          let p = spill env fr b v in
          if listed env l then ignore (call_runtime env b Cgt.Runtime.Copy [| p; layout env l |]);
          Llvm.build_load (Llvm.type_of v) p "" b)
        (expr env fr b value)
  (* A box and a hold are made in the innermost region, which every block
     the value they take owns already outlives: it was made in this scope or
     an enclosing one, or lent by the call that spawned this context, which
     waits for it. So nothing arrives (memory.md §3.5). *)
  | Expr.Box { value; _ } ->
      let size, align = size_align value.Expr.ty in
      let block = Walks.box (walks env).Walks.emitting fr.fn b size align in
      Option.iter (fun v -> ignore (Llvm.build_store v block b)) (expr env fr b value);
      Some block
  | Expr.Layout l -> Some (layout env l)
  | Expr.Function fn -> Some (fst (Hashtbl.find env.funcs fn))
  | Expr.Global g -> Some (Hashtbl.find env.globals g)
  | Expr.Snapshot p -> (
      let p = value_of env fr b p in
      match e.Expr.ty with
      | Ty.Void -> None
      | t ->
          let lt = lltype env t in
          let out = alloca env fr lt in
          let size = fst (size_align t) in
          (match snapshot_read t with
          | (`Unordered | `Acquire) as order ->
              let word = Llvm.build_load (Llvm.integer_type env.ctx (8 * size)) p "" b in
              Llvm.set_alignment size word;
              set_ordering word (order = `Acquire);
              ignore (Llvm.build_store word out b)
          | `Runtime ->
              ignore
                (call_runtime env b Cgt.Runtime.Snapshot
                   [| out; p; Llvm.const_int env.i64 size |]));
          Some (Llvm.build_load lt out "" b))
  | Expr.Escape { value; layout = l; exit } -> (
      (* The arenas the exit drains are the innermost ones: all of the
         function's, or those opened since the expansion began. *)
      let kept = match exit with None -> 0 | Some label -> snd (Hashtbl.find fr.labels label) in
      let drained = List.filteri (fun i _ -> i < List.length fr.open_ - kept) fr.open_ in
      match (expr env fr b value, List.rev drained) with
      | Some v, outermost :: _ when listed env l ->
          let p = spill env fr b v in
          ignore (call_runtime env b Cgt.Runtime.Promote [| p; layout env l; outermost |]);
          Some (Llvm.build_load (Llvm.type_of v) p "" b)
      | v, _ -> v)
  | Expr.Float f -> Some (Llvm.const_float (lltype env e.Expr.ty) f)
  | Expr.Bool v -> Some (Llvm.const_int (Llvm.i1_type env.ctx) (if v then 1 else 0))
  | Expr.Text s -> Some (text env s)
  | Expr.Unit -> None
  | Expr.Local id ->
      Option.map (fun (slot, t) -> Llvm.build_load t slot "" b) (Hashtbl.find_opt fr.locals id)
  | Expr.Address id -> (
      match Hashtbl.find_opt fr.locals id with
      | Some (slot, _) -> Some slot
      | None -> Some (Llvm.const_null env.ptr))
  | Expr.Deref p -> (
      let p = expr env fr b p in
      match (e.Expr.ty, p) with
      | Ty.Void, _ | _, None -> None
      | t, Some p -> Some (access env t (Llvm.build_load (lltype env t) p "" b)))
  | Expr.Record members ->
      Some
        (List.fold_left
           (fun v (i, m) ->
             match expr env fr b m with Some x -> Llvm.build_insertvalue v x i "" b | None -> v)
           (Llvm.undef (lltype env e.Expr.ty))
           members)
  | Expr.Member { value; index } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | _, Some v -> Some (Llvm.build_extractvalue v index "" b))
  | Expr.Case { index; payload } when (match e.Expr.ty with Ty.Sum ts -> Ty.niche ts | _ -> false) ->
      let t = lltype env e.Expr.ty in
      let word =
        match (index, expr env fr b payload) with
        | 0, _ | _, None -> Llvm.const_int (Llvm.i32_type env.ctx) 0
        | _, Some p -> p
      in
      Some (Llvm.build_insertvalue (Llvm.undef t) word 0 "" b)
  | Expr.Case { index; payload } ->
      let t = lltype env e.Expr.ty in
      let packed = match e.Expr.ty with Ty.Packed _ -> true | _ -> false in
      let tmp = alloca env fr t in
      let tag = Llvm.build_struct_gep t tmp 0 "" b in
      let tag_type = if packed then Llvm.i8_type env.ctx else Llvm.i32_type env.ctx in
      ignore (Llvm.build_store (Llvm.const_int tag_type index) tag b);
      (match expr env fr b payload with
      | Some p ->
          let at = Llvm.build_struct_gep t tmp 1 (if packed then unaligned_name else "") b in
          ignore (Llvm.build_store p at b)
      | None -> ());
      Some (Llvm.build_load t tmp "" b)
  | Expr.Payload { value; _ } when (match value.Expr.ty with Ty.Sum ts -> Ty.niche ts | _ -> false) -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | _, Some v -> Some (Llvm.build_extractvalue v 0 "" b))
  | Expr.Payload { value; _ } -> (
      match (e.Expr.ty, expr env fr b value) with
      | Ty.Void, _ | _, None -> None
      | t, Some v ->
          let sum = Llvm.type_of v in
          let tmp = alloca env fr sum in
          ignore (Llvm.build_store v tmp b);
          let name = if Llvm.is_packed sum then unaligned_name else "" in
          Some (Llvm.build_load (lltype env t) (Llvm.build_struct_gep sum tmp 1 name b) "" b))
  | Expr.Call _ | Expr.Call_value _ -> (
      match call env fr b e with
      | `Value v -> Some v
      | `Stored p -> Some (Llvm.build_load (lltype env e.Expr.ty) p "" b)
      | `Nothing -> None)
  | Expr.Runtime { fn = (Cgt.Runtime.List_at | Cgt.Runtime.Array_at) as fn; args } ->
      let cached =
        match (fn, args) with
        | Cgt.Runtime.List_at, l :: _ when fr.hoisted <> [] ->
            let key = match l.Expr.node with Expr.Local x -> Option.value ~default:l (Hashtbl.find_opt fr.names x) | _ -> l in
            List.assoc_opt key fr.hoisted
        | _ -> None
      in
      let unchecked = cached <> None && List.memq e fr.unchecked in
      Some (element ?cached ~unchecked env fr b fn (List.filter_map (expr env fr b) args))
  | Expr.Runtime { fn = (Cgt.Runtime.List_remove _ | Cgt.Runtime.List_swap_remove _) as fn; args } -> (
      match List.filter_map (expr env fr b) args with
      | [ list; index; stride ] ->
          remove env fr b fn list index stride;
          None
      | _ -> Diagnostic.bug "codegen: a removal with the wrong arguments")
  (* A new list is empty and owns no block (runtime/list.c). *)
  | Expr.Runtime { fn = Cgt.Runtime.List_new; args = [] } -> Some (Llvm.const_null (lltype env e.Expr.ty))
  | Expr.Runtime { fn = Cgt.Runtime.List_push; args } -> (
      let run =
        match args with
        | { Expr.node = Expr.Address id; _ } :: _ -> Option.map (fun r -> (id, r)) (Hashtbl.find_opt fr.runs id)
        | _ -> None
      in
      match List.filter_map (expr env fr b) args with
      | [ list; stride ] -> (
          match run with
          | Some (id, Ahead n) ->
              Hashtbl.replace fr.runs id (Room (n - 1));
              Some (push env fr b ~ahead:n list stride)
          | Some (id, Room n) ->
              if n = 1 then Hashtbl.remove fr.runs id else Hashtbl.replace fr.runs id (Room (n - 1));
              Some (push env fr b ~unchecked:true list stride)
          | None -> Some (push env fr b list stride))
      | _ -> Diagnostic.bug "codegen: a push with the wrong arguments")
  | Expr.Runtime
      {
        fn = Cgt.Runtime.Pool_push;
        args = { Expr.node = Expr.Local x; _ } :: node :: { Expr.node = Expr.Int size; _ } :: { Expr.node = Expr.Int n; _ } :: links;
      }
    when Pool_cache.held x ->
      let rec pairs k = function
        | o :: { Expr.node = Expr.Int l; _ } :: rest when k > 0 -> (value_of env fr b o, Int64.to_int l) :: pairs (k - 1) rest
        | _ -> []
      in
      let node = value_of env fr b node in
      let links = pairs (Int64.to_int n) links in
      Some (Pool_cache.push env.ctx env.m b (Option.get !Pool_cache.current) node (Int64.to_int size) links)
  | Expr.Runtime { fn = Cgt.Runtime.Pool_new; args = [ out ] } when Pool_cache.unchecked () ->
      Pool_cache.fresh env.ctx env.m b (value_of env fr b out);
      None
  | Expr.Runtime { fn; args = given } -> (
      let f, fty = runtime env fn in
      let args = given in
      let args =
        List.filter_map
          (fun (a : Expr.t) ->
            match (a.Expr.ty, expr env fr b a) with
            | (Ty.Handle | Ty.Handle16), Some v -> Some (spill env fr b v)
            | _, v -> v)
          args
      in
      Pool_cache.around env.ctx b given (fun () ->
          match e.Expr.ty with
          | Ty.Void ->
              ignore (Llvm.build_call fty f (Array.of_list args) "" b);
              None
          | (Ty.Handle | Ty.Handle16) as h ->
              let t = lltype env h in
              let out = alloca env fr t in
              ignore (Llvm.build_call fty f (Array.of_list (out :: args)) "" b);
              Some (Llvm.build_load t out "" b)
          | _ -> Some (Llvm.build_call fty f (Array.of_list args) "" b)))
  | Expr.Math { fn; args } ->
      (* The operands' instructions come in the order they are listed. *)
      let args = List.map (value_of env fr b) args in
      Some (math env b fn e.Expr.ty args)
  | Expr.Binary { op; left; right } -> (
      (* The left operand's instructions come first. *)
      let l = expr env fr b left in
      match (l, expr env fr b right) with
      | Some l, Some r -> Some (binary env fr b op left.Expr.ty l r)
      | _ -> Diagnostic.bug "codegen: an operand has no value")
  | Expr.Flip value -> (
      match (value.Expr.ty, expr env fr b value) with
      | (Ty.I64 | Ty.I32), Some v -> Some (Llvm.build_neg v "" b)
      | (Ty.F64 | Ty.F32), Some v -> Some (Llvm.build_fneg v "" b)
      | Ty.I1, Some v -> Some (Llvm.build_not v "" b)
      | _ -> Diagnostic.bug "codegen: `~` on a value it does not flip")
  (* A 32-bit handle's count or room is never negative, so it widens with
     zeros, as List_handle reads it everywhere else: the same widening of the
     same load, so LLVM sees a loop's bound and an index's check compare
     with one value. *)
  | Expr.Convert ({ Expr.node = Expr.Member { value = { Expr.ty = Ty.Handle16; _ }; index = 1 | 2 }; _ } as value)
    when e.Expr.ty = Ty.I64 -> (
      match expr env fr b value with
      | Some v -> Some (Llvm.build_zext v env.i64 "" b)
      | None -> Diagnostic.bug "codegen: a conversion of no value")
  | Expr.Convert value -> (
      match expr env fr b value with
      | Some v -> Some (convert env b value.Expr.ty e.Expr.ty v)
      | None -> Diagnostic.bug "codegen: a conversion of no value")
  | Expr.Expand { label; body; result } ->
      Option.iter (fun id -> ignore (slot env fr id (lltype env e.Expr.ty))) result;
      let exit = block env fr in
      Hashtbl.replace fr.labels label (exit, List.length fr.open_);
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br exit b);
      Llvm.position_at_end exit b;
      Option.bind result (fun id -> expr env fr b { Expr.node = Expr.Local id; ty = e.Expr.ty })

(* A call (docs/design/lowering.md §9). Each argument passes as its type
   says: as itself; as words, through a slot of words; or by address, a
   place's own and a fresh slot of this frame for any other value. The
   arguments run in order first. A result that comes back by address is
   written to [into], a fresh slot the caller names, or to one made here;
   one that comes back as words is put back together in a slot. *)
and call ?into env fr b (e : Expr.t) =
  let f, fty, a, args =
    match e.Expr.node with
    | Expr.Call { fn; args } ->
        let f, fty = Hashtbl.find env.funcs fn in
        (f, fty, Hashtbl.find env.abis fn, args)
    | Expr.Call_value { fn; args } ->
        (* The function's type is its arguments' and its result's, which the
           tree gives, as for a direct call. *)
        let f = value_of env fr b fn in
        let a = abi env (List.map (fun (a : Expr.t) -> a.Expr.ty) args) e.Expr.ty in
        (f, abi_type env a, a, args)
    | _ -> Diagnostic.bug "codegen: a call that is not one"
  in
  let rec pass passings (args : Expr.t list) =
    match (args, passings) with
    | [], [] -> []
    | (arg : Expr.t) :: rest, _ when arg.Expr.ty = Ty.Void ->
        ignore (expr env fr b arg);
        pass passings rest
    | arg :: rest, (_, p) :: passings ->
        let passed =
          match p with
          | Itself -> [ value_of env fr b arg ]
          | Address -> [ in_memory env fr b arg ]
          | Words n -> to_words env fr b n (value_of env fr b arg)
        in
        passed @ pass passings rest
    | _ -> Diagnostic.bug "codegen: a call whose arguments do not match its signature"
  in
  let ret, ret_passing = a.ret in
  let dest =
    match ret_passing with
    | Address -> Some (match into with Some p -> p | None -> alloca env fr (lltype env ret))
    | Itself | Words _ -> None
  in
  let given = args in
  let args = pass a.params args in
  let site =
    Pool_cache.around env.ctx b given (fun () -> Llvm.build_call fty f (Array.of_list (Option.to_list dest @ args)) "" b)
  in
  List.iter
    (fun (i, attrs) -> List.iter (fun at -> Llvm.add_call_site_attr site at (Llvm.AttrIndex.Param i)) attrs)
    (abi_attrs env a);
  match (ret_passing, dest) with
  | _ when ret = Ty.Void -> `Nothing
  | Address, Some p -> `Stored p
  | Words n, _ ->
      let slot = alloca env fr (Llvm.array_type env.i64 n) in
      ignore (Llvm.build_store site slot b);
      `Stored slot
  | _ -> `Value site

(* The address of a slot holding [e]'s value, for a parameter passed by
   address. A place is lent where it is: nothing else in the call writes it
   (memory.md §2.9.1). A call that returns by address writes its result
   straight into a fresh slot, and an expansion's result is its own slot.
   Any other value is stored in a fresh slot of this frame first. *)
and in_memory env fr b (e : Expr.t) =
  match e.Expr.node with
  | Expr.Local id when Hashtbl.mem fr.locals id -> fst (Hashtbl.find fr.locals id)
  | Expr.Deref p -> value_of env fr b p
  | (Expr.Call _ | Expr.Call_value _) when returning env e.Expr.ty = Address -> (
      match call env fr b e with
      | `Stored p -> p
      | _ -> Diagnostic.bug "codegen: a result passed by address came back otherwise")
  | Expr.Expand { result = Some id; _ } -> (
      ignore (expr env fr b e);
      match Hashtbl.find_opt fr.locals id with
      | Some (slot, _) -> slot
      | None -> Diagnostic.bug "codegen: an expansion's result has no slot")
  | _ -> spill env fr b (value_of env fr b e)

(* A value as [n] words, through a slot of words it is stored in. *)
and to_words env fr b n v =
  let slot = alloca env fr (Llvm.array_type env.i64 n) in
  ignore (Llvm.build_store v slot b);
  List.init n (fun i ->
      Llvm.build_load env.i64 (Llvm.build_in_bounds_gep env.i64 slot [| Llvm.const_int env.i64 i |] "" b) "" b)

(* [v] split into [n] words, and packed into one value of the [n]-word type
   when there is more than one. *)
and packed_words env fr b n v =
  let words = to_words env fr b n v in
  if n = 1 then List.hd words
  else
    List.fold_left
      (fun (acc, i) w -> (Llvm.build_insertvalue acc w i "" b, i + 1))
      (Llvm.undef (words_type env n), 0)
      words
    |> fst

and stats env fr b body =
  List.iter (fun (id, n) -> Hashtbl.replace fr.runs id (Ahead n)) (runs body);
  List.iter (fun s -> if not (has_terminator b) then stat env fr b s) body

and stat env fr b (s : Stat.t) =
  match s with
  | Stat.Let { id; value = { Expr.node = Expr.Call _ | Expr.Call_value _; ty } as value }
    when returning env ty = Address ->
      ignore (call ~into:(slot env fr id (lltype env ty)) env fr b value)
  | Stat.Let { id; value } -> (
      match expr env fr b value with
      | Some v -> ignore (Llvm.build_store v (slot env fr id (Llvm.type_of v)) b)
      | None -> ())
  | Stat.Assign { place; value } -> (
      match (expr env fr b value, Hashtbl.find_opt fr.locals place.Expr.local) with
      | Some v, Some (slot, _) ->
          let base = if place.Expr.deref then Llvm.build_load env.ptr slot "" b else slot in
          let target, _ =
            List.fold_left
              (fun (p, t) i ->
                match t with
                | Ty.Struct ts -> (Llvm.build_struct_gep (lltype env t) p i "" b, List.nth ts i)
                | _ -> Diagnostic.bug "codegen: a member path through something not a struct")
              (base, place.Expr.ty) place.Expr.path
          in
          let store = Llvm.build_store v target b in
          (* A store into a local's own slot is the frame's. *)
          if place.Expr.deref || place.Expr.path <> [] then ignore (access env value.Expr.ty store)
      | _ -> ())
  | Stat.Switch { value; cases } ->
      let v = value_of env fr b value in
      let tag = Llvm.build_extractvalue v 0 "" b in
      let tag =
        match value.Expr.ty with
        | Ty.Sum ts when Ty.niche ts ->
            Llvm.build_zext (Llvm.build_icmp Llvm.Icmp.Ne tag (Llvm.const_int (Llvm.i32_type env.ctx) 0) "" b) (Llvm.i32_type env.ctx) "" b
        | _ -> tag
      in
      let after = block env fr and otherwise = block env fr in
      let sw = Llvm.build_switch tag otherwise (List.length cases) b in
      List.iter
        (fun (i, body) ->
          let case = block env fr in
          Llvm.add_case sw (Llvm.const_int (Llvm.type_of tag) i) case;
          Llvm.position_at_end case b;
          stats env fr b body;
          if not (has_terminator b) then ignore (Llvm.build_br after b))
        cases;
      (* A tag is always one of the cases. *)
      Llvm.position_at_end otherwise b;
      ignore (Llvm.build_unreachable b);
      Llvm.position_at_end after b
  | Stat.Eval e -> ignore (expr env fr b e)
  | Stat.Return e -> (
      (* The value is read before its arenas are drained: a result passed
         by address is written to the caller's slot first, by a call
         straight into it when the value is one. *)
      let ret, ret_passing = fr.ret in
      let v =
        match (ret_passing, fr.sret, e.Expr.node) with
        | Address, Some dest, (Expr.Call _ | Expr.Call_value _) ->
            ignore (call ~into:dest env fr b e);
            None
        | Address, Some dest, _ ->
            Option.iter (fun v -> ignore (Llvm.build_store v dest b)) (expr env fr b e);
            None
        | Words n, _, _ -> Option.map (packed_words env fr b n) (expr env fr b e)
        | _ -> expr env fr b e
      in
      Option.iter (Pool_cache.flush env.ctx b) !Pool_cache.current;
      drain env fr b 0;
      match v with
      | Some v when ret <> Ty.Void -> ignore (Llvm.build_ret v b)
      | _ -> ignore (Llvm.build_ret_void b))
  | Stat.Scope { id; body } ->
      let frame = Frames.layout fr.symbol id body in
      Hashtbl.iter (Hashtbl.replace fr.offsets) frame.Frames.offsets;
      if frame.Frames.size <= 4096 && light id body then begin
        let space = alloca env fr (Llvm.array_type (Llvm.i8_type env.ctx) frame.Frames.size) in
        Llvm.set_alignment 16 space;
        Hashtbl.replace fr.arenas id space;
        stats env fr b body
      end
      else
      let arena = enter env fr b frame.Frames.size in
      Hashtbl.replace fr.arenas id arena;
      fr.open_ <- arena :: fr.open_;
      stats env fr b body;
      if not (has_terminator b) then drain_scope env fr b arena;
      fr.open_ <- List.tl fr.open_
  | Stat.Hold { id; scope; value = { Expr.node = Expr.Call _ | Expr.Call_value _; ty } as value; layout = l }
    when returning env ty = Address ->
      let slot = frame_slot env fr b scope id in
      ignore (call ~into:slot env fr b value);
      hold env fr b slot l;
      Hashtbl.replace fr.locals id (slot, lltype env ty)
  | Stat.Hold { id; scope; value; layout = l } -> (
      match expr env fr b value with
      | None -> ()
      | Some v ->
          (* The slot is listed before it is written, since listing it only
             takes its address: the write is then the last LLVM sees before
             what follows, and it knows the value there, a new list's empty
             header included. A large value is written first, so its load
             and its store stay next to each other for Big_moves. *)
          let slot = frame_slot env fr b scope id in
          if fst (size_align value.Expr.ty) >= large then begin
            ignore (Llvm.build_store v slot b);
            hold env fr b slot l
          end
          else begin
            hold env fr b slot l;
            ignore (Llvm.build_store v slot b)
          end;
          Hashtbl.replace fr.locals id (slot, Llvm.type_of v))
  | Stat.Reserve { id; scope; ty = t; layout = l } ->
      let slot = frame_slot env fr b scope id in
      hold env fr b slot l;
      zero env b slot (fst (size_align t));
      Hashtbl.replace fr.locals id (slot, lltype env t)
  | Stat.Place { address; value; layout = l } -> (
      let p = value_of env fr b address in
      match expr env fr b value with Some v -> place env b value.Expr.ty p v l | None -> ())
  | Stat.Store { address; value } -> (
      let p = value_of env fr b address in
      match expr env fr b value with
      | Some v -> ignore (access env value.Expr.ty (Llvm.build_store v p b))
      | None -> ())
  | Stat.Overwrite { address; value; layout = l } -> (
      let p = value_of env fr b address in
      match expr env fr b value with
      | None -> ()
      | Some v ->
          let incoming = spill env fr b v in
          let n x = Llvm.const_int env.i64 x in
          let size = n (fst (size_align value.Expr.ty)) in
          ignore (call_runtime env b Cgt.Runtime.Overwrite [| p; incoming; size; layout env l |]))
  | Stat.If { cond; body } ->
      let c = value_of env fr b cond in
      let taken = block env fr and after = block env fr in
      ignore (Llvm.build_cond_br c taken after b);
      Llvm.position_at_end taken b;
      stats env fr b body;
      if not (has_terminator b) then ignore (Llvm.build_br after b);
      Llvm.position_at_end after b
  | Stat.Repeat { count; body } ->
      (* The count is read once; a count below one runs the body no times. *)
      let n = value_of env fr b count in
      let looped = looped_pushes body in
      List.iter
        (fun (id, stride) ->
          let list = value_of env fr b { Expr.node = Expr.Address id; ty = Ty.Ptr } in
          let f, fty = runtime env Cgt.Runtime.List_room in
          ignore (Llvm.build_call fty f [| list; Llvm.const_int env.i64 (Int64.to_int stride); n |] "" b);
          Hashtbl.replace fr.runs id (Room max_int))
        looped;
      Fun.protect ~finally:(fun () -> List.iter (fun (id, _) -> Hashtbl.remove fr.runs id) looped) @@ fun () ->
      let lists, names = invariant_lists body in
      let ranges = ranged body lists names in
      let counted trips =
        let saved = fr.hoisted in
        let hoisted =
          List.map
            (fun a ->
              let list = value_of env fr b a in
              let tag = handle_field env and count_tag = if List_handle.on () then handle_field env else count_field env in
              (a, (List_handle.items ~tag env.ctx b list, List_handle.count ~tag:count_tag env.ctx b list)))
            lists
        in
        fr.hoisted <- hoisted @ saved;
        Hashtbl.iter (Hashtbl.replace fr.names) names;
        let loop () =
        let i = alloca env fr env.i64 in
        ignore (Llvm.build_store (Llvm.const_int env.i64 0) i b);
        let head = block env fr and step = block env fr and after = block env fr in
        ignore (Llvm.build_br head b);
        Llvm.position_at_end head b;
        let current = Llvm.build_load env.i64 i "" b in
        let test = Llvm.build_cond_br (Llvm.build_icmp Llvm.Icmp.Slt current n "" b) step after b in
        Option.iter (weigh env test) trips;
        Llvm.position_at_end step b;
        fr.loops <- fr.loops + 1;
        stats env fr b body;
        fr.loops <- fr.loops - 1;
        if not (has_terminator b) then begin
          let current = Llvm.build_load env.i64 i "" b in
          (* Below the count, so it cannot wrap. *)
          let next = Llvm.build_nsw_add current (Llvm.const_int env.i64 1) "" b in
          ignore (Llvm.build_store next i b);
          ignore (Llvm.build_br head b)
        end;
        Llvm.position_at_end after b
        in
        (if ranges = [] then loop ()
         else begin
           (* Each index's first and last value, one less than each compared
              unsigned with the list's count, as [element] checks one. *)
           let one = Llvm.const_int env.i64 1 in
           let last_pass = Llvm.build_sub n one "" b in
           let fits =
             List.fold_left
               (fun ok (_, key, a, first) ->
                 let count = snd (List.assoc key fr.hoisted) in
                 let first = Option.get (expr env fr b first) in
                 let last = Llvm.build_add first (Llvm.build_mul (Llvm.const_int env.i64 a) last_pass "" b) "" b in
                 let inside v = Llvm.build_icmp Llvm.Icmp.Ult (Llvm.build_sub v one "" b) count "" b in
                 Llvm.build_and ok (Llvm.build_and (inside first) (inside last) "" b) "" b)
               (Llvm.const_int (Llvm.i1_type env.ctx) 1)
               ranges
           in
           let fast = block env fr and slow = block env fr and joined = block env fr in
           ignore (Llvm.build_cond_br fits fast slow b);
           Llvm.position_at_end fast b;
           let outer = fr.unchecked in
           fr.unchecked <- List.map (fun (e, _, _, _) -> e) ranges @ outer;
           loop ();
           fr.unchecked <- outer;
           ignore (Llvm.build_br joined b);
           Llvm.position_at_end slow b;
           loop ();
           ignore (Llvm.build_br joined b);
           Llvm.position_at_end joined b
         end);
        fr.hoisted <- saved
      in
      if (not env.version) || fr.loops > 0 || not (versioned ~symbol:fr.symbol body) then counted None
      else begin
        (* A loop no other loop holds is emitted twice, for a count of at
           least [long_loop] and for a smaller one, each saying how often it
           goes round (docs/design/lowering.md, "The passes"). *)
        let long = block env fr and short = block env fr and joined = block env fr in
        let at_least = Llvm.build_icmp Llvm.Icmp.Sge n (Llvm.const_int env.i64 long_loop) "" b in
        (* Taking the long copy is weighted as rare, so the short copy is
           what falls through from the test; the long copy's own weights
           still make its body hot. Weighting it common, or not at all,
           costs langbench's `fannkuch` 1.5% more instructions. *)
        unlikely env (Llvm.build_cond_br at_least long short b);
        List.iter
          (fun (start, trips) ->
            Llvm.position_at_end start b;
            counted (Some trips);
            ignore (Llvm.build_br joined b))
          [ (long, long_trips); (short, short_trips) ];
        Llvm.position_at_end joined b
      end
  | Stat.Leave label ->
      let exit, depth = Hashtbl.find fr.labels label in
      drain env fr b depth;
      ignore (Llvm.build_br exit b)
  | Stat.Spawn { task; scope; thunk; frame; args; dest; layout = l } ->
      (* The arguments run first, in order; then the frame is made, filled,
         and handed to the pool with where its result goes. *)
      let values = List.map (expr env fr b) args in
      let n x = Llvm.const_int env.i64 x in
      let header = frame_slot env fr b scope task in
      zero env b header Frames.task;
      let at = byte_at env b header Frames.task in
      let t = lltype env frame in
      List.iteri
        (fun i v ->
          Option.iter
            (fun v -> ignore (Llvm.build_store v (Llvm.build_struct_gep t at (i + 1) "" b) b))
            v)
        values;
      ignore (Llvm.build_store at (slot env fr task env.ptr) b);
      let result = match frame with Ty.Struct (r :: _) -> r | _ -> Ty.Void in
      let home, bytes =
        match dest with
        | Some id ->
            let size = fst (size_align result) in
            let s = frame_slot env fr b scope id in
            zero env b s size;
            hold env fr b s l;
            Hashtbl.replace fr.locals id (s, lltype env result);
            (s, size)
        | None -> (at, 0)
      in
      let f, _ = Hashtbl.find env.funcs thunk in
      ignore (call_runtime env b Cgt.Runtime.Spawn [| at; f; home; layout env l; n bytes |])
  | Stat.Join task ->
      let at = Llvm.build_load env.ptr (fst (Hashtbl.find fr.locals task)) "" b in
      ignore (call_runtime env b Cgt.Runtime.Join [| at |])

(* ---------------------------------------------------------------------- *)
(* Functions and programs                                                 *)
(* ---------------------------------------------------------------------- *)

(* A parameter passed by address is the caller's place or a fresh slot of
   its, which the attributes promise the callee only reads. Lowering never
   writes a parameter's own slot: a borrow is read-only (memory.md §2.9),
   and a `^T` parameter is held in a slot of the body's own before it is
   moved on. So one that does is an invariant broken, not a program to
   build. *)
let unwritten env (f : Func.t) addressed =
  let bad id = Diagnostic.bug (Printf.sprintf "codegen: `%s` writes its parameter %%%d, passed by address" f.Func.symbol id) in
  let rec stat (s : Stat.t) =
    (match s with
    | Stat.Assign { place; _ } when (not place.Expr.deref) && List.mem place.Expr.local addressed ->
        bad place.Expr.local
    | _ -> ());
    let es, bodies = Cgt.Traverse.stat_parts s in
    List.iter expr es;
    List.iter (List.iter stat) bodies
  and expr (e : Expr.t) =
    (match e.Expr.node with
    | Expr.Take { address = { Expr.node = Expr.Address id; _ }; layout = l }
      when List.mem id addressed && Option.is_some (Walks.vacater (walks env) l) ->
        bad id
    | _ -> ());
    let es, bodies = Cgt.Traverse.expr_parts e in
    List.iter expr es;
    List.iter (List.iter stat) bodies
  in
  if addressed <> [] then List.iter stat f.Func.body

let func env (f : Func.t) =
  let fn, _ = Hashtbl.find env.funcs f.Func.symbol in
  let a = Hashtbl.find env.abis f.Func.symbol in
  (* `define_function` gives the function its entry block already. *)
  let b = Llvm.builder_at_end env.ctx (Llvm.entry_block fn) in
  let sret = match snd a.ret with Address -> Some (Llvm.param fn 0) | Itself | Words _ -> None in
  let fr =
    {
      fn;
      symbol = f.Func.symbol;
      locals = Hashtbl.create 8;
      labels = Hashtbl.create 8;
      arenas = Hashtbl.create 4;
      open_ = [];
      offsets = Hashtbl.create 8;
      ret = a.ret;
      sret;
      loops = 0;
      runs = Hashtbl.create 4;
      hoisted = [];
      names = Hashtbl.create 8;
      unchecked = [];
    }
  in
  (* A parameter passed as itself is stored into a slot like any other
     local, and one passed as words is put back together in one. One
     passed by address is read where it is: its pointer is its slot. *)
  let kept = List.filter (fun (_, t) -> t <> Ty.Void) f.Func.params in
  let next = ref (if Option.is_some sret then 1 else 0) in
  let param () =
    let p = Llvm.param fn !next in
    incr next;
    p
  in
  List.iter2
    (fun (id, t) (_, passing) ->
      match passing with
      | Itself -> ignore (Llvm.build_store (param ()) (slot env fr id (lltype env t)) b)
      | Address -> Hashtbl.replace fr.locals id (param (), lltype env t)
      | Words n ->
          let s = alloca env fr (Llvm.array_type env.i64 n) in
          for i = 0 to n - 1 do
            let at = Llvm.build_in_bounds_gep env.i64 s [| Llvm.const_int env.i64 i |] "" b in
            ignore (Llvm.build_store (param ()) at b)
          done;
          Hashtbl.replace fr.locals id (s, lltype env t))
    kept a.params;
  unwritten env f (List.filter_map (fun ((id, _), (_, p)) -> if p = Address then Some id else None) (List.combine kept a.params));
  (Pool_cache.current :=
     match if Pool_cache.on () then Pool_cache.pool_locals f else [] with
     | p :: _ as ids ->
         let handle = Llvm.build_load env.ptr (fst (Hashtbl.find fr.locals p)) "" b in
         Some (Pool_cache.start env.ctx b ~alloca:(alloca env fr) ids handle)
     | [] -> None);
  stats env fr b f.Func.body;
  Pool_cache.current := None;
  if not (has_terminator b) then
    ignore
      (if f.Func.ret = Ty.Void || Option.is_some sret then Llvm.build_ret_void b
       else Llvm.build_unreachable b);
  unaligned fn
