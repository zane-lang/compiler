/* What tier 1 of a tiered build needs of LLVM that its C API does not give
   (docs/design/tiers.md): every use of a value made a load from a table the
   runtime fills. [zane_tier_import] first turns each constant expression
   that uses the value inside a function into instructions, so a use folded
   into an address computation is reached too. A use left in a constant no
   function holds, such as another variable's initial value, cannot load
   anything, and the import fails. A thread-local variable has an address
   only on some thread, so for one the table holds a function of tier 0's
   that gives it, and each place the code asks for the variable's address
   on the thread it runs on calls that function instead. */

#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/ReplaceConstant.h"
#include "llvm-c/Types.h"

#include <vector>

extern "C" {
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* The bindings carry an LLVM pointer with its low bit set (llvm_stubs.c). */
static llvm::Value *from_val(value v) { return reinterpret_cast<llvm::Value *>(v & ~(value)1); }

extern "C" value zane_tier_import(value global, value table, value index) {
  CAMLparam3(global, table, index);
  auto *g = llvm::cast<llvm::Constant>(from_val(global));
  auto *t = llvm::cast<llvm::GlobalVariable>(from_val(table));
  llvm::convertUsersOfConstantsToInstructions({g});
  std::vector<llvm::User *> users(g->user_begin(), g->user_end());
  for (llvm::User *u : users)
    if (!llvm::isa<llvm::Instruction>(u)) CAMLreturn(Val_false);
  auto *ptr = llvm::PointerType::getUnqual(g->getContext());
  auto load = [&](llvm::Instruction *before) {
    llvm::IRBuilder<> b(before);
    llvm::Value *at = b.CreateConstInBoundsGEP1_64(ptr, t, Long_val(index));
    return b.CreateAlignedLoad(ptr, at, llvm::Align(8));
  };
  auto *variable = llvm::dyn_cast<llvm::GlobalVariable>(g);
  bool thread = variable && variable->isThreadLocal();
  auto *accessor = llvm::FunctionType::get(ptr, false);
  /* What the code reads in [g]'s place, made just before [before]. */
  auto address = [&](llvm::Instruction *before) -> llvm::Value * {
    llvm::Value *loaded = load(before);
    if (!thread) return loaded;
    llvm::IRBuilder<> b(before);
    return b.CreateCall(accessor, loaded);
  };
  for (llvm::User *u : users) {
    auto *i = llvm::cast<llvm::Instruction>(u);
    auto *asked = llvm::dyn_cast<llvm::IntrinsicInst>(i);
    if (asked && asked->getIntrinsicID() == llvm::Intrinsic::threadlocal_address) {
      asked->replaceAllUsesWith(address(asked));
      asked->eraseFromParent();
    } else if (auto *phi = llvm::dyn_cast<llvm::PHINode>(i)) {
      for (unsigned k = 0; k < phi->getNumIncomingValues(); k++)
        if (phi->getIncomingValue(k) == g)
          phi->setIncomingValue(k, address(phi->getIncomingBlock(k)->getTerminator()));
    } else {
      i->replaceUsesOfWith(g, address(i));
    }
  }
  CAMLreturn(Val_bool(g->use_empty()));
}
