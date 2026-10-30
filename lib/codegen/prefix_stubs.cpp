/* What a function value C can call needs of LLVM that its C API does not
   give (docs/design/ffi.md F11): prefix data, the constant LLVM places in
   the words just before a function's code. */

#include "llvm/IR/Constant.h"
#include "llvm/IR/Function.h"

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Value *from_val(value v) { return reinterpret_cast<llvm::Value *>(v & ~(value)1); }

extern "C" value zane_set_prefix_data(value function, value data) {
  CAMLparam2(function, data);
  llvm::cast<llvm::Function>(from_val(function))->setPrefixData(llvm::cast<llvm::Constant>(from_val(data)));
  CAMLreturn(Val_unit);
}

extern "C" value zane_has_prefix_data(value function) {
  CAMLparam1(function);
  CAMLreturn(Val_bool(llvm::cast<llvm::Function>(from_val(function))->hasPrefixData()));
}

/* [from]'s prefix data made [into]'s, and [from] left without any. */
extern "C" value zane_move_prefix_data(value from, value into) {
  CAMLparam2(from, into);
  auto *f = llvm::cast<llvm::Function>(from_val(from));
  if (f->hasPrefixData()) {
    llvm::cast<llvm::Function>(from_val(into))->setPrefixData(f->getPrefixData());
    f->setPrefixData(nullptr);
  }
  CAMLreturn(Val_unit);
}

extern "C" value zane_drop_prefix_data(value function) {
  CAMLparam1(function);
  llvm::cast<llvm::Function>(from_val(function))->setPrefixData(nullptr);
  CAMLreturn(Val_unit);
}
