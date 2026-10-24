/* What linking the runtime's bodies into a program needs of LLVM that its C
   API does not give (Runtime_bodies): a function's body dropped, leaving its
   declaration, with every reference inside the body let go first, so a
   branch to a block or a use of a value the body made never outlives it. */

#include "llvm/IR/Function.h"

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Value *from_val(value v) { return reinterpret_cast<llvm::Value *>(v & ~(value)1); }

extern "C" value zane_delete_body(value function) {
  CAMLparam1(function);
  llvm::cast<llvm::Function>(from_val(function))->deleteBody();
  CAMLreturn(Val_unit);
}
