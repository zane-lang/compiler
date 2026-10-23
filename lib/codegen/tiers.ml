(* Tiered builds (docs/design/tiers.md). Tier 0 is an unoptimized program
   whose calls to its own functions go through a slot each; tier 1 is the
   same program optimized into a shared library, which the runtime loads
   while tier 0 runs and points the slots at (runtime/tier.c). Tier 1 takes
   whatever it does not define from tier 0 through a table of its own,
   which the runtime fills from tier 0's, so it links against nothing but
   the C library on every platform. *)

external value_type : Llvm.llvalue -> Llvm.lltype = "zane_global_value_type"
external set_ordering : Llvm.llvalue -> bool -> unit = "zane_set_ordering"

(* [global]'s every use made a load of the [index]th pointer of [table];
   false when one is a constant that no instruction holds, such as another
   variable's initial value (llvm_stubs.cpp). *)
external import_uses : Llvm.llvalue -> Llvm.llvalue -> int -> bool = "zane_tier_import"

type tier = Plain | Tier0 | Tier1

(* The module's fingerprint, taken before anything changes it. Tier 0 and
   tier 1 lower the same tree and emit the same module, so the runtime
   loads tier 1 only into the program whose fingerprint it carries. *)
let fingerprint m = Digest.to_hex (Digest.string (Llvm.string_of_llmodule m))

let intrinsic v = String.starts_with ~prefix:"llvm." (Llvm.value_name v)

(* A function this module defines a body of its own for. *)
let own f =
  (not (Llvm.is_declaration f)) && Llvm.linkage f <> Llvm.Linkage.Available_externally && not (intrinsic f)

(* The functions that move to tier 1: each the program defines, and none
   of those made here for tier 0 itself. *)
let functions m =
  List.rev
    (Llvm.fold_left_functions
       (fun acc f -> if own f && not (String.ends_with ~suffix:".tier.address" (Llvm.value_name f)) then f :: acc else acc)
       [] m)

(* What tier 1 may take from tier 0, by name: each function and variable
   the module declares, each body it has only to inline, and each variable
   whose value changes while the program runs, a package constant's or a
   memo table's, so the program has one of each. Both tiers read it from
   the module as emitted, so they list the same. *)
let shared m =
  let fs =
    Llvm.fold_left_functions
      (fun acc f ->
        if intrinsic f then acc
        else if Llvm.is_declaration f || Llvm.linkage f = Llvm.Linkage.Available_externally then f :: acc
        else acc)
      [] m
  in
  let gs =
    Llvm.fold_left_globals
      (fun acc g -> if Llvm.is_declaration g || not (Llvm.is_global_constant g) then g :: acc else acc)
      [] m
  in
  List.sort (fun a b -> compare (Llvm.value_name a) (Llvm.value_name b)) (fs @ gs)

(* A function's key: its symbol and its type, so a body is put in a slot
   only where tier 0 calls it as it is written. *)
let key f = Llvm.value_name f ^ " " ^ Llvm.string_of_lltype (value_type f)

let text m s =
  let g = Llvm.define_global "zane.tier.text" (Llvm.const_stringz (Llvm.module_context m) s) m in
  Llvm.set_linkage Llvm.Linkage.Private g;
  Llvm.set_global_constant true g;
  Llvm.set_unnamed_addr true g;
  g

let ptr m = Llvm.pointer_type (Llvm.module_context m)
let i64 m n = Llvm.const_int (Llvm.i64_type (Llvm.module_context m)) n

(* An array of (text, pointer) pairs under [name], sorted by the text, and
   how many there are. *)
let pairs m name rows =
  let ctx = Llvm.module_context m in
  let entry = Llvm.struct_type ctx [| ptr m; ptr m |] in
  let rows = List.sort (fun (a, _) (b, _) -> compare a b) rows in
  let body = Llvm.const_array entry (Array.of_list (List.map (fun (k, p) -> Llvm.const_struct ctx [| text m k; p |]) rows)) in
  let g = Llvm.define_global name body m in
  Llvm.set_linkage Llvm.Linkage.Internal g;
  Llvm.set_global_constant true g;
  (List.length rows, g)

(* A thread-local variable's address on the thread that asks: a function
   of tier 0's, which tier 1 calls where it reads the variable. *)
let thread_address m g =
  let ctx = Llvm.module_context m in
  let f = Llvm.define_function (Llvm.value_name g ^ ".tier.address") (Llvm.function_type (ptr m) [||]) m in
  Llvm.set_linkage Llvm.Linkage.Internal f;
  let b = Llvm.builder_at_end ctx (Llvm.entry_block f) in
  let intrinsic =
    match Llvm.lookup_function "llvm.threadlocal.address.p0" m with
    | Some i -> i
    | None -> Llvm.declare_function "llvm.threadlocal.address.p0" (Llvm.function_type (ptr m) [| ptr m |]) m
  in
  ignore (Llvm.build_ret (Llvm.build_call (Llvm.function_type (ptr m) [| ptr m |]) intrinsic [| g |] "" b) b);
  f

(* Tier 0, before its passes: the table of what tier 1 may import, which
   also keeps each of them through the passes. *)
let exports m =
  pairs m "zane.tier.exports"
    (List.map
       (fun v ->
         let thread = Llvm.classify_value v = Llvm.ValueKind.GlobalVariable && Llvm.is_thread_local v in
         (Llvm.value_name v, if thread then thread_address m v else v))
       (shared m))

let copy_attrs ~from ~into ~site =
  let n = Array.length (Llvm.params from) in
  let at i = Emit.function_attrs from i in
  Array.iter (fun a -> Llvm.add_function_attr into a Llvm.AttrIndex.Function) (at Llvm.AttrIndex.Function);
  List.iter
    (fun i ->
      Array.iter
        (fun a ->
          Llvm.add_function_attr into a i;
          Option.iter (fun s -> Llvm.add_call_site_attr s a i) site)
        (at i))
    (Llvm.AttrIndex.Return :: List.init n (fun i -> Llvm.AttrIndex.Param i))

(* Tier 0, after its passes: a slot for each function it defines, every
   direct call to one made through its slot, and every other use, a
   function value, made a use of an entry that calls through it, so a
   lambda moves to tier 1 too. The entry function then hands the runtime
   the slots and the exports (runtime/tier.c). *)
let tier0 m ~hash ~exports:(count, table) =
  let ctx = Llvm.module_context m in
  let p = ptr m in
  let fs = functions m in
  let slots = Hashtbl.create 64 in
  List.iter
    (fun f ->
      let g = Llvm.define_global (Llvm.value_name f ^ ".tier") (Llvm.const_null p) m in
      Llvm.set_linkage Llvm.Linkage.Internal g;
      Hashtbl.replace slots f g)
    fs;
  let through slot b =
    let v = Llvm.build_load p slot "" b in
    set_ordering v true;
    v
  in
  List.iter
    (fun fn ->
      Llvm.iter_blocks
        (fun bb ->
          Llvm.iter_instrs
            (fun i ->
              if Llvm.instr_opcode i = Llvm.Opcode.Call then
                let n = Llvm.num_operands i in
                match Hashtbl.find_opt slots (Llvm.operand i (n - 1)) with
                | Some slot -> Llvm.set_operand i (n - 1) (through slot (Llvm.builder_before ctx i))
                | None -> ())
            bb)
        fn)
    fs;
  List.iter
    (fun f ->
      let slot = Hashtbl.find slots f in
      if Option.is_some (Llvm.use_begin f) then begin
        let fty = value_type f in
        let entry = Llvm.define_function (Llvm.value_name f ^ ".tier.entry") fty m in
        Llvm.set_linkage Llvm.Linkage.Internal entry;
        Llvm.set_function_call_conv (Llvm.function_call_conv f) entry;
        Llvm.replace_all_uses_with f entry;
        let b = Llvm.builder_at_end ctx (Llvm.entry_block entry) in
        let call = Llvm.build_call fty (through slot b) (Llvm.params entry) "" b in
        Llvm.set_instruction_call_conv (Llvm.function_call_conv f) call;
        Llvm.set_tail_call true call;
        copy_attrs ~from:f ~into:entry ~site:(Some call);
        if Llvm.classify_type (Llvm.return_type fty) = Llvm.TypeKind.Void then ignore (Llvm.build_ret_void b)
        else ignore (Llvm.build_ret call b)
      end;
      Llvm.set_initializer f slot)
    fs;
  let count_slots, slot_table = pairs m "zane.tier.slots" (List.map (fun f -> (key f, Hashtbl.find slots f)) fs) in
  let record =
    Llvm.const_struct ctx [| text m hash; i64 m count_slots; slot_table; i64 m count; table |]
  in
  let tier0 = Llvm.define_global "zane.tier0" record m in
  Llvm.set_linkage Llvm.Linkage.Internal tier0;
  Llvm.set_global_constant true tier0;
  match Llvm.lookup_function "zane_main" m with
  | None -> ()
  | Some main ->
      let up =
        match Llvm.lookup_function "zane_tier_up" m with
        | Some f -> f
        | None -> Llvm.declare_function "zane_tier_up" (Llvm.function_type (Llvm.void_type ctx) [| p |]) m
      in
      let first = Llvm.instr_begin (Llvm.entry_block main) in
      let b = match first with Llvm.Before i -> Llvm.builder_before ctx i | Llvm.At_end bb -> Llvm.builder_at_end ctx bb in
      ignore (Llvm.build_call (Llvm.function_type (Llvm.void_type ctx) [| p |]) up [| tier0 |] "" b)

(* How many scalars a value of [t] holds, counting each element of an
   array and each member of a struct. *)
let rec scalars t =
  match Llvm.classify_type t with
  | Llvm.TypeKind.Array -> Emit.array_length t * scalars (Llvm.element_type t)
  | Llvm.TypeKind.Struct -> Array.fold_left (fun n m -> n + scalars m) 0 (Emit.struct_element_types t)
  | _ -> 1

(* The most scalars a frame of tier 1 may hold for its function to be
   optimized. LLVM's instruction combining walks every use of a frame's
   slot each time it visits one, so a frame holding an array of a hundred
   thousand values keeps it for minutes; the unoptimized pipeline leaves
   that pass out for the same reason (Passes.unoptimized). *)
let largest_frame = 4096

(* Each function whose frame holds more than [largest_frame] scalars
   marked to be left as it is, and never written into another, so the
   pipeline passes it by. It runs as tier 0 would run it. *)
let keep_large_frames m =
  let ctx = Llvm.module_context m in
  let attr name = Llvm.create_enum_attr ctx name 0L in
  List.iter
    (fun f ->
      let large = ref false in
      Llvm.iter_blocks
        (fun bb ->
          Llvm.iter_instrs
            (fun i ->
              if Llvm.instr_opcode i = Llvm.Opcode.Alloca && scalars (Wrappers.allocated_type i) > largest_frame then
                large := true)
            bb)
        f;
      if !large then begin
        Llvm.remove_enum_function_attr f (Llvm.enum_attr_kind "alwaysinline") Llvm.AttrIndex.Function;
        Llvm.remove_enum_function_attr f (Llvm.enum_attr_kind "inlinehint") Llvm.AttrIndex.Function;
        List.iter (fun a -> Llvm.add_function_attr f (attr a) Llvm.AttrIndex.Function) [ "optnone"; "noinline" ]
      end)
    (functions m)

(* Tier 1, before its pipeline: every function it defines kept to this
   library and listed by key, which also keeps each one, with its type,
   through the pipeline; every changing variable made a declaration, so the
   pipeline assumes nothing of its value. Gives what [tier1_imports] needs
   after the pipeline. *)
let tier1_definitions m =
  let names = List.map Llvm.value_name (shared m) in
  List.iter
    (fun g ->
      if (not (Llvm.is_declaration g)) && not (Llvm.is_global_constant g) then begin
        Llvm.remove_initializer g;
        Llvm.set_linkage Llvm.Linkage.External g
      end)
    (Llvm.fold_left_globals (fun acc g -> g :: acc) [] m);
  keep_large_frames m;
  let fs = functions m in
  List.iter
    (fun f ->
      Llvm.set_linkage Llvm.Linkage.Internal f;
      Llvm.set_visibility Llvm.Visibility.Default f)
    fs;
  let ((_, table) as defs) = pairs m "zane.tier.defs" (List.map (fun f -> (key f, f)) fs) in
  (* Seen from outside, so the pipeline keeps it, and each function in it,
     until `__zane_tier1` holds it. *)
  Llvm.set_linkage Llvm.Linkage.External table;
  Llvm.set_visibility Llvm.Visibility.Hidden table;
  (names, defs)

(* Tier 1, after its pipeline: each of [names] it still uses read from its
   import table, which the runtime fills with tier 0's, and the one record
   the runtime looks up, `__zane_tier1`. Error names a use that cannot be
   read so. *)
let tier1_imports m ~hash (names, (count_defs, defs)) =
  let ctx = Llvm.module_context m in
  let p = ptr m in
  let used =
    List.filter_map
      (fun name ->
        let v =
          match Llvm.lookup_function name m with Some f -> Some f | None -> Llvm.lookup_global name m
        in
        match v with Some v when Option.is_some (Llvm.use_begin v) -> Some (name, v) | _ -> None)
      names
  in
  let n = List.length used in
  let table = Llvm.define_global "zane.tier.imports" (Llvm.const_null (Llvm.array_type p (max n 1))) m in
  Llvm.set_visibility Llvm.Visibility.Hidden table;
  let rec go i = function
    | [] -> Ok ()
    | (name, v) :: rest ->
        if import_uses v table i then begin
          (match Llvm.classify_value v with
          | Llvm.ValueKind.Function -> Llvm.delete_function v
          | _ -> Llvm.delete_global v);
          go (i + 1) rest
        end
        else Error (Printf.sprintf "tier 1 cannot import `%s`: a constant holds its address" name)
  in
  Result.map
    (fun () ->
      let names_array = Llvm.const_array p (Array.of_list (List.map (fun (name, _) -> text m name) used)) in
      let names_table = Llvm.define_global "zane.tier.names" names_array m in
      Llvm.set_linkage Llvm.Linkage.Internal names_table;
      Llvm.set_global_constant true names_table;
      let record =
        Llvm.const_struct ctx [| text m hash; i64 m count_defs; defs; i64 m n; names_table; table |]
      in
      let g = Llvm.define_global "__zane_tier1" record m in
      Llvm.set_global_constant true g;
      Llvm.set_dll_storage_class Llvm.DLLStorageClass.DLLExport g)
    (go 0 used)
