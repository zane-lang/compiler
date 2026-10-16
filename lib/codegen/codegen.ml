(* Codegen's entry module (docs/design/lowering.md §1). *)

let emit ?target ?fixed_region ?spawned_fixed_region p =
  Result.map
    (fun (triple, tm) ->
      let data_layout = Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm) in
      Emit.program ?fixed_region ?spawned_fixed_region ~triple ~data_layout p)
    (Build.target_machine ?target ~optimize:false ())

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let executable ?target ?optimize ?link m output =
  Build.executable ?target ?optimize ?link m output
let object_file ?target ?optimize m output = Build.object_file ?target ?optimize m output
let prepare ?target ?optimize m = Result.map ignore (Build.prepare ?target ?optimize m)
