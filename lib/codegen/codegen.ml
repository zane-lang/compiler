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
let with_module ?target ?pack ?memos ?version ?fixed_region ?spawned_fixed_region p f =
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
              match Emit.program ?fixed_region ?spawned_fixed_region ?pack ?memos ?version ~triple ~data_layout m p with
              | () -> f m
              | exception Cgt.Nodes.Ty.Too_large ->
                  Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")))

(* The program's module lives only while [f] runs: its context and the
   module are disposed however [f] or the emit ends, since LLVM's bindings
   free neither on their own. With [memoize], the functions [Cgt.Memo]
   picks are remembered, the same in every build, so a tiered build's two
   tiers emit the same module (docs/design/tiers.md T3). With [version],
   each loop over elements the optimized passes can split is emitted twice
   for them to tell apart (Emit.versioned); a tiered build's two tiers
   both take it. *)
let with_program ?target ?pack ?(memoize = false) ?version ?fixed_region ?spawned_fixed_region p f =
  let p, memos = if memoize then Cgt.Memo.plan p else (p, []) in
  with_module ?target ?pack ~memos ?version ?fixed_region ?spawned_fixed_region p f

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
