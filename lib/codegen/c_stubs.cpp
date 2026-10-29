/* A package's C globals renamed before its module is linked into the
   program's (docs/design/ffi.md F9): every global value it defines that
   other modules could link against -- a function, a variable, an alias or
   an indirect function -- takes the package's prefix before its C name,
   except the glue's thunks, named by their labels, whose names already
   carry the package's. A name an `__asm__` label gave, which LLVM writes
   with a leading \1 and the target's global prefix spelled out, is read as
   the label and renamed by it, so the new name is mangled as any other. A COMDAT named after a renamed global
   is renamed with it, so two versions of a package never share one. A
   declaration is renamed when its name is one of the package's objects
   defines, an archive's member or an object assembled from a source
   holding assembly, so the module's uses reach the object's renamed
   definition. What comes back is the C name of every global renamed, for
   the objects to be renamed by. */

#include "llvm/IR/Comdat.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalIFunc.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/Support/raw_ostream.h"
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
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Module *module_of(value v) { return reinterpret_cast<llvm::Module *>(v & ~(value)1); }

extern "C" value zane_rename_c_globals(value mod, value prefix, value global_prefix, value keep, value declared) {
  CAMLparam5(mod, prefix, global_prefix, keep, declared);
  CAMLlocal3(names, cell, name);
  llvm::Module *m = module_of(mod);
  std::set<std::string> kept, defined_apart;
  for (value l = keep; l != Val_emptylist; l = Field(l, 1)) kept.insert(String_val(Field(l, 0)));
  for (value l = declared; l != Val_emptylist; l = Field(l, 1)) defined_apart.insert(String_val(Field(l, 0)));
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
    if (g.hasLocalLinkage() || g.hasAppendingLinkage()) continue;
    // An `available_externally` definition, such as a C library's inline
    // copy of its own function, stands for a symbol another object defines,
    // renamed only where that object is one of the package's own.
    if (g.isDeclarationForLinker() && !defined_apart.count(label_of(name))) continue;
    if (name.rfind("llvm.", 0) == 0 || kept.count(label_of(name))) continue;
    renamed.push_back(&g);
  }
  std::vector<std::string> labels;
  std::map<llvm::Comdat *, llvm::Comdat *> comdats;
  for (llvm::GlobalValue *g : renamed) {
    std::string old = g->getName().str();
    labels.push_back(label_of(old));
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
  names = Val_emptylist;
  for (auto it = labels.rbegin(); it != labels.rend(); ++it) {
    name = caml_copy_string(it->c_str());
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, name);
    Store_field(cell, 1, names);
    names = cell;
  }
  CAMLreturn(names);
}

/* A name without the `.N` the linker adds to a local one it renames. */
static llvm::StringRef unnumbered(llvm::StringRef name) {
  size_t dot = name.rfind('.');
  if (dot == llvm::StringRef::npos || dot + 1 == name.size()) return name;
  for (char c : name.substr(dot + 1))
    if (c < '0' || c > '9') return name;
  return name.substr(0, dot);
}

/* What a function does, as far as telling two copies of one header's
   function apart from two different functions needs: its instructions'
   opcodes, the constants they use and the globals they name. */
static std::string fingerprint(llvm::Function &f) {
  std::string s;
  llvm::raw_string_ostream out(s);
  for (llvm::BasicBlock &bb : f) {
    out << '|';
    for (llvm::Instruction &i : bb) {
      out << i.getOpcodeName();
      for (llvm::Value *op : i.operands()) {
        if (auto *g = llvm::dyn_cast<llvm::GlobalValue>(op))
          out << " @" << unnumbered(g->getName());
        else if (auto *c = llvm::dyn_cast<llvm::ConstantInt>(op))
          out << ' ' << c->getValue();
        else if (auto *c = llvm::dyn_cast<llvm::ConstantFP>(op))
          out << ' ' << c->getValueAPF().bitcastToAPInt();
      }
      out << ';';
    }
  }
  return out.str();
}

/* The functions the appending list [list] of [m] runs. */
static std::vector<llvm::Function *> listed(llvm::Module *m, const char *list) {
  std::vector<llvm::Function *> fs;
  llvm::GlobalVariable *v = m->getNamedGlobal(list);
  if (!v || !v->hasInitializer()) return fs;
  if (auto *a = llvm::dyn_cast<llvm::ConstantArray>(v->getInitializer()))
    for (llvm::Use &e : a->operands())
      if (auto *entry = llvm::dyn_cast<llvm::ConstantStruct>(e.get()))
        if (auto *f = llvm::dyn_cast<llvm::Function>(entry->getOperand(1)->stripPointerCasts())) fs.push_back(f);
  return fs;
}

/* Whether anything but the functions [fs] uses [v]: a function outside
   them, directly or through a constant expression, or a global's
   initializer, through which any function could reach it. */
static bool used_beyond(llvm::Value *v, const std::set<llvm::Function *> &fs) {
  for (llvm::User *u : v->users()) {
    if (auto *i = llvm::dyn_cast<llvm::Instruction>(u)) {
      if (!fs.count(i->getFunction())) return true;
    } else if (!llvm::isa<llvm::ConstantExpr>(u) || used_beyond(u, fs))
      return true;
  }
  return false;
}

/* Whether a private variable [f] reaches, itself, through the functions
   of its module it calls or through the initializer of a private variable
   it reaches, is used by any other function: the glue's own
   copy of a header's state, which only [f] sets up for the glue's
   functions that read it. A function [f] reaches that something else uses
   too could read such state for it, and a call through a pointer could
   reach any function, so either is taken to. */
static bool sets_up_private_state(llvm::Function &f) {
  std::set<llvm::Function *> reached{&f};
  std::vector<llvm::Function *> to_read{&f};
  std::set<llvm::GlobalVariable *> state;
  while (!to_read.empty()) {
    llvm::Function *fn = to_read.back();
    to_read.pop_back();
    std::vector<llvm::Value *> pending;
    for (llvm::Instruction &i : llvm::instructions(*fn)) {
      if (auto *call = llvm::dyn_cast<llvm::CallBase>(&i))
        if (call->isIndirectCall()) return true;
      for (llvm::Value *op : i.operands()) pending.push_back(op);
    }
    while (!pending.empty()) {
      llvm::Value *v = pending.back();
      pending.pop_back();
      if (auto *g = llvm::dyn_cast<llvm::GlobalVariable>(v)) {
        if (g->hasLocalLinkage() && state.insert(g).second && g->hasInitializer())
          pending.push_back(g->getInitializer());
      } else if (auto *callee = llvm::dyn_cast<llvm::Function>(v)) {
        if (!callee->isDeclaration() && reached.insert(callee).second) to_read.push_back(callee);
      } else if (auto *c = llvm::dyn_cast<llvm::Constant>(v); c && !llvm::isa<llvm::GlobalValue>(c))
        for (llvm::Value *op : c->operands()) pending.push_back(op);
    }
  }
  for (llvm::Function *fn : reached)
    if (fn != &f && used_beyond(fn, reached)) return true;
  for (llvm::GlobalVariable *g : state)
    if (used_beyond(g, reached)) return true;
  return false;
}

/* What a constructor or destructor of the appending list [list] is known
   by: the list, its name without the linker's number and what it does. */
static std::string run_by(const char *list, llvm::Function &f) {
  return std::string(list) + '\0' + unnumbered(f.getName()).str() + '\0' + fingerprint(f);
}

static const char *const lists[] = {"llvm.global_ctors", "llvm.global_dtors"};

/* The entries of the glue's appending list [list], `llvm.global_ctors` or
   `llvm.global_dtors`, that run a local function [run] holds, as
   [run_by] reads it: a constructor or destructor of the interface header
   the glue compiles, which a source including that header runs once for
   the package's C, not again for the glue's copy. A source including the
   header defines only one local function of that name, the header's. One
   of a header no source includes stays, and so does one that sets up
   private state of the glue's own, which [zane_share_state] did not make
   the source's and a function of the glue still reads, since the source's
   copy sets up only its own. */
static void drop_repeated(llvm::Module *g, const std::set<std::string> &run, const char *list) {
  llvm::GlobalVariable *v = g->getNamedGlobal(list);
  if (!v || !v->hasInitializer()) return;
  auto *a = llvm::dyn_cast<llvm::ConstantArray>(v->getInitializer());
  if (!a) return;
  std::vector<llvm::Constant *> kept;
  for (llvm::Use &e : a->operands()) {
    auto *entry = llvm::cast<llvm::Constant>(e.get());
    auto *f = llvm::dyn_cast<llvm::Function>(entry->getOperand(1)->stripPointerCasts());
    bool again = f && f->hasLocalLinkage() && run.count(run_by(list, *f)) && !sets_up_private_state(*f);
    if (!again) kept.push_back(entry);
  }
  if (kept.size() == a->getNumOperands()) return;
  if (kept.empty()) {
    v->eraseFromParent();
    return;
  }
  llvm::ArrayType *t = llvm::ArrayType::get(a->getType()->getElementType(), kept.size());
  auto *fresh = new llvm::GlobalVariable(*g, t, v->isConstant(), v->getLinkage(), llvm::ConstantArray::get(t, kept), "", v,
                                         v->getThreadLocalMode(), v->getAddressSpace());
  fresh->setSection(v->getSection());
  fresh->takeName(v);
  v->eraseFromParent();
}

/* The local constructors and destructors [mod], a source's module not yet
   linked, runs, as [run_by] reads each. */
extern "C" value zane_c_constructors(value mod) {
  CAMLparam1(mod);
  CAMLlocal3(result, cell, text);
  llvm::Module *m = module_of(mod);
  result = Val_emptylist;
  for (const char *list : lists)
    for (llvm::Function *f : listed(m, list))
      if (f->hasLocalLinkage()) {
        std::string s = run_by(list, *f);
        text = caml_alloc_initialized_string(s.size(), s.data());
        cell = caml_alloc(2, 0);
        Store_field(cell, 0, text);
        Store_field(cell, 1, result);
        result = cell;
      }
  CAMLreturn(result);
}

/* What a private variable of a source's shared with a glue module is named
   while the two are linked: the prefix, the source's [tag], a dot and its
   own name. */
static const char shared_prefix[] = "zane.shared.";

/* Whether [v] is a private object whose address the program can see: a
   named variable local to its module, other than a string literal or any
   other whose address LLVM is free to merge. */
static bool private_object(const llvm::GlobalVariable &v) {
  return v.hasLocalLinkage() && !v.hasGlobalUnnamedAddr() && v.hasName() && !v.getName().starts_with("llvm.");
}

/* Whether [a] and [b] can be one object: both writable, or both constant
   with the same value. */
static bool same_object(const llvm::GlobalVariable &a, const llvm::GlobalVariable &b) {
  if (a.getValueType() != b.getValueType() || a.getThreadLocalMode() != b.getThreadLocalMode()) return false;
  if (a.isConstant() != b.isConstant()) return false;
  return !a.isConstant() || (a.hasInitializer() && b.hasInitializer() && a.getInitializer() == b.getInitializer());
}

/* The glue module [glue]'s private objects that [source], the one source
   including its interface header, also defines, by name and type, made
   one variable: the source's renamed [shared_prefix] [tag] `.` and its
   name and made visible to the link, and the glue's made a declaration of
   it. Within one translation unit a name at file scope, or a function's
   own static, is one variable, so the source's of that name is the
   header's, and the glue's functions read and write the state the
   source's do, and see a constant at the address they see it at, as the C
   alone would. A constant is one only with the same value, which in one
   context is the same LLVM constant. */
extern "C" value zane_share_state(value glue, value source, value tag) {
  CAMLparam3(glue, source, tag);
  llvm::Module *g = module_of(glue), *s = module_of(source);
  std::string prefix = shared_prefix + std::string(String_val(tag)) + '.';
  std::vector<llvm::GlobalVariable *> state;
  for (llvm::GlobalVariable &v : g->globals())
    if (private_object(v)) state.push_back(&v);
  for (llvm::GlobalVariable *v : state) {
    std::string name = v->getName().str(), joined = prefix + name;
    llvm::GlobalVariable *there = s->getNamedGlobal(joined);
    if (!there) {
      there = s->getNamedGlobal(name);
      if (!there || !private_object(*there)) continue;
    }
    if (!same_object(*there, *v)) continue;
    if (there->hasLocalLinkage()) {
      there->setName(joined);
      there->setLinkage(llvm::GlobalValue::ExternalLinkage);
      there->setVisibility(llvm::GlobalValue::HiddenVisibility);
    }
    auto *d = new llvm::GlobalVariable(*g, v->getValueType(), v->isConstant(), llvm::GlobalValue::ExternalLinkage, nullptr, joined,
                                       nullptr, v->getThreadLocalMode(), v->getAddressSpace());
    d->setVisibility(llvm::GlobalValue::HiddenVisibility);
    v->replaceAllUsesWith(d);
    v->eraseFromParent();
  }
  CAMLreturn(Val_unit);
}

/* Each variable [zane_share_state] shared in [mod], a package's linked
   module, local again under its own name. */
extern "C" value zane_localize_shared(value mod) {
  CAMLparam1(mod);
  llvm::Module *m = module_of(mod);
  for (llvm::GlobalVariable &v : m->globals()) {
    llvm::StringRef name = v.getName();
    if (v.isDeclaration() || !name.starts_with(shared_prefix)) continue;
    std::string own = name.drop_front(sizeof shared_prefix - 1).split('.').second.str();
    v.setLinkage(llvm::GlobalValue::InternalLinkage);
    v.setVisibility(llvm::GlobalValue::DefaultVisibility);
    v.setName(own);
  }
  CAMLreturn(Val_unit);
}

/* A declaration of the global value [v] standing for it in its module, its
   uses moved to the declaration and [v] gone: an alias or an indirect
   function cannot be made a declaration in place. */
static void declare_instead(llvm::GlobalValue *v) {
  llvm::Module *m = v->getParent();
  llvm::GlobalValue *d;
  if (auto *ft = llvm::dyn_cast<llvm::FunctionType>(v->getValueType()))
    d = llvm::Function::Create(ft, llvm::GlobalValue::ExternalLinkage, v->getAddressSpace(), "", m);
  else
    d = new llvm::GlobalVariable(*m, v->getValueType(), false, llvm::GlobalValue::ExternalLinkage, nullptr, "", nullptr,
                                 llvm::GlobalValue::NotThreadLocal, v->getAddressSpace());
  d->takeName(v);
  v->replaceAllUsesWith(d);
  v->eraseFromParent();
}

/* Each definition of a glue module that the package's modules linked
   before it already define, under the same name and visible to other
   modules, made a declaration, so the glue's copy of a function, variable,
   alias or indirect function an interface header defines meets the copy
   of a source that includes the header as a use, not a second definition;
   and the glue's copy of its header's constructors and destructors [run]
   names, which a source including the header runs, left out of its lists. */
/* Each definition of [g] visible to other modules that [defined]
   already holds elsewhere made a declaration: an alias or an indirect
   function by [declare_instead], a function or variable in place. */
template <typename Defined> static void declare_defined(llvm::Module *g, Defined defined) {
  // An alias or an indirect function names a definition the glue may drop
  // below, so it goes first.
  std::vector<llvm::GlobalValue *> named;
  for (llvm::GlobalAlias &a : g->aliases())
    if (!a.hasLocalLinkage() && defined(a)) named.push_back(&a);
  for (llvm::GlobalIFunc &i : g->ifuncs())
    if (!i.hasLocalLinkage() && defined(i)) named.push_back(&i);
  for (llvm::GlobalValue *v : named) declare_instead(v);
  std::vector<llvm::GlobalObject *> dropped;
  for (llvm::GlobalObject &o : g->global_objects()) {
    // An appending list, such as `llvm.global_ctors`, is concatenated by the
    // link: each module's entries are its own.
    if (o.isDeclaration() || o.hasLocalLinkage() || o.hasAppendingLinkage()) continue;
    if (defined(o)) dropped.push_back(&o);
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
}

extern "C" value zane_drop_defined(value glue, value before, value run) {
  CAMLparam3(glue, before, run);
  llvm::Module *g = module_of(glue), *b = module_of(before);
  std::set<std::string> repeated;
  for (value l = run; l != Val_emptylist; l = Field(l, 1))
    repeated.insert(std::string(String_val(Field(l, 0)), caml_string_length(Field(l, 0))));
  declare_defined(g, [b](llvm::GlobalValue &v) {
    llvm::GlobalValue *there = b->getNamedValue(v.getName());
    return there && !there->isDeclarationForLinker() && !there->hasLocalLinkage();
  });
  // After the copies above are declarations, which no longer read any
  // state of the glue's.
  for (const char *list : lists) drop_repeated(g, repeated, list);
  CAMLreturn(Val_unit);
}

/* Each definition of the glue module [glue] of a C name the package's
   objects define, an archive's member or an object assembled from a
   source holding assembly, made a declaration, as [zane_drop_defined]
   makes one the modules before it hold: an interface header's own
   definition, compiled into the glue too, meets the object's copy as a
   use. */
extern "C" value zane_drop_defined_apart(value glue, value names) {
  CAMLparam2(glue, names);
  std::set<std::string> apart;
  for (value l = names; l != Val_emptylist; l = Field(l, 1)) apart.insert(String_val(Field(l, 0)));
  declare_defined(module_of(glue), [&apart](llvm::GlobalValue &v) { return apart.count(v.getName().str()) > 0; });
  CAMLreturn(Val_unit);
}
