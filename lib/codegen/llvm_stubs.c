/* What LLVM's C API offers and its OCaml bindings do not: a function or a
   variable placed in a COMDAT of its own name
   (docs/design/separate-compilation.md C4), a target triple in LLVM's
   normal form, a load made atomic, an array type whose length takes more
   than 32 bits, an attribute that carries a type, such as `sret`, and a
   function's own type. And arrays the bindings do give, but wrongly when
   empty: their `param_types`, `struct_element_types` and `function_attrs`
   allocate an empty array as a block of no size in the minor heap, which
   the collector does not allow and which corrupts the heap, so a process
   that builds many programs crashes. These give OCaml's own empty array.
   The bindings carry an LLVM pointer with its low bit
   set; their `from_val` undoes that, and `to_val` sets it. The C API is declared
   here rather than included, so the build needs no LLVM headers beyond the
   bindings it already links. */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct LLVMOpaqueModule *LLVMModuleRef;
typedef struct LLVMOpaqueValue *LLVMValueRef;
typedef struct LLVMComdat *LLVMComdatRef;
typedef struct LLVMOpaqueType *LLVMTypeRef;
typedef struct LLVMOpaqueContext *LLVMContextRef;
typedef struct LLVMOpaqueAttributeRef *LLVMAttributeRef;

extern void *from_val(value v);
extern value to_val(void *ptr);
extern LLVMComdatRef LLVMGetOrInsertComdat(LLVMModuleRef M, const char *Name);
extern void LLVMSetComdat(LLVMValueRef V, LLVMComdatRef C);
extern char *LLVMNormalizeTargetTriple(const char *triple);
extern void LLVMDisposeMessage(char *message);
extern void LLVMSetOrdering(LLVMValueRef access, int ordering);
extern LLVMTypeRef LLVMArrayType2(LLVMTypeRef element, uint64_t count);
extern uint64_t LLVMGetArrayLength2(LLVMTypeRef array);
extern LLVMTypeRef LLVMGlobalGetValueType(LLVMValueRef global);
extern unsigned LLVMGetEnumAttributeKindForName(const char *name, size_t length);
extern LLVMAttributeRef LLVMCreateTypeAttribute(LLVMContextRef context, unsigned kind, LLVMTypeRef type);
extern unsigned LLVMCountParamTypes(LLVMTypeRef function);
extern void LLVMGetParamTypes(LLVMTypeRef function, LLVMTypeRef *types);
extern unsigned LLVMCountStructElementTypes(LLVMTypeRef structure);
extern void LLVMGetStructElementTypes(LLVMTypeRef structure, LLVMTypeRef *types);
extern unsigned LLVMGetAttributeCountAtIndex(LLVMValueRef function, int index);
extern void LLVMGetAttributesAtIndex(LLVMValueRef function, int index, LLVMAttributeRef *attributes);

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

/* An attribute of the kind [name] that carries [type], as `sret(T)` does. */
value zane_type_attr(value context, value name, value type) {
  CAMLparam3(context, name, type);
  unsigned kind = LLVMGetEnumAttributeKindForName(String_val(name), caml_string_length(name));
  CAMLreturn(to_val(
      LLVMCreateTypeAttribute((LLVMContextRef)from_val(context), kind, (LLVMTypeRef)from_val(type))));
}

/* The type of what a global names: a function's own type, which its
   address, a `ptr`, no longer carries. */
value zane_global_value_type(value global) {
  CAMLparam1(global);
  CAMLreturn(to_val(LLVMGlobalGetValueType((LLVMValueRef)from_val(global))));
}

/* [count] pointers as an OCaml array, each carried as the bindings carry
   one; an empty array is OCaml's own, `Atom(0)`, which [caml_alloc_tuple]
   gives for no fields. */
static value pointers(void **items, unsigned count) {
  CAMLparam0();
  CAMLlocal1(array);
  array = caml_alloc_tuple(count);
  for (unsigned i = 0; i < count; ++i) Store_field(array, i, to_val(items[i]));
  CAMLreturn(array);
}

value zane_param_types(value function) {
  CAMLparam1(function);
  CAMLlocal1(array);
  LLVMTypeRef t = (LLVMTypeRef)from_val(function);
  unsigned n = LLVMCountParamTypes(t);
  void **items = malloc((n ? n : 1) * sizeof(void *));
  LLVMGetParamTypes(t, (LLVMTypeRef *)items);
  array = pointers(items, n);
  free(items);
  CAMLreturn(array);
}

value zane_struct_element_types(value structure) {
  CAMLparam1(structure);
  CAMLlocal1(array);
  LLVMTypeRef t = (LLVMTypeRef)from_val(structure);
  unsigned n = LLVMCountStructElementTypes(t);
  void **items = malloc((n ? n : 1) * sizeof(void *));
  LLVMGetStructElementTypes(t, (LLVMTypeRef *)items);
  array = pointers(items, n);
  free(items);
  CAMLreturn(array);
}

/* [index] as LLVM numbers it: -1 for the function, 0 for its result, and
   n + 1 for parameter n. */
value zane_function_attrs(value function, value index) {
  CAMLparam2(function, index);
  CAMLlocal1(array);
  LLVMValueRef f = (LLVMValueRef)from_val(function);
  unsigned n = LLVMGetAttributeCountAtIndex(f, Int_val(index));
  void **items = malloc((n ? n : 1) * sizeof(void *));
  LLVMGetAttributesAtIndex(f, Int_val(index), (LLVMAttributeRef *)items);
  array = pointers(items, n);
  free(items);
  CAMLreturn(array);
}
