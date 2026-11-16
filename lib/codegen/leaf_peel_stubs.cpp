/* A recursive function's base case made at each of its self-calls with no
   call, as for binary-trees' `build`: at a call
   `build(item - delta, depth - 1)` it tests `depth - 1 > 0` itself,
   calls when it holds and writes the leaf node in place when it does not,
   so half of all nodes (the leaves) take no call.

   After LLVM's passes, a function F of the program that calls itself, of
   at most a budget of instructions, is looked at for a conditional branch
   whose condition is an integer compare of its arguments and constants (or
   of one add or subtract of an argument and a constant) and with one side
   from which, the branch taken that way, no call of F is reachable from
   F's entry: the base case. Since arguments do not change, the condition
   tested at a call with that call's arguments is what F would find there.
   F is cloned as F$leaf with the branch made to go that side always (so
   it makes no call of F), and each call of F in F becomes a call of
   F$peel, which tests the condition on its arguments and calls F or
   F$leaf; F$peel and F$leaf are always inlined, by the passes run again
   after this one.

   A function whose entry block allocates more than a budget of bytes of
   machine stack is left: the inlined leaf brings its own copies of those
   allocations into F's frame, so each level of the recursion would take
   twice the stack it did. Five levels of a function holding a 1.1 MB
   value (tests/memory-probes `bigbox`) then pass macOS's 8 MiB. */

#include "llvm/IR/DataLayout.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Utils/ValueMapper.h"

#include <set>
#include <string>
#include <vector>

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Value *from_val(value v) { return reinterpret_cast<llvm::Value *>(v & ~(value)1); }

/* Whether [v] is computed only from arguments and constants, in at most
   [depth] instructions deep. */
static bool from_arguments(llvm::Value *v, int depth) {
  if (llvm::isa<llvm::Argument>(v) || llvm::isa<llvm::ConstantInt>(v)) return true;
  if (depth == 0) return false;
  if (auto *c = llvm::dyn_cast<llvm::CastInst>(v)) return from_arguments(c->getOperand(0), depth - 1);
  if (auto *b = llvm::dyn_cast<llvm::BinaryOperator>(v)) {
    switch (b->getOpcode()) {
    case llvm::Instruction::Add:
    case llvm::Instruction::Sub:
    case llvm::Instruction::And:
      return from_arguments(b->getOperand(0), depth - 1) && from_arguments(b->getOperand(1), depth - 1);
    default:
      return false;
    }
  }
  return false;
}

static bool calls(llvm::BasicBlock &b, llvm::Function *f) {
  for (auto &i : b)
    if (auto *c = llvm::dyn_cast<llvm::CallBase>(&i))
      if (c->getCalledFunction() == f) return true;
  return false;
}

/* Whether a call of [f] is reachable from its entry with [br] taking only
   its successor [side]. */
static bool recurses(llvm::Function *f, llvm::BranchInst *br, unsigned side) {
  std::set<llvm::BasicBlock *> seen;
  std::vector<llvm::BasicBlock *> work{&f->getEntryBlock()};
  while (!work.empty()) {
    auto *b = work.back();
    work.pop_back();
    if (!seen.insert(b).second) continue;
    if (calls(*b, f)) return true;
    auto *t = b->getTerminator();
    if (t == br) {
      work.push_back(br->getSuccessor(side));
      continue;
    }
    for (unsigned i = 0; i < t->getNumSuccessors(); i++) work.push_back(t->getSuccessor(i));
  }
  return false;
}

/* [v] made at [b], with each argument of [f] replaced by the one [call]
   passes. */
static llvm::Value *at_call(llvm::IRBuilder<> &b, llvm::Value *v, llvm::CallBase *call) {
  if (auto *a = llvm::dyn_cast<llvm::Argument>(v)) return call->getArgOperand(a->getArgNo());
  if (llvm::isa<llvm::Constant>(v)) return v;
  auto *i = llvm::cast<llvm::Instruction>(v)->clone();
  for (unsigned k = 0; k < i->getNumOperands(); k++) i->setOperand(k, at_call(b, i->getOperand(k), call));
  return b.Insert(i);
}

/* The bytes [f]'s entry block allocates, those of known size. */
static uint64_t frame_bytes(llvm::Function *f) {
  const llvm::DataLayout &layout = f->getParent()->getDataLayout();
  uint64_t bytes = 0;
  for (auto &i : f->getEntryBlock())
    if (auto *a = llvm::dyn_cast<llvm::AllocaInst>(&i))
      if (auto size = a->getAllocationSize(layout); size && !size->isScalable()) bytes += size->getFixedValue();
  return bytes;
}

extern "C" value zane_leaf_peel(value fv, value budget, value frame) {
  CAMLparam3(fv, budget, frame);
  auto *f = llvm::cast<llvm::Function>(from_val(fv));
  std::string name = f->getName().str();
  if (f->isDeclaration() || name.find('$') == std::string::npos || name.find("%c$") != std::string::npos ||
      f->isVarArg())
    CAMLreturn(Val_int(0));
  size_t size = 0;
  std::vector<llvm::CallBase *> self;
  for (auto &b : *f)
    for (auto &i : b) {
      size++;
      if (auto *c = llvm::dyn_cast<llvm::CallBase>(&i))
        if (c->getCalledFunction() == f && llvm::isa<llvm::CallInst>(c)) self.push_back(c);
    }
  if (self.empty() || size > (size_t)Long_val(budget) || frame_bytes(f) > (uint64_t)Long_val(frame))
    CAMLreturn(Val_int(0));
  /* The base case's branch. */
  llvm::BranchInst *base = nullptr;
  unsigned side = 0;
  for (auto &b : *f) {
    auto *br = llvm::dyn_cast<llvm::BranchInst>(b.getTerminator());
    if (!br || !br->isConditional()) continue;
    auto *cmp = llvm::dyn_cast<llvm::ICmpInst>(br->getCondition());
    if (!cmp || !from_arguments(cmp->getOperand(0), 2) || !from_arguments(cmp->getOperand(1), 2)) continue;
    for (unsigned s = 0; s < 2 && !base; s++)
      if (!recurses(f, br, s) && recurses(f, br, 1 - s)) {
        base = br;
        side = s;
      }
    if (base) break;
  }
  if (!base) CAMLreturn(Val_int(0));
  llvm::Module *m = f->getParent();
  llvm::LLVMContext &ctx = m->getContext();
  /* F$leaf: F with the base case's branch always taken. */
  llvm::ValueToValueMapTy map;
  llvm::Function *leaf = llvm::CloneFunction(f, map);
  leaf->setName(name + "$leaf");
  leaf->setLinkage(llvm::GlobalValue::InternalLinkage);
  leaf->addFnAttr(llvm::Attribute::AlwaysInline);
  leaf->removeFnAttr(llvm::Attribute::NoInline);
  auto *leaf_br = llvm::cast<llvm::BranchInst>(map[base]);
  leaf_br->setCondition(side == 0 ? llvm::ConstantInt::getTrue(ctx) : llvm::ConstantInt::getFalse(ctx));
  /* F$peel: the test, then F or F$leaf. */
  llvm::Function *peel =
      llvm::Function::Create(f->getFunctionType(), llvm::GlobalValue::InternalLinkage, name + "$peel", m);
  peel->copyAttributesFrom(f);
  peel->addFnAttr(llvm::Attribute::AlwaysInline);
  peel->removeFnAttr(llvm::Attribute::NoInline);
  auto *entry = llvm::BasicBlock::Create(ctx, "", peel);
  auto *deep = llvm::BasicBlock::Create(ctx, "", peel);
  auto *shallow = llvm::BasicBlock::Create(ctx, "", peel);
  llvm::IRBuilder<> b(entry);
  std::vector<llvm::Value *> args;
  for (auto &a : peel->args()) args.push_back(&a);
  /* The compare made on F$peel's arguments: a call of F$peel's own, its
     operands being the arguments, stands in for the call. */
  auto *probe = b.CreateCall(f, args);
  auto *cond = at_call(b, base->getCondition(), probe);
  probe->eraseFromParent();
  if (side == 0) b.CreateCondBr(cond, shallow, deep);
  else b.CreateCondBr(cond, deep, shallow);
  auto finish = [&](llvm::BasicBlock *bb, llvm::Function *callee) {
    llvm::IRBuilder<> c(bb);
    auto *call = c.CreateCall(callee, args);
    call->setCallingConv(f->getCallingConv());
    if (f->getReturnType()->isVoidTy()) c.CreateRetVoid();
    else c.CreateRet(call);
  };
  finish(deep, f);
  finish(shallow, leaf);
  for (auto *c : self) c->setCalledFunction(peel);
  CAMLreturn(Val_int(1));
}
