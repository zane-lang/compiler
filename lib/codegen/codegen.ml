(* Codegen's entry module (docs/design/lowering.md §1). *)

(* Lowering refuses each type that reaches the size limit (Cgt.Nodes.Ty.limit)
   where it is named. A frame is laid out here, from slots each below it, and
   one whose slots together reach it is refused as the build's error. *)
let emit ?target ?fixed_region ?spawned_fixed_region p =
  Result.bind (Build.target_machine ?target ~optimize:false ()) (fun (triple, tm) ->
      let data_layout = Llvm_target.DataLayout.as_string (Llvm_target.TargetMachine.data_layout tm) in
      match Emit.program ?fixed_region ?spawned_fixed_region ~triple ~data_layout p with
      | m -> Ok m
      | exception Cgt.Nodes.Ty.Too_large ->
          Error "a scope's frame takes 2^48 bytes or more, past the limit on any value's size")

let ir m = Llvm.string_of_llmodule m

let target_cpu ?target () =
  Result.map
    (fun (_, tm) -> Llvm_target.TargetMachine.cpu tm)
    (Build.target_machine ?target ~optimize:true ())

let executable ?target ?optimize ?link m output =
  Build.executable ?target ?optimize ?link m output
let object_file ?target ?optimize m output = Build.object_file ?target ?optimize m output
let prepare ?target ?optimize m = Result.map ignore (Build.prepare ?target ?optimize m)
