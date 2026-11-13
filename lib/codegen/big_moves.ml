(* Large aggregates moved as memory (docs/design/lowering.md §9).

   Emit moves a value as one LLVM value, a load and then a store, which is
   what a small value wants. LLVM's code generator gives a value at most
   65,535 parts, though, and dies on a larger one, such as an
   `@primitives$ArrayRef<Int, 65536>` moved into its slot; well below that
   it still takes seconds per move. So a load of a large aggregate whose
   only uses are stores becomes a `memcpy` per store. A value of more parts
   than that read only for its parts, as a match arm reads one field of a
   large payload, is read a part at a time, and one built a part at a time
   and stored, as a constructor builds its struct, is stored a part at a
   time, so a struct past 1 MiB can be a variant's payload. A large
   aggregate left anywhere else is reported as a limit rather than
   crashing LLVM. *)

(* Aggregates of this many bytes or more are moved as memory. *)
let large = Int64.of_int Emit.large

(* LLVM's limit on the parts of one value. *)
let most_parts = 65535

(* The parts of a value of LLVM type [t], or [most_parts + 1] when there are
   more than [most_parts]: each product and sum is checked before it is
   taken, so a length of 2^32 or more cannot overflow it. *)
let rec parts t =
  let over = most_parts + 1 in
  let add a b = if a > over - b then over else a + b in
  match Llvm.classify_type t with
  | Llvm.TypeKind.Array ->
      let n = Llvm_extra.array_length t and each = parts (Llvm.element_type t) in
      if each = 0 then 0 else if n > over / each then over else n * each
  | Llvm.TypeKind.Struct -> Array.fold_left (fun n e -> add n (parts e)) 0 (Llvm_extra.struct_element_types t)
  | _ -> 1

let aggregate t =
  match Llvm.classify_type t with Llvm.TypeKind.Array | Llvm.TypeKind.Struct -> true | _ -> false

let uses v =
  let all = ref [] in
  Llvm.iter_uses (fun u -> all := Llvm.user u :: !all) v;
  !all

let is_store_of v i = Llvm.instr_opcode i = Llvm.Opcode.Store && Llvm.operand i 0 == v

(* Whether anything between [a] and [b], in one block, may write memory. *)
let quiet_between a b =
  let rec go = function
    | Llvm.At_end _ -> false
    | Llvm.Before i when i == b -> true
    | Llvm.Before i -> (
        match Llvm.instr_opcode i with
        | Llvm.Opcode.Store | Llvm.Opcode.Call | Llvm.Opcode.Invoke | Llvm.Opcode.AtomicRMW
        | Llvm.Opcode.AtomicCmpXchg | Llvm.Opcode.Fence ->
            false
        | _ -> go (Llvm.instr_succ i))
  in
  Llvm.instr_parent a == Llvm.instr_parent b && go (Llvm.instr_succ a)

let rewrite data_layout m =
  let ctx = Llvm.module_context m in
  let ptr = Llvm.pointer_type ctx in
  let i64 = Llvm.i64_type ctx in
  let memcpy_type = Llvm.function_type (Llvm.void_type ctx) [| ptr; ptr; i64; Llvm.i1_type ctx |] in
  let memcpy =
    lazy
      (match Llvm.lookup_function "llvm.memcpy.p0.p0.i64" m with
      | Some f -> f
      | None -> Llvm.declare_function "llvm.memcpy.p0.p0.i64" memcpy_type m)
  in
  (* The source and destination of a store may be the same storage, as in
     `xs[i] = xs[j]` with `i = j`, which `memcpy` does not allow. *)
  let memmove =
    lazy
      (match Llvm.lookup_function "llvm.memmove.p0.p0.i64" m with
      | Some f -> f
      | None -> Llvm.declare_function "llvm.memmove.p0.p0.i64" memcpy_type m)
  in
  let call fn b dst src size =
    ignore
      (Llvm.build_call memcpy_type (Lazy.force fn)
         [| dst; src; Llvm.const_of_int64 i64 size false; Llvm.const_int (Llvm.i1_type ctx) 0 |]
         "" b)
  in
  let copy = call memcpy and move = call memmove in
  let size t = Llvm_target.DataLayout.store_size t data_layout in
  let large_loads f =
    let found = ref [] in
    Llvm.iter_blocks
      (Llvm.iter_instrs (fun i ->
           if
             Llvm.instr_opcode i = Llvm.Opcode.Load
             && aggregate (Llvm.type_of i)
             && Int64.compare (size (Llvm.type_of i)) large >= 0
           then found := i :: !found))
      f;
    !found
  in
  let rewrite_load f load =
    let users = uses load in
    if users <> [] && List.for_all (is_store_of load) users then begin
      let t = Llvm.type_of load in
      let n = size t in
      let src = Llvm.operand load 0 in
      (* A store right after its load, with nothing between that may
         write memory, copies straight from the source; any other
         keeps what the load read in a slot of its own. *)
      let from =
        if List.for_all (quiet_between load) users then src
        else begin
          let entry = Llvm.builder_at ctx (Llvm.instr_begin (Llvm.entry_block f)) in
          let held = Llvm.build_alloca t "" entry in
          Llvm.set_alignment 8 held;
          copy (Llvm.builder_before ctx load) held src n;
          held
        end
      in
      List.iter
        (fun store ->
          (if from == src then move else copy)
            (Llvm.builder_before ctx store) (Llvm.operand store 1) from n;
          Llvm.delete_instruction store)
        users;
      Llvm.delete_instruction load
    end
  in
  (* A load of more parts than LLVM moves as one value whose every use
     takes one part out of it, as a match arm reading one field of a large
     payload does, becomes a load of each such part from its address,
     where the whole was loaded, and so on into each part still too large. *)
  let i32 = Llvm.i32_type ctx in
  (* The alignment of the part at [path] in a value of type [t] that is
     [whole]-aligned: the largest power of two dividing both [whole] and
     the part's offset in bytes. *)
  let aligned_at t path whole =
    let offset, _ =
      Array.fold_left
        (fun (offset, t) i ->
          match Llvm.classify_type t with
          | Llvm.TypeKind.Struct ->
              ( Int64.add offset (Llvm_target.DataLayout.offset_of_element t i data_layout),
                (Llvm_extra.struct_element_types t).(i) )
          | _ ->
              let e = Llvm.element_type t in
              (Int64.add offset (Int64.mul (Int64.of_int i) (Llvm_target.DataLayout.abi_size e data_layout)), e))
        (0L, t) path
    in
    let rec fit a = if a <= 1 || Int64.rem offset (Int64.of_int a) = 0L then max a 1 else fit (a / 2) in
    fit whole
  in
  (* The address of the part at [path] in a value of type [t] at [p]: a
     struct's field is numbered in 32 bits, as LLVM requires, and an
     array's element in 64, so an index of 2^31 or more stays whole. *)
  let address b t p path =
    let rec go t = function
      | [] -> []
      | i :: rest -> (
          match Llvm.classify_type t with
          | Llvm.TypeKind.Struct -> Llvm.const_int i32 i :: go (Llvm_extra.struct_element_types t).(i) rest
          | _ -> Llvm.const_int i64 i :: go (Llvm.element_type t) rest)
    in
    Llvm.build_in_bounds_gep t p (Array.of_list (Llvm.const_int i64 0 :: go t (Array.to_list path))) "" b
  in
  let rec split load =
    let users = uses load in
    if
      parts (Llvm.type_of load) > most_parts
      && users <> []
      && List.for_all (fun u -> Llvm.instr_opcode u = Llvm.Opcode.ExtractValue) users
    then begin
      let t = Llvm.type_of load and src = Llvm.operand load 0 in
      let b = Llvm.builder_before ctx load in
      List.iter
        (fun x ->
          let at = address b t src (Llvm.indices x) in
          let part = Llvm.build_load (Llvm.type_of x) at "" b in
          Llvm.set_alignment (aligned_at t (Llvm.indices x) (Llvm.alignment load)) part;
          Llvm.replace_all_uses_with x part;
          Llvm.delete_instruction x;
          split part)
        users;
      Llvm.delete_instruction load
    end
  in
  let memset_type = Llvm.function_type (Llvm.void_type ctx) [| ptr; Llvm.i8_type ctx; i64; Llvm.i1_type ctx |] in
  let memset =
    lazy
      (match Llvm.lookup_function "llvm.memset.p0.i64" m with
      | Some f -> f
      | None -> Llvm.declare_function "llvm.memset.p0.i64" memset_type m)
  in
  (* A constant [c] of type [t] stored [align]-aligned at [p] by [b]: whole
     while LLVM can move it as one value, else nothing where it is
     undefined, zeros where it is all zeros, and otherwise each part at
     its address, and so on into each part still too large. A constant
     part is what `insertvalue` folds to when the first part put in is a
     constant. *)
  let rec put_constant b c t p align =
    if Llvm.is_undef c || Llvm.is_poison c then ()
    else if parts t <= most_parts then Llvm.set_alignment align (Llvm.build_store c p b)
    else if Llvm.is_null c then
      ignore
        (Llvm.build_call memset_type (Lazy.force memset)
           [| p; Llvm.const_int (Llvm.i8_type ctx) 0; Llvm.const_of_int64 i64 (size t) false; Llvm.const_int (Llvm.i1_type ctx) 0 |]
           "" b)
    else
      let n =
        match Llvm.classify_type t with
        | Llvm.TypeKind.Struct -> Array.length (Llvm_extra.struct_element_types t)
        | _ -> Llvm_extra.array_length t
      in
      for i = 0 to n - 1 do
        match Llvm.aggregate_element c i with
        | None -> ()
        | Some e ->
            put_constant b e (Llvm.type_of e) (address b t p [| i |]) (aligned_at t [| i |] align)
      done
  in
  (* A store of more parts than LLVM moves as one value, built by putting
     parts into another value one by one, as a constructor builds its
     struct, becomes a store of that other value, a part at a time when it
     is a constant, and then a store of each part at its address, in the
     order they were put in; and so on into each part still too large. A
     constant stored whole is put a part at a time too. *)
  let rec scatter store =
    let v = Llvm.operand store 0 and p = Llvm.operand store 1 in
    let rec unchain v puts =
      match Llvm.instr_opcode v with
      | Llvm.Opcode.InsertValue when List.length (uses v) = 1 ->
          unchain (Llvm.operand v 0) ((v, Llvm.indices v, Llvm.operand v 1) :: puts)
      | _ | (exception _) -> (v, puts)
    in
    let base, puts = unchain v [] in
    if parts (Llvm.type_of v) > most_parts && (puts <> [] || Llvm.is_constant base) then begin
      let t = Llvm.type_of v in
      let b = Llvm.builder_before ctx store in
      let put value at align =
        let s = Llvm.build_store value at b in
        Llvm.set_alignment align s;
        s
      in
      let align = Llvm.alignment store in
      let whole =
        if Llvm.is_constant base then begin
          put_constant b base t p align;
          None
        end
        else Some (put base p align)
      in
      let stores = List.map (fun (_, path, part) -> put part (address b t p path) (aligned_at t path align)) puts
      in
      Llvm.delete_instruction store;
      List.iter (fun (x, _, _) -> Llvm.delete_instruction x) (List.rev puts);
      Option.iter scatter whole;
      List.iter scatter stores
    end
  in
  let large_stores f =
    let found = ref [] in
    Llvm.iter_blocks
      (Llvm.iter_instrs (fun i ->
           if
             Llvm.instr_opcode i = Llvm.Opcode.Store
             && aggregate (Llvm.type_of (Llvm.operand i 0))
             && parts (Llvm.type_of (Llvm.operand i 0)) > most_parts
           then found := i :: !found))
      f;
    !found
  in
  Llvm.iter_functions
    (fun f ->
      if not (Llvm.is_declaration f) then begin
        List.iter scatter (large_stores f);
        List.iter split (large_loads f);
        List.iter (rewrite_load f) (large_loads f)
      end)
    m;
  (* A parameter or a result too large to move as one value: a signature
     passes such an aggregate by address (Emit.passing, Emit.returning), so
     one here is an invariant broken, not a limit of the program's. *)
  Llvm.iter_functions
    (fun f ->
      let fty = Llvm_extra.value_type f in
      List.iter
        (fun t ->
          if aggregate t && parts t > most_parts then
            Diagnostic.bug
              (Printf.sprintf "codegen: `%s` passes or returns a value of more than %d parts whole"
                 (Llvm.value_name f) most_parts))
        (Llvm.return_type fty :: Array.to_list (Llvm_extra.param_types fty)))
    m;
  (* What is still moved as one value. *)
  let too_large = ref None in
  Llvm.iter_functions
    (fun f ->
      Llvm.iter_blocks
        (Llvm.iter_instrs (fun i ->
             (* A store's own type is void: what it moves is its value. *)
             let t = if Llvm.instr_opcode i = Llvm.Opcode.Store then Llvm.type_of (Llvm.operand i 0) else Llvm.type_of i in
             if
               Option.is_none !too_large
               && Llvm.instr_opcode i <> Llvm.Opcode.Alloca
               && aggregate t && parts t > most_parts
             then too_large := Some ()))
        f)
    m;
  match !too_large with
  | None -> Ok ()
  | Some _ ->
      Error
        (Printf.sprintf
           "a value of more than %d parts is moved whole inside a function, and the code generator can \
            move at most that many as one value"
           most_parts)
