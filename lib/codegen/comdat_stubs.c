/* A function placed in a COMDAT of its own name, which LLVM's C API offers
   and its OCaml bindings do not (docs/design/separate-compilation.md C4).
   The bindings carry an LLVM pointer with its low bit set; their `from_val`
   undoes that. The C API is declared here rather than included, so the
   build needs no LLVM headers beyond the bindings it already links. */

#include <caml/memory.h>
#include <caml/mlvalues.h>

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMComdat *LLVMComdatRef;

extern void *from_val(value v);
extern LLVMComdatRef LLVMGetOrInsertComdat(LLVMModuleRef M, const char *Name);
extern void LLVMSetComdat(LLVMValueRef V, LLVMComdatRef C);

value zane_set_own_comdat(value m, value f, value name) {
  CAMLparam3(m, f, name);
  LLVMComdatRef comdat = LLVMGetOrInsertComdat((LLVMModuleRef)from_val(m), String_val(name));
  LLVMSetComdat((LLVMValueRef)from_val(f), comdat);
  CAMLreturn(Val_unit);
}
