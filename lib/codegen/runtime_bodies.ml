(* The runtime's bodies for LLVM to inline (docs/design/lowering.md §7). The
   runtime is compiled to LLVM bitcode as well as to its object, and before
   an optimized build's passes the bodies of the runtime's functions the
   program calls are linked into its module as `available_externally`: LLVM
   may inline them, and calls it does not inline, and every address taken,
   still go to the runtime the program links with. Nothing the runtime keeps
   is copied: each of its variables is linked in as a declaration of the
   one the runtime defines. A body is left out, and the call stays a call,
   when it reaches a variable of the runtime's own translation unit, which
   no other unit can name, or takes the address of one of its functions,
   which a copy would not share, or calls one that is never inlined, which
   would be copied into the program whole. A function marked cold keeps its
   call too: it runs off the hot path, where its body would only cost the
   caller registers. *)

external delete_body : Llvm.llvalue -> unit = "zane_delete_body"

let internal v = match Llvm.linkage v with Llvm.Linkage.Internal | Llvm.Linkage.Private -> true | _ -> false
let is_function v = Llvm.classify_value v = Llvm.ValueKind.Function
let is_variable v = Llvm.classify_value v = Llvm.ValueKind.GlobalVariable

(* Whether the runtime keeps something in [v]: a variable of its own unit
   that changes. *)
let state v = is_variable v && internal v && not (Llvm.is_global_constant v)

let rec references acc v =
  match Llvm.classify_value v with
  | Llvm.ValueKind.Function | Llvm.ValueKind.GlobalVariable | Llvm.ValueKind.GlobalAlias -> v :: acc
  | Llvm.ValueKind.ConstantExpr | Llvm.ValueKind.ConstantStruct | Llvm.ValueKind.ConstantArray
  | Llvm.ValueKind.ConstantVector ->
      let n = Llvm.num_operands v in
      let rec go acc i = if i = n then acc else go (references acc (Llvm.operand v i)) (i + 1) in
      go acc 0
  | _ -> acc

(* What [f]'s body calls, and everything else it refers to. *)
let uses f =
  let calls = ref [] and refers = ref [] in
  Llvm.iter_blocks
    (fun b ->
      Llvm.iter_instrs
        (fun i ->
          let n = Llvm.num_operands i in
          let call = match Llvm.instr_opcode i with Llvm.Opcode.Call | Llvm.Opcode.Invoke -> true | _ -> false in
          for j = 0 to n - 1 do
            let v = Llvm.operand i j in
            if call && j = n - 1 && is_function v then calls := v :: !calls else refers := references !refers v
          done)
        b)
    f;
  (!calls, !refers)

let marked f names =
  Array.exists
    (fun a ->
      match Llvm.repr_of_attr a with
      | Llvm.AttrRepr.Enum (kind, _) -> List.exists (fun n -> kind = Llvm.enum_attr_kind n) names
      | Llvm.AttrRepr.String _ -> false)
    (Emit.function_attrs f Llvm.AttrIndex.Function)

(* Whether [v] is a function from outside the runtime, such as the C
   library's; LLVM's own intrinsics are not. *)
let foreign v =
  is_function v && Llvm.is_declaration v && not (String.starts_with ~prefix:"llvm." (Llvm.value_name v))

let protections = [ "ssp"; "sspstrong"; "sspreq" ]

(* [rt] made ready to link into [m]: the bodies kept are those of the
   runtime's functions [m] calls, and what they call in turn, that are safe
   to copy. A tiered build also leaves out a body that calls outside the
   runtime, since tier 1 imports everything through tier 0's table
   (docs/design/tiers.md), and an entry for the C library's function is a
   symbol the loader looks up as every run starts. A body kept loses any
   stack protection the runtime was compiled with: it becomes the program's
   code, which has none, and inlined, it would protect its caller too. *)
let prune ~tiered m rt =
  let defined = Llvm.fold_left_functions (fun acc f -> if Llvm.is_declaration f then acc else f :: acc) [] rt in
  let table = Hashtbl.create 128 in
  List.iter (fun f -> Hashtbl.replace table f (uses f)) defined;
  let calls f = fst (Hashtbl.find table f) in
  let unsafe = Hashtbl.create 128 in
  List.iter
    (fun f ->
      let calls, refers = Hashtbl.find table f in
      if
        List.exists (fun v -> state v || (is_function v && internal v)) refers
        || List.exists (fun c -> internal c && marked c [ "noinline"; "cold" ]) calls
        || (tiered && List.exists foreign (calls @ refers))
      then Hashtbl.replace unsafe f ())
    defined;
  let rec spread () =
    let changed =
      List.fold_left
        (fun changed f ->
          if (not (Hashtbl.mem unsafe f))
             && List.exists (fun c -> internal c && Hashtbl.mem unsafe c) (calls f)
          then (
            Hashtbl.replace unsafe f ();
            true)
          else changed)
        false defined
    in
    if changed then spread ()
  in
  spread ();
  let reached = Hashtbl.create 128 in
  let rec reach f =
    if Hashtbl.mem table f && (not (Hashtbl.mem reached f)) && (not (Hashtbl.mem unsafe f)) && not (marked f [ "cold" ])
    then begin
      Hashtbl.replace reached f ();
      List.iter reach (calls f)
    end
  in
  Llvm.iter_functions
    (fun f ->
      if Llvm.is_declaration f then
        match Llvm.lookup_function (Llvm.value_name f) rt with Some g when not (internal g) -> reach g | _ -> ())
    m;
  List.iter
    (fun f ->
      if not (internal f) then
        if Hashtbl.mem reached f then Llvm.set_linkage Llvm.Linkage.Available_externally f else delete_body f)
    defined;
  (* A thread's variable is read as the program reads its own, at a fixed
     offset from the thread's pointer (Walks.zane_open), whatever model the
     runtime was compiled for. *)
  Llvm.iter_globals
    (fun g ->
      if not (internal g) then begin
        if not (Llvm.is_declaration g) then begin
          Llvm.remove_initializer g;
          Llvm.set_linkage Llvm.Linkage.External g
        end;
        if Llvm.is_thread_local g then Llvm.set_thread_local_mode Llvm.ThreadLocalMode.InitialExec g
      end)
    rt;
  let appending = Llvm.fold_left_globals (fun acc g -> if Llvm.linkage g = Llvm.Linkage.Appending then g :: acc else acc) [] rt in
  List.iter Llvm.delete_global appending;
  (* What only the bodies left out used, until nothing is left unused. *)
  let rec sweep () =
    let unused v = internal v && Llvm.use_begin v = None in
    let fs = Llvm.fold_left_functions (fun acc f -> if unused f then f :: acc else acc) [] rt in
    let gs = Llvm.fold_left_globals (fun acc g -> if unused g then g :: acc else acc) [] rt in
    List.iter Llvm.delete_function fs;
    List.iter Llvm.delete_global gs;
    if fs <> [] || gs <> [] then sweep ()
  in
  sweep ();
  Llvm.iter_functions
    (fun f ->
      if not (Llvm.is_declaration f) then
        List.iter (fun n -> Llvm.remove_enum_function_attr f (Llvm.enum_attr_kind n) Llvm.AttrIndex.Function) protections)
    rt

(* The bodies in the bitcode at [path] linked into [m]; false, and [m]
   untouched, when there is none or this LLVM cannot read it, as when a
   newer one wrote it. *)
(* The bitcode at [path] in [ctx], or [None] when this LLVM cannot read
   it. LLVM reports bitcode it cannot read to the context's handler, whose
   default ends the process, so one is set while it is read. *)
let read ctx path =
  match Llvm.MemoryBuffer.of_file path with
  | exception Llvm.IoError _ -> None
  | buffer ->
      let failed = ref false in
      Llvm.set_diagnostic_handler ctx
        (Some (fun d -> if Llvm.Diagnostic.severity d = Llvm.DiagnosticSeverity.Error then failed := true));
      let parsed =
        Fun.protect
          ~finally:(fun () ->
            Llvm.set_diagnostic_handler ctx None;
            Llvm.MemoryBuffer.dispose buffer)
          (fun () -> try Some (Llvm_bitreader.parse_bitcode ctx buffer) with Llvm_bitreader.Error _ -> None)
      in
      match parsed with
      | Some rt when !failed ->
          Llvm.dispose_module rt;
          None
      | parsed -> parsed

let add ~tiered path m =
  match read (Llvm.module_context m) path with
  | None -> false
  | Some rt ->
      prune ~tiered m rt;
      Llvm.set_target_triple (Llvm.target_triple m) rt;
      Llvm.set_data_layout (Llvm.data_layout m) rt;
      Llvm_linker.link_modules m rt;
      true

(* Whether this LLVM reads the bitcode at [path]. *)
let readable path =
  let ctx = Llvm.create_context () in
  let rt = read ctx path in
  Option.iter Llvm.dispose_module rt;
  Llvm.dispose_context ctx;
  Option.is_some rt
