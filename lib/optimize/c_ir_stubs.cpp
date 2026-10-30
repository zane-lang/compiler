/* A function or a global of a package's C module written out as text, for
   stage 5's C evaluator to read (docs/design/ffi.md F16, lib/optimize/c_ir.ml).

   The text is words separated by spaces: a number in decimal, a name as
   its length, a colon and its bytes, and a tag as a short word. It holds
   what the evaluator needs and LLVM's OCaml bindings do not give: an
   instruction's flags (`nsw`, `nuw`, `exact`, `disjoint`, `nneg`, any
   fast-math flag), whether a load or store is atomic, an `alloca`'s size,
   a `byval` argument's, and every offset the target's data layout gives:
   a struct's fields, an array's stride, and a `getelementptr` as a
   constant offset plus each variable index times its scale. */

#include "llvm/ADT/MapVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/DataLayout.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GetElementPtrTypeIterator.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"

#include <map>
#include <string>

extern "C" {
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

using namespace llvm;

static Module *module_of(value v) { return reinterpret_cast<Module *>(v & ~(value)1); }

namespace {

/* Whether the constant indices of [gep] sum, scaled, past what [width]
   bits hold: `collectOffset` wraps them, so an address moved by more than
   any allocation spans would read as one moved by less. */
static bool offset_wraps(GEPOperator *gep, const DataLayout &dl, unsigned width) {
  APInt sum(width, 0);
  bool over = false;
  for (auto t = gep_type_begin(gep), e = gep_type_end(gep); t != e && !over; ++t) {
    auto *ci = dyn_cast<ConstantInt>(t.getOperand());
    if (!ci || t.isStruct()) continue;
    APInt index = ci->getValue().sextOrTrunc(width);
    APInt step = index.smul_ov(APInt(width, t.getSequentialElementStride(dl).getFixedValue()), over);
    if (!over) sum = sum.sadd_ov(step, over);
  }
  return over;
}

/* Whether a constant expression carries a flag that makes it poison on
   overflow or an inexact result; the evaluator models those only on
   instructions, so such a constant is one it does not model. */
static bool wrap_flags(const ConstantExpr *ce) {
  if (auto *o = dyn_cast<OverflowingBinaryOperator>(ce))
    if (o->hasNoSignedWrap() || o->hasNoUnsignedWrap()) return true;
  if (auto *e = dyn_cast<PossiblyExactOperator>(ce))
    if (e->isExact()) return true;
  return false;
}

struct Out {
  std::string s;
  const DataLayout &dl;
  explicit Out(const DataLayout &dl) : dl(dl) {}
  void w(const char *t) {
    s += t;
    s += ' ';
  }
  void n(int64_t v) {
    s += std::to_string(v);
    s += ' ';
  }
  void name(StringRef t) {
    s += std::to_string(t.size());
    s += ':';
    s.append(t.data(), t.size());
    s += ' ';
  }

  void type(Type *t) {
    if (t->isVoidTy()) w("v");
    else if (auto *i = dyn_cast<IntegerType>(t)) {
      w("i");
      n(i->getBitWidth());
    } else if (t->isFloatTy()) w("f");
    else if (t->isDoubleTy()) w("d");
    else if (t->isPointerTy()) w("p");
    else if (auto *v = dyn_cast<FixedVectorType>(t)) {
      w("V");
      n(v->getNumElements());
      type(v->getElementType());
    } else if (auto *st = dyn_cast<StructType>(t)) {
      if (st->isOpaque()) {
        w("o");
        return;
      }
      const StructLayout *l = dl.getStructLayout(st);
      w("S");
      n(dl.getTypeAllocSize(st));
      n(dl.getABITypeAlign(st).value());
      n(st->getNumElements());
      for (unsigned k = 0; k < st->getNumElements(); k++) {
        n(l->getElementOffset(k));
        type(st->getElementType(k));
      }
    } else if (auto *a = dyn_cast<ArrayType>(t)) {
      w("A");
      n(a->getNumElements());
      n(dl.getTypeAllocSize(a->getElementType()));
      n(dl.getABITypeAlign(a).value());
      type(a->getElementType());
    } else w("o");
  }

  void constant(Constant *c) {
    if (auto *ci = dyn_cast<ConstantInt>(c)) {
      if (ci->getBitWidth() > 64) {
        w("X");
        return;
      }
      w("i");
      n(ci->getBitWidth());
      n((int64_t)ci->getValue().getZExtValue());
    } else if (auto *cf = dyn_cast<ConstantFP>(c)) {
      if (!(cf->getType()->isFloatTy() || cf->getType()->isDoubleTy())) {
        w("X");
        return;
      }
      w("f");
      n(cf->getType()->isDoubleTy() ? 1 : 0);
      n((int64_t)cf->getValueAPF().bitcastToAPInt().getZExtValue());
    } else if (isa<ConstantPointerNull>(c)) w("n");
    else if (isa<PoisonValue>(c) || isa<UndefValue>(c)) {
      w("u");
      type(c->getType());
    } else if (isa<ConstantAggregateZero>(c)) {
      w("z");
      type(c->getType());
    } else if (auto *ds = dyn_cast<ConstantDataSequential>(c)) {
      w("a");
      type(c->getType());
      n(ds->getNumElements());
      for (unsigned k = 0; k < ds->getNumElements(); k++) constant(ds->getElementAsConstant(k));
    } else if (isa<ConstantArray>(c) || isa<ConstantStruct>(c) || isa<ConstantVector>(c)) {
      w("a");
      type(c->getType());
      n(c->getNumOperands());
      for (unsigned k = 0; k < c->getNumOperands(); k++) constant(cast<Constant>(c->getOperand(k)));
    } else if (auto *f = dyn_cast<Function>(c)) {
      w("F");
      name(f->getName());
    } else if (isa<GlobalVariable>(c) || isa<GlobalAlias>(c)) {
      w("g");
      name(c->getName());
    } else if (auto *ce = dyn_cast<ConstantExpr>(c)) {
      expression(ce);
    } else w("X");
  }

  void expression(ConstantExpr *ce) {
    if (auto *gep = dyn_cast<GEPOperator>(ce)) {
      APInt offset(dl.getIndexTypeSizeInBits(gep->getType()), 0);
      if (gep->getType()->isVectorTy() || offset_wraps(gep, dl, offset.getBitWidth()) || !gep->accumulateConstantOffset(dl, offset)) {
        w("X");
        return;
      }
      w("G");
      constant(cast<Constant>(gep->getPointerOperand()));
      n(offset.getSExtValue());
    } else if (ce->isCast()) {
      w("C");
      w(ce->getOpcodeName());
      type(ce->getType());
      constant(ce->getOperand(0));
    } else if (Instruction::isBinaryOp(ce->getOpcode()) && !wrap_flags(ce)) {
      w("B");
      w(ce->getOpcodeName());
      constant(ce->getOperand(0));
      constant(ce->getOperand(1));
    } else w("X");
  }
};

struct Function_out : Out {
  std::map<const Value *, int64_t> regs;
  std::map<const BasicBlock *, int64_t> blocks;
  using Out::Out;

  void operand(Value *v) {
    auto r = regs.find(v);
    if (r != regs.end()) {
      w("r");
      n(r->second);
    } else if (auto *c = dyn_cast<Constant>(v)) {
      w("c");
      constant(c);
    } else if (isa<InlineAsm>(v)) w("a");
    else w("m");
  }

  void block(const BasicBlock *b) { n(blocks.at(b)); }

  /* What an instruction's flags are, as bits: 1 `nsw`, 2 `nuw`, 4
     `exact`, 8 `disjoint`, 16 `nneg`, 32 any fast-math flag. */
  int64_t flags(Instruction &i) {
    int64_t f = 0;
    if (isa<OverflowingBinaryOperator>(&i)) {
      if (i.hasNoSignedWrap()) f |= 1;
      if (i.hasNoUnsignedWrap()) f |= 2;
    }
    if (auto *t = dyn_cast<TruncInst>(&i)) {
      if (t->hasNoSignedWrap()) f |= 1;
      if (t->hasNoUnsignedWrap()) f |= 2;
    }
    if (isa<PossiblyExactOperator>(&i) && i.isExact()) f |= 4;
    if (auto *d = dyn_cast<PossiblyDisjointInst>(&i); d && d->isDisjoint()) f |= 8;
    if (auto *p = dyn_cast<PossiblyNonNegInst>(&i); p && p->hasNonNeg()) f |= 16;
    if (isa<FPMathOperator>(&i) && i.getFastMathFlags().any()) f |= 32;
    return f;
  }

  void instruction(Instruction &i) {
    w(i.getOpcodeName());
    type(i.getType());
    n(flags(i));
    if (i.isBinaryOp() || isa<CmpInst>(i) || isa<SelectInst>(i) || isa<FreezeInst>(i) || i.getOpcode() == Instruction::FNeg ||
        isa<ExtractElementInst>(i) || isa<InsertElementInst>(i)) {
      if (auto *cmp = dyn_cast<CmpInst>(&i)) n(cmp->getPredicate());
      n(i.getNumOperands());
      for (Value *op : i.operands()) operand(op);
    } else if (auto *ci = dyn_cast<CastInst>(&i)) {
      type(ci->getSrcTy());
      operand(ci->getOperand(0));
    } else if (auto *a = dyn_cast<AllocaInst>(&i)) {
      n(dl.getTypeAllocSize(a->getAllocatedType()));
      n(a->getAlign().value());
      operand(a->getArraySize());
    } else if (auto *l = dyn_cast<LoadInst>(&i)) {
      n(l->getAlign().value());
      n(l->isVolatile());
      n(l->isAtomic());
      operand(l->getPointerOperand());
    } else if (auto *s = dyn_cast<StoreInst>(&i)) {
      n(s->getAlign().value());
      n(s->isVolatile());
      n(s->isAtomic());
      type(s->getValueOperand()->getType());
      operand(s->getValueOperand());
      operand(s->getPointerOperand());
    } else if (auto *g = dyn_cast<GetElementPtrInst>(&i)) {
      MapVector<Value *, APInt> variable;
      unsigned width = dl.getIndexTypeSizeInBits(g->getType());
      APInt offset(width, 0);
      if (g->getType()->isVectorTy() || offset_wraps(cast<GEPOperator>(g), dl, width) ||
          !cast<GEPOperator>(g)->collectOffset(dl, width, variable, offset)) {
        w("X");
        return;
      }
      w("G");
      operand(g->getPointerOperand());
      n(offset.getSExtValue());
      n(variable.size());
      for (auto &[v, scale] : variable) {
        operand(v);
        n(v->getType()->getScalarSizeInBits());
        n(scale.getSExtValue());
      }
    } else if (auto *p = dyn_cast<PHINode>(&i)) {
      n(p->getNumIncomingValues());
      for (unsigned k = 0; k < p->getNumIncomingValues(); k++) {
        block(p->getIncomingBlock(k));
        operand(p->getIncomingValue(k));
      }
    } else if (auto *c = dyn_cast<CallInst>(&i)) {
      Value *callee = c->getCalledOperand();
      if (auto *f = dyn_cast<Function>(callee)) {
        w("d");
        name(f->getName());
      } else if (isa<InlineAsm>(callee)) w("a");
      else {
        w("i");
        operand(callee);
      }
      n(c->arg_size());
      for (unsigned k = 0; k < c->arg_size(); k++) {
        Type *byval = c->getParamByValType(k);
        n(byval ? (int64_t)dl.getTypeAllocSize(byval) : -1);
        operand(c->getArgOperand(k));
      }
    } else if (auto *e = dyn_cast<ExtractValueInst>(&i)) {
      n(e->getNumIndices());
      for (unsigned k : e->indices()) n(k);
      operand(e->getAggregateOperand());
    } else if (auto *iv = dyn_cast<InsertValueInst>(&i)) {
      n(iv->getNumIndices());
      for (unsigned k : iv->indices()) n(k);
      operand(iv->getAggregateOperand());
      operand(iv->getInsertedValueOperand());
    } else if (auto *sv = dyn_cast<ShuffleVectorInst>(&i)) {
      operand(sv->getOperand(0));
      operand(sv->getOperand(1));
      n(sv->getShuffleMask().size());
      for (int m : sv->getShuffleMask()) n(m);
    } else if (auto *r = dyn_cast<ReturnInst>(&i)) {
      n(r->getReturnValue() ? 1 : 0);
      if (r->getReturnValue()) operand(r->getReturnValue());
    } else if (auto *b = dyn_cast<BranchInst>(&i)) {
      n(b->isConditional());
      if (b->isConditional()) {
        operand(b->getCondition());
        block(b->getSuccessor(0));
        block(b->getSuccessor(1));
      } else block(b->getSuccessor(0));
    } else if (auto *sw = dyn_cast<SwitchInst>(&i)) {
      operand(sw->getCondition());
      block(sw->getDefaultDest());
      n(sw->getNumCases());
      for (auto &k : sw->cases()) {
        n((int64_t)k.getCaseValue()->getValue().getZExtValue());
        block(k.getCaseSuccessor());
      }
    } else if (isa<UnreachableInst>(i)) {
    } else w("X");
  }

  void function(Function &f) {
    int64_t next = 0;
    for (Argument &a : f.args()) regs[&a] = next++;
    int64_t b = 0;
    for (BasicBlock &bb : f) {
      blocks[&bb] = b++;
      for (Instruction &i : bb) regs[&i] = next++;
    }
    w("F");
    n(f.arg_size());
    n(f.isVarArg());
    type(f.getReturnType());
    n(f.size());
    for (BasicBlock &bb : f) {
      n(bb.size());
      for (Instruction &i : bb) instruction(i);
    }
  }
};

value text(const std::string &s) {
  value v = caml_alloc_initialized_string(s.size(), s.data());
  return v;
}

} // namespace

/* The pointer width in bits, whether the target is little-endian, and the
   global prefix its symbols take, `-` for none. */
extern "C" value zane_c_ir_layout(value m) {
  CAMLparam1(m);
  const DataLayout &dl = module_of(m)->getDataLayout();
  std::string s = std::to_string(dl.getPointerSizeInBits()) + " " + (dl.isLittleEndian() ? "1" : "0") + " " +
                  (dl.getGlobalPrefix() ? std::string(1, dl.getGlobalPrefix()) : std::string("-"));
  CAMLreturn(text(s));
}

/* The function [name]: empty when the module has none, `D` and its
   whether it never returns when it only declares it or another object may
   replace its definition, as a weak one, and its body otherwise. */
extern "C" value zane_c_ir_function(value m, value name) {
  CAMLparam2(m, name);
  Module *mod = module_of(m);
  Function *f = mod->getFunction(StringRef(String_val(name), caml_string_length(name)));
  if (!f) CAMLreturn(text(""));
  if (f->isDeclaration() || f->isInterposable()) CAMLreturn(text(std::string("D ") + (f->hasFnAttribute(Attribute::NoReturn) ? "1" : "0")));
  Function_out o(mod->getDataLayout());
  o.function(*f);
  CAMLreturn(text(o.s));
}

/* The global variable or alias [name]: empty when the module has none,
   `D` when it only declares one, an alias's aliasee, and a variable's
   attributes and initializer: whether it is constant, thread-local,
   `unnamed_addr` (1 local, 2 global), its alignment and size. */
extern "C" value zane_c_ir_global(value m, value name) {
  CAMLparam2(m, name);
  Module *mod = module_of(m);
  StringRef n(String_val(name), caml_string_length(name));
  Out o(mod->getDataLayout());
  if (GlobalAlias *a = mod->getNamedAlias(n)) {
    o.w("A");
    o.constant(a->getAliasee());
    CAMLreturn(text(o.s));
  }
  GlobalVariable *g = mod->getGlobalVariable(n, true);
  if (!g) CAMLreturn(text(""));
  if (!g->hasInitializer() || g->isInterposable()) CAMLreturn(text("D"));
  o.w("V");
  o.n(g->isConstant());
  o.n(g->isThreadLocal());
  o.n(g->getUnnamedAddr() == GlobalValue::UnnamedAddr::Local ? 1
      : g->getUnnamedAddr() == GlobalValue::UnnamedAddr::Global ? 2
                                                                : 0);
  o.n(g->getAlign() ? g->getAlign()->value() : mod->getDataLayout().getPreferredAlign(g).value());
  o.n(mod->getDataLayout().getTypeAllocSize(g->getValueType()));
  o.type(g->getValueType());
  o.constant(g->getInitializer());
  CAMLreturn(text(o.s));
}
