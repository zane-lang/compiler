(* Codegen's entry module (docs/design/lowering.md §1). *)

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
let with_program ?target ?pack ?fixed_region ?spawned_fixed_region p f =
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
              match Emit.program ?fixed_region ?spawned_fixed_region ?pack ~triple ~data_layout m p with
              | () -> f m
              | exception Cgt.Nodes.Ty.Too_large ->
                  Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")))

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let executable ?target ?optimize ?link m output =
  Build.executable ?target ?optimize ?link m output
let object_file ?target ?optimize m output = Build.object_file ?target ?optimize m output
let prepare ?target ?optimize m = Result.map ignore (Build.prepare ?target ?optimize m)
let bundle_runtime ~target ~optimize dir = Build.bundle_runtime ~target ~optimize dir
