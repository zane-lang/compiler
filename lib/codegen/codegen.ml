(* Codegen's entry module (docs/lowering.md §1). *)

let emit = Emit.program
let ir m = Llvm.string_of_llmodule m

let executable m output = Build.executable m output
let prepare m = ignore (Build.prepare m)
