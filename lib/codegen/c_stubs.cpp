/* A package's C globals renamed before its module is linked into the
   program's (docs/design/ffi.md F9): every global value it defines that
   other modules could link against -- a function, a variable, an alias or
   an indirect function -- takes the package's prefix before its C name,
   except the glue's thunks, named by their labels, whose names already
   carry the package's. A name an `__asm__` label gave, which LLVM writes
   with a leading \1 and the target's global prefix spelled out, is read as
   the label and renamed by it, so the new name is mangled as any other. A COMDAT named after a renamed global
   is renamed with it, so two versions of a package never share one. */

#include "llvm/IR/Comdat.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/GlobalObject.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/Module.h"

#include <map>
#include <set>
#include <string>
#include <vector>

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Module *module_of(value v) { return reinterpret_cast<llvm::Module *>(v & ~(value)1); }

extern "C" value zane_rename_c_globals(value mod, value prefix, value global_prefix, value keep) {
  CAMLparam4(mod, prefix, global_prefix, keep);
  llvm::Module *m = module_of(mod);
  std::set<std::string> kept;
  for (value l = keep; l != Val_emptylist; l = Field(l, 1)) kept.insert(String_val(Field(l, 0)));
  std::string p = String_val(prefix), target = String_val(global_prefix);
  auto label_of = [&](const std::string &name) {
    std::string label = name;
    if (!label.empty() && label[0] == '\1') {
      label = label.substr(1);
      if (!target.empty() && label.rfind(target, 0) == 0) label = label.substr(target.size());
    }
    return label;
  };
  std::vector<llvm::GlobalValue *> renamed;
  for (llvm::GlobalValue &g : m->global_values()) {
    std::string name = g.getName().str();
    if (g.isDeclaration() || g.hasLocalLinkage() || g.hasAppendingLinkage()) continue;
    if (name.rfind("llvm.", 0) == 0 || kept.count(label_of(name))) continue;
    renamed.push_back(&g);
  }
  std::map<llvm::Comdat *, llvm::Comdat *> comdats;
  for (llvm::GlobalValue *g : renamed) {
    std::string old = g->getName().str();
    g->setName(p + label_of(old));
    if (auto *o = llvm::dyn_cast<llvm::GlobalObject>(g))
      if (llvm::Comdat *c = o->getComdat())
        if (c->getName() == old) {
          llvm::Comdat *&fresh = comdats[c];
          if (!fresh) {
            fresh = m->getOrInsertComdat(g->getName());
            fresh->setSelectionKind(c->getSelectionKind());
          }
        }
  }
  for (llvm::GlobalObject &o : m->global_objects())
    if (llvm::Comdat *c = o.getComdat()) {
      auto it = comdats.find(c);
      if (it != comdats.end()) o.setComdat(it->second);
    }
  CAMLreturn(Val_unit);
}

/* Each definition of a glue module that the package's modules linked
   before it already define, under the same name and visible to other
   modules, made a declaration, so the glue's copy of a function or
   variable an interface header defines meets the copy of a source that
   includes the header as a use, not a second definition. */
extern "C" value zane_drop_defined(value glue, value before) {
  CAMLparam2(glue, before);
  llvm::Module *g = module_of(glue), *b = module_of(before);
  std::vector<llvm::GlobalObject *> dropped;
  for (llvm::GlobalObject &o : g->global_objects()) {
    if (o.isDeclaration() || o.hasLocalLinkage()) continue;
    llvm::GlobalValue *there = b->getNamedValue(o.getName());
    if (there && !there->isDeclaration() && !there->hasLocalLinkage()) dropped.push_back(&o);
  }
  for (llvm::GlobalObject *o : dropped) {
    if (auto *f = llvm::dyn_cast<llvm::Function>(o))
      f->deleteBody();
    else if (auto *v = llvm::dyn_cast<llvm::GlobalVariable>(o)) {
      v->setInitializer(nullptr);
      v->setLinkage(llvm::GlobalValue::ExternalLinkage);
    }
    o->setComdat(nullptr);
  }
  CAMLreturn(Val_unit);
}
