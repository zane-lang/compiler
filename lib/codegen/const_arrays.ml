(* A
   local whose every write is a constant, the same at each offset each
   time, made a constant global.

   An `Array` literal of constants, as a scene or a lookup table, is a
   stack slot its elements
   are stored to each time the code that makes it runs, inside the loop
   that reads it. Where the slot is indexed by a value LLVM does not know,
   the stores stay. A slot that nothing writes but those constants holds
   the same bytes whenever it is read (a byte never written was undefined,
   and reading the global's zero is one of its values), so the reads can
   read a constant global instead, and the stores go.

   The slot: an alloca every use of which, through GEPs, is a load, a
   store of a constant at a constant offset, the source of a `memcpy`, or
   a lifetime marker. Constants are integers, floats, and vectors and
   arrays of them; the target is little-endian. *)


exception No

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* [c]'s bytes, little-endian, as [size] bytes. *)
let rec bytes_of dl c =
  let t = Llvm.type_of c in
  let size = Int64.to_int (Llvm_target.DataLayout.store_size t dl) in
  let le n v = String.init n (fun i -> Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * i)) 0xffL))) in
  match Llvm.classify_type t with
  | Llvm.TypeKind.Integer -> (
      if size > 8 then raise No;
      match Llvm.int64_of_const c with Some v -> le size v | None -> raise No)
  | Llvm.TypeKind.Double -> (
      match Llvm.float_of_const c with Some f -> le 8 (Int64.bits_of_float f) | None -> raise No)
  | Llvm.TypeKind.Float -> (
      match Llvm.float_of_const c with Some f -> le 4 (Int64.of_int32 (Int32.bits_of_float f)) | None -> raise No)
  | Llvm.TypeKind.Vector | Llvm.TypeKind.Array ->
      let e = Llvm.element_type t in
      let n = if Llvm.classify_type t = Llvm.TypeKind.Vector then Llvm.vector_size t else Llvm.array_length t in
      let es = Int64.to_int (Llvm_target.DataLayout.abi_size e dl) in
      let b = Bytes.make size '\000' in
      for i = 0 to n - 1 do
        match Llvm.aggregate_element c i with
        | Some x -> Bytes.blit_string (bytes_of dl x) 0 b (i * es) (String.length (bytes_of dl x))
        | None -> raise No
      done;
      Bytes.to_string b
  | _ -> raise No

let callee i =
  let n = Llvm.num_operands i in
  let f = Llvm.operand i (n - 1) in
  if Llvm.classify_value f = Llvm.ValueKind.Function then Some (Llvm.value_name f) else None

let func m dl f =
  let entry = Llvm.entry_block f in
  let allocas = ref [] in
  Llvm.iter_instrs (fun i -> if Llvm.instr_opcode i = Llvm.Opcode.Alloca then allocas := i :: !allocas) entry;
  List.iter
    (fun a ->
      let size = Int64.to_int (Llvm_target.DataLayout.abi_size (Wrappers.allocated_type a) dl) in
      let image = Bytes.make size '\000' and written = Array.make size false in
      let stores = ref [] and markers = ref [] in
      (* [p] is at constant offset [off] from [a], or anywhere ([None]). *)
      let rec visit p off =
        Llvm.iter_uses
          (fun u ->
            let i = Llvm.user u in
            match Llvm.classify_value i with
            | Llvm.ValueKind.Instruction Llvm.Opcode.GetElementPtr when Llvm.operand i 0 == p ->
                let o = match off with Some o -> Option.map (Int64.add o) (Frame_shadow.gep_offset dl i) | None -> None in
                visit i o
            | Llvm.ValueKind.Instruction Llvm.Opcode.Load -> if Llvm.is_volatile i then raise No
            | Llvm.ValueKind.Instruction Llvm.Opcode.Store when Llvm.operand i 1 == p && Llvm.operand i 0 != p -> (
                let v = Llvm.operand i 0 in
                match off with
                | Some o when Llvm.is_constant v && not (Llvm.is_volatile i) ->
                    let b = bytes_of dl v in
                    let o = Int64.to_int o in
                    if o < 0 || o + String.length b > size then raise No;
                    String.iteri
                      (fun k ch ->
                        if written.(o + k) && Bytes.get image (o + k) <> ch then raise No;
                        written.(o + k) <- true;
                        Bytes.set image (o + k) ch)
                      b;
                    stores := i :: !stores
                | _ -> raise No)
            | Llvm.ValueKind.Instruction Llvm.Opcode.Call -> (
                match callee i with
                | Some n when starts "llvm.lifetime" n -> markers := i :: !markers
                | Some n when starts "llvm.memcpy" n && Llvm.operand i 1 == p && Llvm.operand i 0 != p -> ()
                | _ -> raise No)
            | _ -> raise No)
          p
      in
      match visit a (Some 0L) with
      | exception No -> ()
      | () ->
          if !stores <> [] then begin
            let ctx = Llvm.module_context m in
            let init = Llvm.const_string ctx (Bytes.to_string image) in
            let g = Llvm.define_global "zane.const.array" init m in
            Llvm.set_global_constant true g;
            Llvm.set_linkage Llvm.Linkage.Private g;
            Llvm.set_unnamed_addr true g;
            Llvm.set_alignment (max 16 (Llvm.alignment a)) g;
            List.iter Llvm.delete_instruction !stores;
            List.iter Llvm.delete_instruction !markers;
            Llvm.replace_all_uses_with a g;
            Llvm.delete_instruction a
          end)
    !allocas

let run m =
  begin
    let dl = Llvm_target.DataLayout.of_string (Llvm.data_layout m) in
    if Llvm_target.DataLayout.byte_order dl = Llvm_target.Endian.Little then
      Llvm.iter_functions (fun f -> if not (Llvm.is_declaration f) then func m dl f) m
  end

(* Reads of the globals folded, and copies from them made reads of them. *)
let again = "function(instcombine<no-verify-fixpoint>,memcpyopt,sroa,early-cse<memssa>,gvn,simplifycfg,loop-mssa(licm<allowspeculation>))"
