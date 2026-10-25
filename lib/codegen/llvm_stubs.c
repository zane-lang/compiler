/* What LLVM's C API offers and its OCaml bindings do not: a function or a
   variable placed in a COMDAT of its own name
   (docs/design/separate-compilation.md C4), an assumption that carries
   operand bundles, a target triple in LLVM's
   normal form, an access made atomic at any ordering, a fence, an array type whose length takes more
   than 32 bits, an attribute that carries a type, such as `sret`, a
   function's own type, and the type an `alloca` makes room for. And arrays
   the bindings do give, but wrongly when empty: their `param_types`,
   `struct_element_types` and `function_attrs` allocate an empty array as a
   block of no size in the minor heap, which the collector does not allow
   and which corrupts the heap, so a process that builds many programs
   crashes. These give OCaml's own empty array. The bindings carry an LLVM
   pointer with its low bit set; their `from_val` undoes that, and `to_val`
   sets it. The C API is declared here rather than included, so the build
   needs no LLVM headers beyond the bindings it already links. */

#include <caml/alloc.h>
#include <caml/fail.h>
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
typedef struct LLVMOpaqueBasicBlock *LLVMBasicBlockRef;
typedef struct LLVMOpaqueBuilder *LLVMBuilderRef;
typedef struct LLVMOpaqueOperandBundle *LLVMOperandBundleRef;

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
extern LLVMTypeRef LLVMGetAllocatedType(LLVMValueRef alloca);
extern unsigned LLVMGetEnumAttributeKindForName(const char *name, size_t length);
extern LLVMAttributeRef LLVMCreateTypeAttribute(LLVMContextRef context, unsigned kind, LLVMTypeRef type);
extern unsigned LLVMCountParamTypes(LLVMTypeRef function);
extern void LLVMGetParamTypes(LLVMTypeRef function, LLVMTypeRef *types);
extern unsigned LLVMCountStructElementTypes(LLVMTypeRef structure);
extern void LLVMGetStructElementTypes(LLVMTypeRef structure, LLVMTypeRef *types);
extern unsigned LLVMGetAttributeCountAtIndex(LLVMValueRef function, int index);
extern void LLVMGetAttributesAtIndex(LLVMValueRef function, int index, LLVMAttributeRef *attributes);
extern LLVMContextRef LLVMGetTypeContext(LLVMTypeRef type);
extern LLVMTypeRef LLVMInt1TypeInContext(LLVMContextRef context);
extern LLVMValueRef LLVMConstInt(LLVMTypeRef type, unsigned long long n, int sign_extend);
extern LLVMBuilderRef LLVMCreateBuilderInContext(LLVMContextRef context);
extern void LLVMPositionBuilderAtEnd(LLVMBuilderRef builder, LLVMBasicBlockRef block);
extern void LLVMDisposeBuilder(LLVMBuilderRef builder);
extern LLVMValueRef LLVMBuildFence(LLVMBuilderRef builder, int ordering, int single_thread, const char *name);
extern LLVMOperandBundleRef LLVMCreateOperandBundle(const char *tag, size_t length, LLVMValueRef *args, unsigned count);
extern void LLVMDisposeOperandBundle(LLVMOperandBundleRef bundle);
extern LLVMValueRef LLVMBuildCallWithOperandBundles(LLVMBuilderRef builder, LLVMTypeRef type, LLVMValueRef fn,
                                                    LLVMValueRef *args, unsigned count, LLVMOperandBundleRef *bundles,
                                                    unsigned bundle_count, const char *name);

value zane_set_own_comdat(value m, value f, value name) {
  CAMLparam3(m, f, name);
  LLVMComdatRef comdat = LLVMGetOrInsertComdat((LLVMModuleRef)from_val(m), String_val(name));
  LLVMSetComdat((LLVMValueRef)from_val(f), comdat);
  CAMLreturn(Val_unit);
}

/* `call void @llvm.assume(i1 true) ["dereferenceable"(ptr, size),
   "align"(ptr, align)]` at the end of [block], where [assume] is
   `llvm.assume` and [type] its type: the bytes from [at] to [at] + [size]
   may be read at any point the call dominates. */
value zane_assume_dereferenceable(value block, value type, value assume, value at, value size, value align) {
  CAMLparam5(block, type, assume, at, size);
  CAMLxparam1(align);
  LLVMTypeRef t = (LLVMTypeRef)from_val(type);
  LLVMContextRef context = LLVMGetTypeContext(t);
  LLVMBuilderRef b = LLVMCreateBuilderInContext(context);
  LLVMPositionBuilderAtEnd(b, (LLVMBasicBlockRef)from_val(block));
  LLVMValueRef dereferenceable[] = { (LLVMValueRef)from_val(at), (LLVMValueRef)from_val(size) };
  LLVMValueRef aligned[] = { (LLVMValueRef)from_val(at), (LLVMValueRef)from_val(align) };
  LLVMOperandBundleRef bundles[] = {
    LLVMCreateOperandBundle("dereferenceable", strlen("dereferenceable"), dereferenceable, 2),
    LLVMCreateOperandBundle("align", strlen("align"), aligned, 2),
  };
  LLVMValueRef yes = LLVMConstInt(LLVMInt1TypeInContext(context), 1, 0);
  LLVMBuildCallWithOperandBundles(b, t, (LLVMValueRef)from_val(assume), &yes, 1, bundles, 2, "");
  LLVMDisposeOperandBundle(bundles[0]);
  LLVMDisposeOperandBundle(bundles[1]);
  LLVMDisposeBuilder(b);
  CAMLreturn(Val_unit);
}

value zane_assume_dereferenceable_bytecode(value *argv, int argc) {
  (void)argc;
  return zane_assume_dereferenceable(argv[0], argv[1], argv[2], argv[3], argv[4], argv[5]);
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

/* An access made atomic at an ordering of `Llvm.AtomicOrdering.t`, whose
   constructors are LLVMAtomicOrdering's values in order, and a fence at
   one, at the end of [block], in the context of [type]. */
value zane_set_atomic(value access, value ordering) {
  CAMLparam2(access, ordering);
  LLVMSetOrdering((LLVMValueRef)from_val(access), Int_val(ordering));
  CAMLreturn(Val_unit);
}

value zane_fence(value type, value block, value ordering) {
  CAMLparam3(type, block, ordering);
  LLVMBuilderRef b = LLVMCreateBuilderInContext(LLVMGetTypeContext((LLVMTypeRef)from_val(type)));
  LLVMPositionBuilderAtEnd(b, (LLVMBasicBlockRef)from_val(block));
  LLVMBuildFence(b, Int_val(ordering), 0, "");
  LLVMDisposeBuilder(b);
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

value zane_allocated_type(value alloca) {
  CAMLparam1(alloca);
  CAMLreturn(to_val(LLVMGetAllocatedType((LLVMValueRef)from_val(alloca))));
}

/* [count] pointers, which [fill] writes for [subject] and [index], as an
   OCaml array, each carried as the bindings carry one; an empty array is
   OCaml's own, `Atom(0)`, which [caml_alloc_tuple] gives for no fields.
   The array is allocated before the C buffer, and nothing between the
   buffer's `malloc` and its `free` allocates on the OCaml heap or raises,
   so the buffer cannot leak. */
static value pointers(unsigned count, void (*fill)(void *, int, void **), void *subject, int index) {
  CAMLparam0();
  CAMLlocal1(array);
  array = caml_alloc_tuple(count);
  if (count == 0) CAMLreturn(array);
  void **items = malloc(count * sizeof(void *));
  if (items == NULL) caml_raise_out_of_memory();
  fill(subject, index, items);
  for (unsigned i = 0; i < count; ++i) Store_field(array, i, to_val(items[i]));
  free(items);
  CAMLreturn(array);
}

static void fill_param_types(void *t, int index, void **items) {
  (void)index;
  LLVMGetParamTypes((LLVMTypeRef)t, (LLVMTypeRef *)items);
}

static void fill_struct_element_types(void *t, int index, void **items) {
  (void)index;
  LLVMGetStructElementTypes((LLVMTypeRef)t, (LLVMTypeRef *)items);
}

static void fill_function_attrs(void *f, int index, void **items) {
  LLVMGetAttributesAtIndex((LLVMValueRef)f, index, (LLVMAttributeRef *)items);
}

value zane_param_types(value function) {
  CAMLparam1(function);
  LLVMTypeRef t = (LLVMTypeRef)from_val(function);
  CAMLreturn(pointers(LLVMCountParamTypes(t), fill_param_types, t, 0));
}

value zane_struct_element_types(value structure) {
  CAMLparam1(structure);
  LLVMTypeRef t = (LLVMTypeRef)from_val(structure);
  CAMLreturn(pointers(LLVMCountStructElementTypes(t), fill_struct_element_types, t, 0));
}

/* [index] as LLVM numbers it: -1 for the function, 0 for its result, and
   n + 1 for parameter n. */
value zane_function_attrs(value function, value index) {
  CAMLparam2(function, index);
  LLVMValueRef f = (LLVMValueRef)from_val(function);
  int i = Int_val(index);
  CAMLreturn(pointers(LLVMGetAttributeCountAtIndex(f, i), fill_function_attrs, f, i));
}

/* LLVM's own options, [args] as its command line would give them, the
   first the program's name. LLVM reads them once per process, so a second
   call does nothing. */
void LLVMParseCommandLineOptions(int argc, const char *const *argv, const char *overview);

value zane_llvm_options(value args) {
  CAMLparam1(args);
  static int parsed = 0;
  if (!parsed) {
    parsed = 1;
    int argc = (int)Wosize_val(args);
    const char **argv = malloc(sizeof *argv * (argc + 1));
    for (int i = 0; i < argc; i++) argv[i] = strdup(String_val(Field(args, i)));
    argv[argc] = NULL;
    LLVMParseCommandLineOptions(argc, argv, "");
  }
  CAMLreturn(Val_unit);
}
