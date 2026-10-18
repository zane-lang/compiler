/* What LLVM's C API offers and its OCaml bindings do not: a function or a
   variable placed in a COMDAT of its own name
   (docs/design/separate-compilation.md C4), a target triple in LLVM's
   normal form, a load made atomic, and an array type whose length takes
   more than 32 bits. The bindings carry an LLVM pointer with its low bit
   set; their `from_val` undoes that, and `to_val` sets it. The C API is declared
   here rather than included, so the build needs no LLVM headers beyond the
   bindings it already links. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdint.h>

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMComdat *LLVMComdatRef;
typedef struct LLVMOpaqueType *LLVMTypeRef;

extern void *from_val(value v);
extern value to_val(void *ptr);
extern LLVMComdatRef LLVMGetOrInsertComdat(LLVMModuleRef M, const char *Name);
extern void LLVMSetComdat(LLVMValueRef V, LLVMComdatRef C);
extern char *LLVMNormalizeTargetTriple(const char *triple);
extern void LLVMDisposeMessage(char *message);
extern void LLVMSetOrdering(LLVMValueRef access, int ordering);
extern LLVMTypeRef LLVMArrayType2(LLVMTypeRef element, uint64_t count);
extern uint64_t LLVMGetArrayLength2(LLVMTypeRef array);

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

/* An access made atomic: LLVMAtomicOrderingUnordered (1), never torn and
   promising no order beyond that, or LLVMAtomicOrderingAcquire (4), which
   also sees every write made before the release that published what it
   reads. */
value zane_set_ordering(value access, value acquire) {
  CAMLparam2(access, acquire);
  LLVMSetOrdering((LLVMValueRef)from_val(access), Bool_val(acquire) ? 4 : 1);
  CAMLreturn(Val_unit);
}

/* An array type of [count] elements, and an array type's length, both 64
   bits wide. The bindings' `array_type` and `array_length` pass the count
   through LLVM's 32-bit `LLVMArrayType` and `LLVMGetArrayLength`, which
   truncate a longer one. Lowering keeps every length below 2^48
   (Cgt.Nodes.Ty.limit), so it fits an OCaml int either way. */
value zane_array_type(value element, value count) {
  CAMLparam2(element, count);
  CAMLreturn(to_val(LLVMArrayType2((LLVMTypeRef)from_val(element), (uint64_t)Long_val(count))));
}

value zane_array_length(value array) {
  CAMLparam1(array);
  CAMLreturn(Val_long((long)LLVMGetArrayLength2((LLVMTypeRef)from_val(array))));
}
