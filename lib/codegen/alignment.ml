(* Each read and write is as aligned as its address is known to be.

   A packed value may begin at any byte (Nodes.Ty.tight, lowering.md L5),
   so the alignment of the type read or written says nothing about the
   address: a member of a struct may sit at an odd offset inside a packed
   one. Every non-atomic load and store therefore takes the smaller of its
   type's alignment and what its address is known to be:

   - a stack slot or a global is at its own alignment;
   - a getelementptr keeps its base's alignment as far as its constant
     offset and each varying index's stride divide it;
   - a pointer loaded from memory is as aligned as its `!align` says
     (List_handle.aligned), and a parameter as its `align` attribute;
   - a runtime call's result as the runtime places it: a frame on 16
     bytes, a block on its alignment and at least 8 (runtime/arena.c),
     and a pushed list slot a whole number of strides into a block aligned
     to 8 (runtime/list.c);
   - a phi or select is the least of its incoming addresses;
   - anything else is at any byte.

   An atomic access keeps its alignment: the runtime places every word it
   is used on. *)

let most = 4096

(* The largest power of two dividing [n], or [most] for 0. *)
let low_bit n = if n = 0L then most else Int64.to_int (Int64.logand n (Int64.neg n)) |> min most

(* A number [index] is known to be a multiple of: a constant itself, a
   product or a shift by a constant, a sum or difference of two such. *)
let rec multiple depth index =
  if depth > 8 then 1L
  else
    let sub i = multiple (depth + 1) (Llvm.operand index i) in
    let rec gcd a b = if b = 0L then a else gcd b (Int64.rem a b) in
    match Llvm.int64_of_const index with
    | Some c -> if c = 0L then 0L else Int64.abs c
    | None -> (
        match Llvm.classify_value index with
        | Llvm.ValueKind.Instruction Llvm.Opcode.Mul -> Int64.mul (sub 0) (sub 1)
        | Llvm.ValueKind.Instruction Llvm.Opcode.Shl -> (
            match Llvm.int64_of_const (Llvm.operand index 1) with
            | Some k when k >= 0L && k < 32L -> Int64.mul (sub 0) (Int64.shift_left 1L (Int64.to_int k))
            | _ -> sub 0)
        | Llvm.ValueKind.Instruction (Llvm.Opcode.Add | Llvm.Opcode.Sub) -> gcd (sub 0) (sub 1)
        | Llvm.ValueKind.Instruction (Llvm.Opcode.SExt | Llvm.Opcode.ZExt) -> sub 0
        | _ -> 1L)

(* A stack slot holding a pointer whose every use is a load from it or a
   store to it, so what it holds is only what is stored there. *)
let is_slot p =
  (match Llvm.classify_value p with Llvm.ValueKind.Instruction Llvm.Opcode.Alloca -> true | _ -> false)
  && Llvm.classify_type (Wrappers.allocated_type p) = Llvm.TypeKind.Pointer
  && Llvm.fold_left_uses
       (fun ok u ->
         ok
         &&
         let user = Llvm.user u in
         match Llvm.classify_value user with
         | Llvm.ValueKind.Instruction Llvm.Opcode.Load -> true
         | Llvm.ValueKind.Instruction Llvm.Opcode.Store -> Llvm.operand user 1 == p && Llvm.operand user 0 != p
         | _ -> false)
       true p

let rec known dl ctx depth v =
  if depth > 8 then 1
  else
    let known' = known dl ctx (depth + 1) in
    let gep () =
      let base = known' (Llvm.operand v 0) in
      let rec walk t i offset stride =
        if i >= Llvm.num_operands v then (offset, stride)
        else
          let index = Llvm.operand v i in
          let constant = Llvm.int64_of_const index in
          match Llvm.classify_type t with
          | Llvm.TypeKind.Struct ->
              let n = Option.value ~default:0L constant |> Int64.to_int in
              walk (Llvm.struct_element_types t).(n) (i + 1)
                (Int64.add offset (Llvm_target.DataLayout.offset_of_element t n dl))
                stride
          | Llvm.TypeKind.Array | Llvm.TypeKind.Vector ->
              let e = Llvm.element_type t in
              step e (i + 1) offset stride (Llvm_target.DataLayout.abi_size e dl) constant
          | _ -> (offset, 1L)
      and step e i offset stride size = function
        | Some c -> walk e i (Int64.add offset (Int64.mul c size)) stride
        | None ->
            let size = Int64.mul size (multiple 0 (Llvm.operand v (i - 1))) in
            walk e i offset (if stride = 0L then size else gcd stride size)
      and gcd a b = if b = 0L then a else gcd b (Int64.rem a b) in
      let source = Llvm_extra.gep_source_type v in
      let offset, stride =
        if Llvm.num_operands v < 2 then (0L, 0L)
        else
          let size = Llvm_target.DataLayout.abi_size source dl in
          match Llvm.int64_of_const (Llvm.operand v 1) with
          | Some c -> walk source 2 (Int64.mul c size) 0L
          | None -> walk source 2 0L (Int64.mul size (multiple 0 (Llvm.operand v 1)))
      in
      min base (min (low_bit offset) (low_bit stride))
    in
    match Llvm.classify_value v with
    | Llvm.ValueKind.Instruction Llvm.Opcode.Alloca ->
        let a = Llvm.alignment v in
        if a > 0 then a else 1
    | Llvm.ValueKind.GlobalVariable ->
        (* One declared without an alignment, a runtime global, is at its
           type's, as C places it. *)
        let a = Llvm.alignment v in
        if a > 0 then a else Llvm_target.DataLayout.abi_align (Llvm_extra.value_type v) dl
    | Llvm.ValueKind.Instruction Llvm.Opcode.Call -> (
        let callee = Llvm.operand v (Llvm.num_operands v - 1) in
        let argument n = Option.map Int64.to_int (Llvm.int64_of_const (Llvm.operand v n)) in
        match Llvm.value_name callee with
        | "zane_scope_enter" -> 16
        | "zane_alloc" | "zane_alloc_held" -> ( match argument 2 with Some a -> max a 8 | None -> 8)
        | "zane_list_push" -> ( match argument 1 with Some stride -> min 8 (low_bit (Int64.of_int stride)) | None -> 1)
        | _ -> 1)
    | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr -> gep ()
    | Llvm.ValueKind.ConstantExpr when Llvm.constexpr_opcode v = Llvm.Opcode.GetElementPtr -> gep ()
    | Llvm.ValueKind.Instruction Llvm.Opcode.Load when is_slot (Llvm.operand v 0) ->
        (* Read back from a stack slot that is only stored to and loaded
           from, as codegen keeps a local before `mem2reg`: as aligned as
           the least of what is stored there. *)
        Llvm.fold_left_uses
          (fun acc u ->
            let user = Llvm.user u in
            match Llvm.instr_opcode user with
            | Llvm.Opcode.Store when Llvm.operand user 1 == Llvm.operand v 0 -> min acc (known' (Llvm.operand user 0))
            | _ -> acc)
          most (Llvm.operand v 0)
    | Llvm.ValueKind.Instruction Llvm.Opcode.Load -> (
        match Llvm.metadata v (Llvm.mdkind_id ctx "align") with
        | Some md -> (
            match Llvm.get_mdnode_operands md with
            | [| n |] -> ( match Llvm.int64_of_const n with Some n -> Int64.to_int n | None -> 1)
            | _ -> 1)
        | None -> 1)
    | Llvm.ValueKind.Argument ->
        let fn = Llvm.param_parent v in
        let params = Llvm.params fn in
        let rec index i = if i >= Array.length params then None else if params.(i) == v then Some i else index (i + 1) in
        (match index 0 with Some i -> Llvm_extra.param_align fn i | None -> 1)
    | Llvm.ValueKind.Instruction Llvm.Opcode.PHI ->
        List.fold_left (fun acc (incoming, _) -> min acc (known' incoming)) most (Llvm.incoming v)
    | Llvm.ValueKind.Instruction Llvm.Opcode.Select -> min (known' (Llvm.operand v 1)) (known' (Llvm.operand v 2))
    | _ -> 1

(* Every load and store in [m] as aligned as its address is known to be. *)
let mark m =
  let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
  let ctx = Llvm.module_context m in
  let lower i address =
    if not (Llvm_extra.is_atomic i) then
      let k = known dl ctx 0 address in
      if k < Llvm.alignment i then Llvm.set_alignment k i
  in
  Llvm.iter_functions
    (Llvm.iter_blocks
       (Llvm.iter_instrs (fun i ->
            match Llvm.instr_opcode i with
            | Llvm.Opcode.Load -> lower i (Llvm.operand i 0)
            | Llvm.Opcode.Store -> lower i (Llvm.operand i 1)
            | _ -> ())))
    m
