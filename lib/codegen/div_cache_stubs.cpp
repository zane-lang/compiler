/* EXPERIMENT (LangArena zane-vs-goose; on with ZANE_DIV_CACHE=1): a 64-bit
   signed division or remainder in a loop, by a divisor that is not a
   constant, made a multiplication by the divisor's reciprocal, as Goose's
   compiler does for a divisor its loop does not change.

   The divisor need not be one LLVM can see is the same each time round:
   ArithEncode's `total` is read again from its frame after each call the
   loop makes. So each division keeps, in three allocas the passes after
   make registers, the divisor it last saw and that divisor's multiplier
   and shift (runtime/block.c, `zane_div_magic`); a different divisor is
   noted and divided the plain way, and its multiplier made when it comes
   again. The quotient of |x| by |d| is then libdivide's
   unsigned one, and takes the sign of x * d. A divisor of 0, 1 or -1
   (`more` 255) divides the plain way, so the division keeps what it did
   for those, the wrap of the least integer by -1 included. */

#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Transforms/Utils/BasicBlockUtils.h"
#include "llvm/Transforms/Utils/LoopUtils.h"

#include <cstdio>

#include <cstdlib>
#include <string>
#include <vector>

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Value *from_val(value v) { return reinterpret_cast<llvm::Value *>(v & ~(value)1); }

extern "C" value zane_div_cache(value fv) {
  CAMLparam1(fv);
  auto *f = llvm::cast<llvm::Function>(from_val(fv));
  llvm::DominatorTree dt(*f);
  llvm::LoopInfo li(dt);
  std::vector<llvm::BinaryOperator *> sites;
  for (auto &b : *f) {
    if (!li.getLoopFor(&b)) continue;
    for (auto &i : b) {
      auto *op = llvm::dyn_cast<llvm::BinaryOperator>(&i);
      if (!op || !op->getType()->isIntegerTy(64)) continue;
      if (op->getOpcode() != llvm::Instruction::SDiv && op->getOpcode() != llvm::Instruction::SRem) continue;
      if (llvm::isa<llvm::Constant>(op->getOperand(1))) continue;
      sites.push_back(op);
    }
  }
  if (sites.empty()) CAMLreturn(Val_int(0));
  llvm::Module *m = f->getParent();
  llvm::LLVMContext &ctx = m->getContext();
  auto *i64 = llvm::Type::getInt64Ty(ctx);
  auto *i128 = llvm::Type::getInt128Ty(ctx);
  auto *pair = llvm::StructType::get(ctx, {i64, i64});
  llvm::FunctionCallee magic = m->getOrInsertFunction("zane_div_magic", llvm::FunctionType::get(pair, {i64}, false));
  if (auto *g = llvm::dyn_cast<llvm::Function>(magic.getCallee())) {
    g->setDoesNotThrow();
    g->setWillReturn();
    g->setDoesNotAccessMemory();
  }
  llvm::IRBuilder<> entry(&*f->getEntryBlock().getFirstInsertionPt());
  const char *hoist_env = getenv("ZANE_DIV_HOIST");
  bool hoist = hoist_env && std::string(hoist_env) == "1";
  for (auto *op : sites) {
    bool rem = op->getOpcode() == llvm::Instruction::SRem;
    llvm::Value *x = op->getOperand(0), *d = op->getOperand(1);
    /* EXPERIMENT (ZANE_DIV_HOIST=1): a divisor the loop does not change
       is looked up in its cache once, before the outermost loop that does
       not change it, rather than at each division: ArithEncode's `total`, once
       the frame's slots stay in registers across the bit writer's push
       (ZANE_SHADOW_REFILL). `zane_div_magic` gives `more` 255 for 0 and 1,
       as for -1 after the absolute value, which then divide the plain way. */
    llvm::Loop *outer = nullptr;
    if (hoist)
      for (llvm::Loop *l = li.getLoopFor(op->getParent()); l && l->isLoopInvariant(d); l = l->getParentLoop())
        outer = l;
    llvm::BasicBlock *preheader = nullptr;
    if (outer) {
      preheader = outer->getLoopPreheader();
      if (!preheader) preheader = llvm::InsertPreheaderForLoop(outer, &dt, &li, nullptr, false);
    }
    if (getenv("ZANE_DIV_CACHE_DEBUG"))
      fprintf(stderr, "div cache: %s: %s\n", f->getName().str().c_str(),
              !outer ? "cached" : preheader ? "hoisted" : "no preheader");
    if (preheader) {
      /* The cache's protocol, made once per entry to the loop rather than
         at each division: making the multiplier is itself a division, and
         a loop entered often for few passes would pay it at each entry. */
      auto *seen = entry.CreateAlloca(i64, nullptr, "div.d");
      auto *mul = entry.CreateAlloca(i64, nullptr, "div.m");
      auto *more = entry.CreateAlloca(i64, nullptr, "div.more");
      entry.CreateStore(llvm::ConstantInt::get(i64, 0), seen);
      entry.CreateStore(llvm::ConstantInt::get(i64, 0), mul);
      entry.CreateStore(llvm::ConstantInt::get(i64, 255), more);
      llvm::Instruction *at = preheader->getTerminator();
      llvm::IRBuilder<> pre(at);
      auto *same = pre.CreateICmpEQ(d, pre.CreateLoad(i64, seen));
      llvm::Instruction *sameT = nullptr, *newT = nullptr;
      llvm::SplitBlockAndInsertIfThenElse(same, at->getIterator(), &sameT, &newT);
      {
        llvm::IRBuilder<> n(newT);
        n.CreateStore(d, seen);
        n.CreateStore(llvm::ConstantInt::get(i64, 254), more);
      }
      {
        llvm::IRBuilder<> s(sameT);
        auto *pending = s.CreateICmpEQ(s.CreateLoad(i64, more), llvm::ConstantInt::get(i64, 254));
        llvm::Instruction *fresh = llvm::SplitBlockAndInsertIfThen(pending, sameT->getIterator(), false);
        llvm::IRBuilder<> g(fresh);
        auto *neg = g.CreateICmpSLT(d, llvm::ConstantInt::get(i64, 0));
        auto *ad = g.CreateSelect(neg, g.CreateNeg(d), d);
        auto *r = g.CreateCall(magic, {ad});
        g.CreateStore(g.CreateExtractValue(r, 0), mul);
        g.CreateStore(g.CreateExtractValue(r, 1), more);
      }
      pre.SetInsertPoint(at);
      llvm::Value *mu = pre.CreateLoad(i64, mul), *mo = pre.CreateLoad(i64, more);
      llvm::IRBuilder<> b(op);
      auto *plain = b.CreateICmpUGE(mo, llvm::ConstantInt::get(i64, 254));
      llvm::Instruction *thenT = nullptr, *elseT = nullptr;
      llvm::SplitBlockAndInsertIfThenElse(plain, op->getIterator(), &thenT, &elseT);
      llvm::BasicBlock *tail = op->getParent();
      op->moveBefore(thenT->getIterator());
      llvm::BasicBlock *plainB = thenT->getParent();
      llvm::IRBuilder<> q(elseT);
      auto *c63 = llvm::ConstantInt::get(i64, 63);
      auto *sx = q.CreateAShr(x, c63);
      auto *sd = q.CreateAShr(d, c63);
      auto *ax = q.CreateSub(q.CreateXor(x, sx), sx);
      auto *hi = q.CreateTrunc(
          q.CreateLShr(q.CreateMul(q.CreateZExt(mu, i128), q.CreateZExt(ax, i128)), llvm::ConstantInt::get(i128, 64)), i64);
      auto *add = q.CreateICmpNE(q.CreateAnd(mo, llvm::ConstantInt::get(i64, 64)), llvm::ConstantInt::get(i64, 0));
      auto *t = q.CreateAdd(q.CreateLShr(q.CreateSub(ax, hi), llvm::ConstantInt::get(i64, 1)), hi);
      auto *u = q.CreateLShr(q.CreateSelect(add, t, hi), q.CreateAnd(mo, c63));
      auto *sq = q.CreateXor(sx, sd);
      llvm::Value *res = q.CreateSub(q.CreateXor(u, sq), sq);
      if (rem) res = q.CreateSub(x, q.CreateMul(res, d));
      llvm::BasicBlock *fastB = elseT->getParent();
      llvm::IRBuilder<> j(&*tail->begin());
      auto *phi = j.CreatePHI(i64, 2);
      op->replaceAllUsesWith(phi);
      phi->addIncoming(op, plainB);
      phi->addIncoming(res, fastB);
      continue;
    }
    auto *seen = entry.CreateAlloca(i64, nullptr, "div.d");
    auto *mul = entry.CreateAlloca(i64, nullptr, "div.m");
    auto *more = entry.CreateAlloca(i64, nullptr, "div.more");
    entry.CreateStore(llvm::ConstantInt::get(i64, 0), seen);
    entry.CreateStore(llvm::ConstantInt::get(i64, 0), mul);
    entry.CreateStore(llvm::ConstantInt::get(i64, 255), more);
    /* A divisor other than the last is only noted, and divides the plain
       way: a loop whose divisor changes each time pays one compare. The
       second division by the same one makes its multiplier and shift
       (`more` 254 until then). */
    llvm::IRBuilder<> b(op);
    auto *same = b.CreateICmpEQ(d, b.CreateLoad(i64, seen));
    llvm::Instruction *sameT = nullptr, *newT = nullptr;
    llvm::SplitBlockAndInsertIfThenElse(same, op->getIterator(), &sameT, &newT);
    {
      llvm::IRBuilder<> n(newT);
      n.CreateStore(d, seen);
      n.CreateStore(llvm::ConstantInt::get(i64, 254), more);
    }
    {
      llvm::IRBuilder<> s(sameT);
      auto *pending = s.CreateICmpEQ(s.CreateLoad(i64, more), llvm::ConstantInt::get(i64, 254));
      llvm::Instruction *fresh = llvm::SplitBlockAndInsertIfThen(pending, sameT->getIterator(), false);
      llvm::IRBuilder<> g(fresh);
      auto *neg = g.CreateICmpSLT(d, llvm::ConstantInt::get(i64, 0));
      auto *ad = g.CreateSelect(neg, g.CreateNeg(d), d);
      auto *r = g.CreateCall(magic, {ad});
      g.CreateStore(g.CreateExtractValue(r, 0), mul);
      g.CreateStore(g.CreateExtractValue(r, 1), more);
    }
    b.SetInsertPoint(op);
    auto *mo = b.CreateLoad(i64, more);
    auto *mu = b.CreateLoad(i64, mul);
    auto *plain = b.CreateICmpUGE(mo, llvm::ConstantInt::get(i64, 254));
    llvm::Instruction *thenT = nullptr, *elseT = nullptr;
    llvm::SplitBlockAndInsertIfThenElse(plain, op->getIterator(), &thenT, &elseT);
    llvm::BasicBlock *tail = op->getParent();
    /* The plain way: the division itself, moved. */
    op->moveBefore(thenT->getIterator());
    llvm::BasicBlock *plainB = thenT->getParent();
    /* The reciprocal's way. */
    llvm::IRBuilder<> q(elseT);
    auto *c63 = llvm::ConstantInt::get(i64, 63);
    auto *sx = q.CreateAShr(x, c63);
    auto *sd = q.CreateAShr(d, c63);
    auto *ax = q.CreateSub(q.CreateXor(x, sx), sx);
    auto *hi = q.CreateTrunc(
        q.CreateLShr(q.CreateMul(q.CreateZExt(mu, i128), q.CreateZExt(ax, i128)), llvm::ConstantInt::get(i128, 64)), i64);
    auto *add = q.CreateICmpNE(q.CreateAnd(mo, llvm::ConstantInt::get(i64, 64)), llvm::ConstantInt::get(i64, 0));
    auto *t = q.CreateAdd(q.CreateLShr(q.CreateSub(ax, hi), llvm::ConstantInt::get(i64, 1)), hi);
    auto *u = q.CreateLShr(q.CreateSelect(add, t, hi), q.CreateAnd(mo, c63));
    auto *sq = q.CreateXor(sx, sd);
    llvm::Value *res = q.CreateSub(q.CreateXor(u, sq), sq);
    if (rem) res = q.CreateSub(x, q.CreateMul(res, d));
    llvm::BasicBlock *fastB = elseT->getParent();
    llvm::IRBuilder<> j(&*tail->begin());
    auto *phi = j.CreatePHI(i64, 2);
    op->replaceAllUsesWith(phi);
    phi->addIncoming(op, plainB);
    phi->addIncoming(res, fastB);
  }
  CAMLreturn(Val_int((long)sites.size()));
}
