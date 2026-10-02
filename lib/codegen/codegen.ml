(* Codegen's entry module (docs/design/lowering.md §1). *)

let emit = Emit.program
let ir m = Llvm.string_of_llmodule m

let executable ?target m output = Build.executable ?target m output
let prepare ?target m = Result.map ignore (Build.prepare ?target m)
