(* Codegen's entry module (docs/design/lowering.md §1). *)

type tier = Tiers.tier = Plain | Tier0 | Tier1

(* Lowering refuses each type that reaches the size limit (Cgt.Nodes.Ty.limit)
   where it is named. A frame is laid out here, from slots each below it, and
   one whose slots together reach it is refused as the build's error. *)

(* How many contexts [with_program] has made and not yet disposed, which
   the unit tests read. *)
let live = Atomic.make 0
let live_contexts () = Atomic.get live

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. *)
let with_module ?target ?pack ?memos ?fixed_region ?spawned_fixed_region p f =
  Result.bind (Build.target_machine ?target ~optimize:false ()) (fun (triple, tm) ->
      let data_layout = Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm) in
      let ctx = Llvm.create_context () in
      Atomic.incr live;
      Fun.protect
        ~finally:(fun () ->
          Llvm.dispose_context ctx;
          Atomic.decr live)
        (fun () ->
          let m = Llvm.create_module ctx "zane" in
          Fun.protect
            ~finally:(fun () -> Llvm.dispose_module m)
            (fun () ->
              match Emit.program ?fixed_region ?spawned_fixed_region ?pack ?memos ~triple ~data_layout m p with
              | () -> f m
              | exception Cgt.Nodes.Ty.Too_large ->
                  Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")))

(* The symbols of the functions an optimized build still calls from some
   other function once LLVM's `-O2` has run over the program as it is: a
   function whose every call LLVM inlined and folded has nothing left for a
   table to save, and a dispatcher would only stop LLVM folding it. *)
let still_called ?target ?pack ?fixed_region ?spawned_fixed_region p =
  let called = Hashtbl.create 64 in
  let names = Hashtbl.create 64 in
  List.iter
    (fun (f : Cgt.Nodes.Func.t) ->
      let s = f.Cgt.Nodes.Func.symbol in
      Hashtbl.replace names (if pack = Some true then s ^ Emit.packed else s) s)
    p.Cgt.Nodes.Program.funcs;
  let found =
    with_module ?target ?pack ?fixed_region ?spawned_fixed_region p (fun m ->
        Result.map
          (fun _ ->
            Llvm.iter_functions
              (fun fn ->
                match Hashtbl.find_opt names (Llvm.value_name fn) with
                | None -> ()
                | Some s ->
                    let rec uses = function
                      | None -> ()
                      | Some u ->
                          let user = Llvm.user u in
                          (match Llvm.classify_value user with
                          | Llvm.ValueKind.Instruction _ ->
                              if Llvm.block_parent (Llvm.instr_parent user) != fn then Hashtbl.replace called s ()
                          | _ -> Hashtbl.replace called s ());
                          uses (Llvm.use_succ u)
                    in
                    uses (Llvm.use_begin fn))
              m)
          (Build.prepare ?target ~optimize:true m))
  in
  match found with Ok () -> fun s -> Hashtbl.mem called s | Error _ -> fun _ -> false

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. With [memoize], the functions [Cgt.Memo]
   picks are remembered; in an [optimize]d build, only those
   [still_called] leaves. *)
let with_program ?target ?pack ?(memoize = false) ?(optimize = false) ?fixed_region ?spawned_fixed_region p f =
  let p, memos =
    if not memoize then (p, [])
    else if optimize then Cgt.Memo.plan ~keep:(still_called ?target ?pack ?fixed_region ?spawned_fixed_region p) p
    else Cgt.Memo.plan p
  in
  with_module ?target ?pack ~memos ?fixed_region ?spawned_fixed_region p f

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let executable ?target ?optimize ?tier ?link m output =
  Build.executable ?target ?optimize ?tier ?link m output
let shared_library ?target m output = Build.shared_library ?target m output
let object_file ?target ?optimize ?tier m output = Build.object_file ?target ?optimize ?tier m output
let prepare ?target ?optimize ?tier m = Result.map ignore (Build.prepare ?target ?optimize ?tier m)
let bundle_runtime ~target ~optimize dir = Build.bundle_runtime ~target ~optimize dir
