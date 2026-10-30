/* A dependency's C module made a retained copy (docs/design/ffi.md F13):
   bodies LLVM may inline and emits nothing for, the dependency's own
   object defining each of them.

   The lists of constructors, destructors and objects marked `used` or
   `retain` go, and so does the module's file-scope assembly: the object
   runs and emits those once. Every function and variable that other
   modules can link against is `available_externally`, or a declaration
   when its body is not the object's code to copy: a variable that is not
   a constant, a weak definition another object may override, a constant
   holding the address of something local to the module or of a label,
   and a function that shares state the object owns or lets out an
   address a copy would change. That is a function that reaches a variable local to the module
   that is not a constant (a `static` counter, or a `static const volatile`
   word, which LLVM holds as no constant either), or a local constant or
   function placed in an explicit section, or takes a label's address
   (a computed `goto`'s), or that does anything with a
   local constant's address but read through it (one whose address LLVM
   may merge, as a string literal's, aside), or with a local
   function's but call it, or that calls a local function that does any
   of those. What is local and still reached is copied; what nothing
   reaches is removed. Aliases and indirect functions are declarations.
   Whether anything was retained comes back: false when what is left
   would still need a local definition it reaches, which leaves the
   caller to drop the whole module. */

#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalIFunc.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"

#include <set>
#include <utility>
#include <vector>

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

static llvm::Module *module_of(value v) { return reinterpret_cast<llvm::Module *>(v & ~(value)1); }

static const char *const dropped_lists[] = {"llvm.global_ctors", "llvm.global_dtors", "llvm.used", "llvm.compiler.used"};

/* Whether [c], a global's initializer, holds the address of anything
   local to the module, a label's among them: a copy's labels are not the
   object's. */
static bool holds_local(const llvm::Constant *c, std::set<const llvm::Constant *> &seen) {
  if (!c || !seen.insert(c).second) return false;
  if (llvm::isa<llvm::BlockAddress>(c)) return true;
  if (auto *g = llvm::dyn_cast<llvm::GlobalValue>(c)) return g->hasLocalLinkage();
  for (const llvm::Use &op : c->operands())
    if (holds_local(llvm::cast<llvm::Constant>(op.get()), seen)) return true;
  return false;
}

static bool holds_local(const llvm::Constant *c) {
  std::set<const llvm::Constant *> seen;
  return holds_local(c, seen);
}

/* Whether [v], a local object a copy would duplicate, is shared state:
   a variable that is not a constant, a thread's own, or any object placed
   in an explicit section, which the linker may gather with the object's. */
static bool shared_state(const llvm::GlobalObject &o) {
  if (o.hasSection()) return true;
  if (auto *v = llvm::dyn_cast<llvm::GlobalVariable>(&o))
    return !v->isConstant() || v->isThreadLocal() || holds_local(v->getInitializer());
  return false;
}

/* Whether the use [u] of a local constant only reads through its address:
   a load from it, or an address computed from it that is only read. */
static bool only_read(const llvm::Use &u) {
  const llvm::User *user = u.getUser();
  if (auto *load = llvm::dyn_cast<llvm::LoadInst>(user)) return !load->isVolatile() && load->getPointerOperandIndex() == u.getOperandNo();
  if (llvm::isa<llvm::GEPOperator>(user)) {
    for (const llvm::Use &next : user->uses())
      if (!only_read(next)) return false;
    return true;
  }
  return false;
}

/* The functions whose instructions [u] is a use in, through the constant
   expressions between. */
static void using_functions(const llvm::Use &u, std::set<llvm::Function *> &into) {
  llvm::User *user = u.getUser();
  if (auto *i = llvm::dyn_cast<llvm::Instruction>(user)) {
    into.insert(i->getFunction());
    return;
  }
  if (llvm::isa<llvm::ConstantExpr>(user) || llvm::isa<llvm::ConstantAggregate>(user))
    for (const llvm::Use &next : user->uses()) using_functions(next, into);
}

/* Each function whose body cannot be copied ([unsafe]), from the local
   objects it reaches, and then every function that calls or names a
   local function among them. */
static std::set<llvm::Function *> unsafe_functions(llvm::Module *m) {
  std::set<llvm::Function *> unsafe;
  auto mark = [&](const llvm::Use &u) { using_functions(u, unsafe); };
  for (llvm::GlobalObject &o : m->global_objects()) {
    if (!o.hasLocalLinkage() || o.isDeclaration()) continue;
    bool state = shared_state(o);
    // A string literal's address, or any other LLVM is free to merge,
    // tells no copy from the original.
    if (!state && o.hasGlobalUnnamedAddr()) continue;
    for (const llvm::Use &u : o.uses()) {
      if (state) {
        mark(u);
        continue;
      }
      if (llvm::isa<llvm::Function>(o)) {
        auto *call = llvm::dyn_cast<llvm::CallBase>(u.getUser());
        if (!(call && call->isCallee(&u))) mark(u);
      } else if (!only_read(u))
        mark(u);
    }
  }
  // A function whose labels' addresses are taken lets out addresses a
  // copy would change.
  for (llvm::Function &f : m->functions())
    for (llvm::BasicBlock &b : f)
      if (b.hasAddressTaken()) unsafe.insert(&f);
  std::vector<llvm::Function *> work(unsafe.begin(), unsafe.end());
  while (!work.empty()) {
    llvm::Function *f = work.back();
    work.pop_back();
    if (!f->hasLocalLinkage()) continue;
    std::set<llvm::Function *> callers;
    for (const llvm::Use &u : f->uses()) using_functions(u, callers);
    for (llvm::Function *c : callers)
      if (unsafe.insert(c).second) work.push_back(c);
  }
  return unsafe;
}

/* A declaration standing for the alias or indirect function [v]. */
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

/* Whether a definition of [linkage] is the object's code to copy: one no
   other object's definition may replace. */
static bool copyable(llvm::GlobalValue::LinkageTypes linkage) {
  return linkage == llvm::GlobalValue::ExternalLinkage || linkage == llvm::GlobalValue::WeakODRLinkage ||
         linkage == llvm::GlobalValue::LinkOnceODRLinkage || linkage == llvm::GlobalValue::AvailableExternallyLinkage;
}

static void declare(llvm::GlobalObject &o) {
  if (auto *f = llvm::dyn_cast<llvm::Function>(&o))
    f->deleteBody();
  else if (auto *v = llvm::dyn_cast<llvm::GlobalVariable>(&o)) {
    v->setInitializer(nullptr);
    v->setLinkage(llvm::GlobalValue::ExternalLinkage);
  }
}

extern "C" value zane_retain_c(value mod) {
  CAMLparam1(mod);
  llvm::Module *m = module_of(mod);
  for (const char *list : dropped_lists)
    if (llvm::GlobalVariable *v = m->getNamedGlobal(list)) v->eraseFromParent();
  m->setModuleInlineAsm("");
  // A local alias is its aliasee; any other alias or indirect function is
  // the object's, and a local indirect function is one no copy can share.
  std::vector<llvm::GlobalAlias *> aliases;
  for (llvm::GlobalAlias &a : m->aliases()) aliases.push_back(&a);
  for (llvm::GlobalAlias *a : aliases) {
    if (a->hasLocalLinkage()) {
      a->replaceAllUsesWith(a->getAliasee());
      a->eraseFromParent();
    } else
      declare_instead(a);
  }
  for (llvm::GlobalIFunc &i : m->ifuncs())
    if (i.hasLocalLinkage()) CAMLreturn(Val_false);
  while (!m->ifunc_empty()) declare_instead(&*m->ifunc_begin());
  for (llvm::GlobalObject &o : m->global_objects()) o.setComdat(nullptr);

  std::set<llvm::Function *> unsafe = unsafe_functions(m);
  // Each is judged before any body goes, since a body going changes the
  // initializers that hold its labels' addresses.
  std::vector<std::pair<llvm::GlobalObject *, bool>> judged;
  for (llvm::GlobalObject &o : m->global_objects()) {
    if (o.isDeclaration() || o.hasLocalLinkage()) continue;
    auto *f = llvm::dyn_cast<llvm::Function>(&o);
    auto *v = llvm::dyn_cast<llvm::GlobalVariable>(&o);
    bool keep = copyable(o.getLinkage()) &&
                (f ? !unsafe.count(f) : v && v->isConstant() && !v->isThreadLocal() && !holds_local(v->getInitializer()));
    judged.emplace_back(&o, keep);
  }
  for (llvm::Function &f : m->functions())
    if (f.hasLocalLinkage() && !f.isDeclaration() && unsafe.count(&f)) f.dropAllReferences();
  for (auto [o, keep] : judged) {
    if (keep)
      o->setLinkage(llvm::GlobalValue::AvailableExternallyLinkage);
    else
      declare(*o);
  }
  // What is local and no longer reached goes, until nothing more does.
  for (bool changed = true; changed;) {
    changed = false;
    std::vector<llvm::GlobalObject *> unused;
    for (llvm::GlobalObject &o : m->global_objects()) {
      if (!o.hasLocalLinkage()) continue;
      o.removeDeadConstantUsers();
      if (o.use_empty()) unused.push_back(&o);
    }
    for (llvm::GlobalObject *o : unused) {
      if (auto *v = llvm::dyn_cast<llvm::GlobalVariable>(o)) v->setInitializer(nullptr);
      o->dropAllReferences();
      o->eraseFromParent();
      changed = true;
    }
  }
  for (llvm::GlobalObject &o : m->global_objects())
    if (o.hasLocalLinkage() && o.isDeclaration()) CAMLreturn(Val_false);
  CAMLreturn(Val_true);
}
