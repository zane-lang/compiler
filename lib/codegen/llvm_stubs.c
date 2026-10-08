/* What LLVM's C API offers and its OCaml bindings do not: a function or a
   variable placed in a COMDAT of its own name
   (docs/design/separate-compilation.md C4), a target triple in LLVM's
   normal form, and a load made atomic. The bindings carry an LLVM pointer
   with its low bit set; their `from_val` undoes that. The C API is declared
   here rather than included, so the build needs no LLVM headers beyond the
   bindings it already links. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMComdat *LLVMComdatRef;

extern void *from_val(value v);
extern LLVMComdatRef LLVMGetOrInsertComdat(LLVMModuleRef M, const char *Name);
extern void LLVMSetComdat(LLVMValueRef V, LLVMComdatRef C);
extern char *LLVMNormalizeTargetTriple(const char *triple);
extern void LLVMDisposeMessage(char *message);
extern void LLVMSetOrdering(LLVMValueRef access, int ordering);

value zane_set_own_comdat(value m, value f, value name) {
  CAMLparam3(m, f, name);
  LLVMComdatRef comdat = LLVMGetOrInsertComdat((LLVMModuleRef)from_val(m), String_val(name));
  LLVMSetComdat((LLVMValueRef)from_val(f), comdat);
  CAMLreturn(Val_unit);
}

value zane_normalize_triple(value triple) {
  CAMLparam1(triple);
  CAMLlocal1(normal);
  char *text = LLVMNormalizeTargetTriple(String_val(triple));
  normal = caml_copy_string(text);
  LLVMDisposeMessage(text);
  CAMLreturn(normal);
}

/* LLVMAtomicOrderingUnordered: the access is never torn, and promises no
   order beyond that. */
value zane_set_unordered(value access) {
  CAMLparam1(access);
  LLVMSetOrdering((LLVMValueRef)from_val(access), 1);
  CAMLreturn(Val_unit);
}
