(* Experimental tiered builds (ZANE_TIER). Tier 0 is an unoptimized program
   whose calls between its own functions go through a slot each, which a
   runtime thread fills from tier 1, an optimized build of the same program
   loaded as a shared object while tier 0 runs. Both name each function by
   its symbol and its type, so only a body meant for a slot fills it. *)

let mode () = Sys.getenv_opt "ZANE_TIER"

let tiered f =
  (not (Llvm.is_declaration f))
  && Llvm.linkage f <> Llvm.Linkage.Available_externally
  && not (String.starts_with ~prefix:"llvm." (Llvm.value_name f))

(* The bindings give no function's type, so it is read from its parameters
   and from the first value it returns. *)
let key f =
  let ret = ref "void" in
  (try
     Llvm.iter_blocks
       (fun bb ->
         match Llvm.block_terminator bb with
         | Some t when Llvm.instr_opcode t = Llvm.Opcode.Ret && Llvm.num_operands t = 1 ->
             ret := Llvm.string_of_lltype (Llvm.type_of (Llvm.operand t 0));
             raise Exit
         | _ -> ())
       f
   with Exit -> ());
  let params = Array.to_list (Array.map (fun p -> Llvm.string_of_lltype (Llvm.type_of p)) (Llvm.params f)) in
  String.concat "|" ((Llvm.value_name f :: !ret :: params))

let text m name s =
  let ctx = Llvm.module_context m in
  let g = Llvm.define_global name (Llvm.const_stringz ctx s) m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  g

(* A table of [count, (key, pointer)...] under [name], seen by dlsym. *)
let table m name entries =
  let ctx = Llvm.module_context m in
  let ptr = Llvm.pointer_type ctx and i64 = Llvm.i64_type ctx in
  let entry = Llvm.struct_type ctx [| ptr; ptr |] in
  let rows =
    List.mapi (fun i (k, p) -> Llvm.const_struct ctx [| text m (Printf.sprintf "zane.tier.key.%d" i) k; p |]) entries
  in
  let body =
    Llvm.const_struct ctx
      [| Llvm.const_int i64 (List.length rows); Llvm.const_array entry (Array.of_list rows) |]
  in
  let g = Llvm.define_global name body m in
  Llvm.set_global_constant true g;
  ignore ptr

let functions m = Llvm.fold_left_functions (fun acc f -> if tiered f then f :: acc else acc) [] m |> List.rev

(* Tier 1, before its pipeline runs: every function it defines, by key. Each
   is taken by address, so the pipeline keeps its type. *)
let definitions m = table m "__zane_tier_defs" (List.map (fun f -> (key f, f)) (functions m))

(* Tier 0, after its passes: a slot for each function, and each direct call
   to one made through its slot. *)
let slots m =
  let ctx = Llvm.module_context m in
  let ptr = Llvm.pointer_type ctx in
  let fs = functions m in
  let slot = Hashtbl.create 64 in
  List.iter
    (fun f ->
      let g = Llvm.define_global (Llvm.value_name f ^ ".tier") f m in
      Llvm.set_linkage Llvm.Linkage.Internal g;
      Hashtbl.replace slot f g)
    fs;
  List.iter
    (fun fn ->
      Llvm.iter_blocks
        (fun bb ->
          Llvm.iter_instrs
            (fun i ->
              if Llvm.instr_opcode i = Llvm.Opcode.Call then
                let n = Llvm.num_operands i in
                let callee = Llvm.operand i (n - 1) in
                match Hashtbl.find_opt slot callee with
                | Some g ->
                    let loaded = Llvm.build_load ptr g "" (Llvm.builder_before ctx i) in
                    Llvm.set_operand i (n - 1) loaded
                | None -> ())
            bb)
        fn)
    fs;
  table m "__zane_tier_slots" (List.map (fun f -> (key f, Hashtbl.find slot f)) fs)
