/* What a build's target machine needs of LLVM that neither its C API nor
   its OCaml bindings give (docs/design/ffi.md F14): an ELF object's
   constructors and destructors placed in `.init_array` and `.fini_array`,
   as clang places them. LLVM's default is `.ctors` and `.dtors`, which the
   C library does not run, so a C constructor the optimizer did not fold
   into its variables' values would never run. Other formats ignore it. */

#include "llvm/Target/TargetMachine.h"

extern "C" {
#include <caml/custom.h>
#include <caml/mlvalues.h>
}

/* The OCaml bindings hold an [LLVMTargetMachineRef], a pointer to the
   machine, in a custom block. The object-file lowering reads the option
   each time the machine emits, so setting it after creation suffices. */
extern "C" value zane_use_init_array(value machine) {
  llvm::TargetMachine *tm = *reinterpret_cast<llvm::TargetMachine **>(Data_custom_val(machine));
  tm->Options.UseInitArray = true;
  return Val_unit;
}
