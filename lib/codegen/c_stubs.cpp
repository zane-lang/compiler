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
#include "llvm/IR/Operator.h"

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
    // An `available_externally` definition, such as a C library's inline
    // copy of its own function, stands for a symbol another object defines.
    if (g.isDeclarationForLinker() || g.hasLocalLinkage() || g.hasAppendingLinkage()) continue;
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

/* Whether [f] is a private function whose address the program can see: a
   named function local to its module and defined there. */
static bool private_function(const llvm::Function &f) {
  return f.hasLocalLinkage() && !f.isDeclaration() && !f.hasGlobalUnnamedAddr() && f.hasName();
}

/* [name] without the [prefix] [zane_share_state] gives a shared variable's
   name, as both modules' copies of an object are named before sharing. */
static llvm::StringRef own_name(llvm::StringRef name, llvm::StringRef prefix) {
  return name.starts_with(prefix) ? name.drop_front(prefix.size()) : name;
}

/* Whether the glue's type [a] and the source's [b] are one C type: each
   module read into the context names its own copy of a struct, so a named
   struct is the other's with the same packing and fields in turn. */
static bool same_type(llvm::Type *a, llvm::Type *b) {
  if (a == b) return true;
  if (a->getTypeID() != b->getTypeID() || a->getNumContainedTypes() != b->getNumContainedTypes()) return false;
  if (auto *sa = llvm::dyn_cast<llvm::StructType>(a)) {
    auto *sb = llvm::cast<llvm::StructType>(b);
    if (sa->isOpaque() || sb->isOpaque() || sa->isPacked() != sb->isPacked()) return false;
  } else if (auto *aa = llvm::dyn_cast<llvm::ArrayType>(a)) {
    if (aa->getNumElements() != llvm::cast<llvm::ArrayType>(b)->getNumElements()) return false;
  } else if (auto *fa = llvm::dyn_cast<llvm::FunctionType>(a)) {
    if (fa->isVarArg() != llvm::cast<llvm::FunctionType>(b)->isVarArg()) return false;
  } else if (!llvm::isa<llvm::FixedVectorType>(a)) {
    return false;
  } else if (llvm::cast<llvm::FixedVectorType>(a)->getNumElements() != llvm::cast<llvm::FixedVectorType>(b)->getNumElements()) {
    return false;
  }
  for (unsigned i = 0; i < a->getNumContainedTypes(); ++i)
    if (!same_type(a->getContainedType(i), b->getContainedType(i))) return false;
  return true;
}

static bool same_object(const llvm::GlobalVariable &a, const llvm::GlobalVariable &b, llvm::StringRef prefix,
                        std::set<const llvm::GlobalVariable *> &assumed);

/* Whether the glue's constant [a] and the source's [b] have the same value
   once each object it points at is the other module's: a private object
   the one its name and value match, a literal one of the same content, and
   any other global value the one of its name. */
static bool same_constant(const llvm::Constant *a, const llvm::Constant *b, llvm::StringRef prefix,
                          std::set<const llvm::GlobalVariable *> &assumed) {
  if (a == b) return true;
  if (!same_type(a->getType(), b->getType()) || a->getValueID() != b->getValueID()) return false;
  auto *ga = llvm::dyn_cast<llvm::GlobalValue>(a);
  auto *gb = llvm::dyn_cast<llvm::GlobalValue>(b);
  if (ga || gb) {
    if (!ga || !gb) return false;
    auto *va = llvm::dyn_cast<llvm::GlobalVariable>(ga);
    auto *vb = llvm::dyn_cast<llvm::GlobalVariable>(gb);
    if (va && vb && va->hasGlobalUnnamedAddr() && vb->hasGlobalUnnamedAddr() && va->isConstant() && vb->isConstant())
      return same_object(*va, *vb, prefix, assumed);
    if (own_name(ga->getName(), prefix) != own_name(gb->getName(), prefix) || ga->getName().empty()) return false;
    return !(va && vb && va->hasInitializer() && vb->hasInitializer()) || same_object(*va, *vb, prefix, assumed);
  }
  if (llvm::isa<llvm::ConstantData>(a))
    return llvm::isa<llvm::ConstantAggregateZero>(a) || llvm::isa<llvm::UndefValue>(a) ||
           llvm::isa<llvm::ConstantPointerNull>(a);
  if (auto *ea = llvm::dyn_cast<llvm::ConstantExpr>(a))
    if (ea->getOpcode() != llvm::cast<llvm::ConstantExpr>(b)->getOpcode()) return false;
  if (auto *pa = llvm::dyn_cast<llvm::GEPOperator>(a))
    if (!same_type(pa->getSourceElementType(), llvm::cast<llvm::GEPOperator>(b)->getSourceElementType()) ||
        pa->isInBounds() != llvm::cast<llvm::GEPOperator>(b)->isInBounds())
      return false;
  if (a->getNumOperands() != b->getNumOperands()) return false;
  for (unsigned i = 0; i < a->getNumOperands(); ++i)
    if (!same_constant(llvm::cast<llvm::Constant>(a->getOperand(i)), llvm::cast<llvm::Constant>(b->getOperand(i)), prefix,
                       assumed))
      return false;
  return true;
}

/* Whether the glue's [a] and the source's [b] can be one object: both
   writable, or both constant with the same value, as [same_constant] reads
   it. [assumed] holds the glue's objects already being compared, taken to
   match, so an object pointing at itself compares. */
static bool same_object(const llvm::GlobalVariable &a, const llvm::GlobalVariable &b, llvm::StringRef prefix,
                        std::set<const llvm::GlobalVariable *> &assumed) {
  if (!same_type(a.getValueType(), b.getValueType()) || a.getThreadLocalMode() != b.getThreadLocalMode()) return false;
  if (a.isConstant() != b.isConstant()) return false;
  if (!a.isConstant()) return true;
  if (!a.hasInitializer() || !b.hasInitializer()) return false;
  if (!assumed.insert(&a).second) return true;
  bool same = same_constant(a.getInitializer(), b.getInitializer(), prefix, assumed);
  assumed.erase(&a);
  return same;
}

/* The glue module [glue]'s private objects that [source], the one source
   including its interface header, also defines, by name and type, made
   one variable: the source's renamed [shared_prefix] [tag] `.` and its
   name and made visible to the link, and the glue's made a declaration of
   it. Within one translation unit a name at file scope, or a function's
   own static, is one variable, so the source's of that name is the
   header's, and the glue's functions read and write the state the
   source's do, and see a constant at the address they see it at, as the C
   alone would. A constant is one only with the same value, which may
   point at other objects the two modules each have a copy of. A private
   function whose address the glue takes, as a comparison with a pointer
   to it does, is shared the same way, so the glue sees the address the
   source's pointers hold; one only called stays the glue's own, to
   inline, and a constructor or destructor stays its own too, as the glue's
   list of them names it. */
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
    std::set<const llvm::GlobalVariable *> assumed;
    if (!same_object(*v, *there, prefix, assumed)) continue;
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
  std::set<llvm::Function *> run;
  for (const char *list : lists)
    for (llvm::Function *f : listed(g, list)) run.insert(f);
  std::vector<llvm::Function *> code;
  for (llvm::Function &f : g->functions())
    if (private_function(f) && !run.count(&f) && f.hasAddressTaken()) code.push_back(&f);
  for (llvm::Function *f : code) {
    std::string name = f->getName().str(), joined = prefix + name;
    llvm::Function *there = s->getFunction(joined);
    if (!there) {
      there = s->getFunction(name);
      if (!there || !private_function(*there)) continue;
      there->setName(joined);
      there->setLinkage(llvm::GlobalValue::ExternalLinkage);
      there->setVisibility(llvm::GlobalValue::HiddenVisibility);
    }
    if (!same_type(f->getFunctionType(), there->getFunctionType())) continue;
    llvm::Function *d = llvm::Function::Create(f->getFunctionType(), llvm::GlobalValue::ExternalLinkage,
                                               f->getAddressSpace(), joined, g);
    d->setVisibility(llvm::GlobalValue::HiddenVisibility);
    d->setCallingConv(f->getCallingConv());
    d->setAttributes(f->getAttributes());
    f->replaceAllUsesWith(d);
    f->eraseFromParent();
  }
  CAMLreturn(Val_unit);
}

/* [v], a variable or function [zane_share_state] shared, local again
   under its own name. */
static void localize(llvm::GlobalObject &v) {
  llvm::StringRef name = v.getName();
  if (v.isDeclaration() || !name.starts_with(shared_prefix)) return;
  std::string own = name.drop_front(sizeof shared_prefix - 1).split('.').second.str();
  v.setLinkage(llvm::GlobalValue::InternalLinkage);
  v.setVisibility(llvm::GlobalValue::DefaultVisibility);
  v.setName(own);
}

/* Each variable and function [zane_share_state] shared in [mod], a
   package's linked module, local again under its own name. */
extern "C" value zane_localize_shared(value mod) {
  CAMLparam1(mod);
  llvm::Module *m = module_of(mod);
  for (llvm::GlobalVariable &v : m->globals()) localize(v);
  for (llvm::Function &f : m->functions()) localize(f);
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
extern "C" value zane_drop_defined(value glue, value before, value run) {
  CAMLparam3(glue, before, run);
  llvm::Module *g = module_of(glue), *b = module_of(before);
  std::set<std::string> repeated;
  for (value l = run; l != Val_emptylist; l = Field(l, 1))
    repeated.insert(std::string(String_val(Field(l, 0)), caml_string_length(Field(l, 0))));
  auto defined_before = [b](llvm::GlobalValue &v) {
    llvm::GlobalValue *there = b->getNamedValue(v.getName());
    return there && !there->isDeclarationForLinker() && !there->hasLocalLinkage();
  };
  // An alias or an indirect function names a definition the glue may drop
  // below, so it goes first.
  std::vector<llvm::GlobalValue *> named;
  for (llvm::GlobalAlias &a : g->aliases())
    if (!a.hasLocalLinkage() && defined_before(a)) named.push_back(&a);
  for (llvm::GlobalIFunc &i : g->ifuncs())
    if (!i.hasLocalLinkage() && defined_before(i)) named.push_back(&i);
  for (llvm::GlobalValue *v : named) declare_instead(v);
  std::vector<llvm::GlobalObject *> dropped;
  for (llvm::GlobalObject &o : g->global_objects()) {
    // An appending list, such as `llvm.global_ctors`, is concatenated by the
    // link: each module's entries are its own.
    if (o.isDeclaration() || o.hasLocalLinkage() || o.hasAppendingLinkage()) continue;
    if (defined_before(o)) dropped.push_back(&o);
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
  // After the copies above are declarations, which no longer read any
  // state of the glue's.
  for (const char *list : lists) drop_repeated(g, repeated, list);
  CAMLreturn(Val_unit);
}
