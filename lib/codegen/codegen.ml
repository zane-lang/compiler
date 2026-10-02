(* Codegen's entry module (docs/design/lowering.md §1). *)

let emit = Emit.program
let ir m = Llvm.string_of_llmodule m

let executable ?target ?optimize m output = Build.executable ?target ?optimize m output
let object_file ?target ?optimize m output = Build.object_file ?target ?optimize m output
let prepare ?target ?optimize m = Result.map ignore (Build.prepare ?target ?optimize m)
