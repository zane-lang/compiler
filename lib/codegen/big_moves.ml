(* Large aggregates moved as memory (docs/design/lowering.md §9).

   Emit moves a value as one LLVM value, a load and then a store, which is
   what a small value wants. LLVM's code generator gives a value at most
   65,535 parts, though, and dies on a larger one, such as an
   `@primitives$ArrayRef<Int, 65536>` moved into its slot; well below that
   it still takes seconds per move. So a load of a large aggregate whose
   only uses are stores becomes a `memcpy` per store, and a large aggregate
   left anywhere else is reported as a limit rather than crashing LLVM. *)

(* Aggregates of this many bytes or more are moved as memory. *)
let large = 4096L

(* LLVM's limit on the parts of one value. *)
let most_parts = 65535

let rec parts t =
  match Llvm.classify_type t with
  | Llvm.TypeKind.Array -> Llvm.array_length t * parts (Llvm.element_type t)
  | Llvm.TypeKind.Struct -> Array.fold_left (fun n e -> n + parts e) 0 (Llvm.struct_element_types t)
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
  let copy b dst src size =
    ignore
      (Llvm.build_call memcpy_type (Lazy.force memcpy)
         [| dst; src; Llvm.const_of_int64 i64 size false; Llvm.const_int (Llvm.i1_type ctx) 0 |]
         "" b)
  in
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
  Llvm.iter_functions
    (fun f ->
      if not (Llvm.is_declaration f) then
        List.iter
          (fun load ->
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
                  copy (Llvm.builder_before ctx store) (Llvm.operand store 1) from n;
                  Llvm.delete_instruction store)
                users;
              Llvm.delete_instruction load
            end)
          (large_loads f))
    m;
  (* What is still moved as one value. *)
  let too_large = ref None in
  Llvm.iter_functions
    (fun f ->
      Llvm.iter_blocks
        (Llvm.iter_instrs (fun i ->
             let t = Llvm.type_of i in
             if
               Option.is_none !too_large
               && Llvm.instr_opcode i <> Llvm.Opcode.Alloca
               && aggregate t && parts t > most_parts
             then too_large := Some (parts t)))
        f)
    m;
  match !too_large with
  | None -> Ok ()
  | Some n ->
      Error
        (Printf.sprintf
           "a value of %d parts is passed or returned whole, and the code generator can move at \
            most %d parts as one value"
           n most_parts)
