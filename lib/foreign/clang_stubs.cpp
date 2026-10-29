/* Clang's front end linked into the compiler, of the compiler's own LLVM
   (docs/design/ffi.md F1), so a package's C is compiled in this process
   and its IR read by the same LLVM that reads the Zane code's.

   Each entry takes a command line as clang's driver reads one, its first
   word the driver's name. The linked driver turns it into a
   [CompilerInvocation] for the target the line names, so every front-end
   option is one this clang made itself. What an entry gives back is plain
   data: bitcode, preprocessed text, and the errors the front end reported,
   each with the file, line and column it points at. */

#include "clang/AST/ASTConsumer.h"
#include "clang/AST/ASTContext.h"
#include "clang/AST/Decl.h"
#include "clang/AST/RecordLayout.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/Version.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/Frontend/Utils.h"
#include "clang/Lex/Preprocessor.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CrashRecoveryContext.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/Triple.h"

#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

extern "C" {
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

namespace {

/* One error the front end reported. A note or a warning is not one: a
   package's C is held only to what makes it fail to compile. */
struct Problem {
  std::string file;
  unsigned line = 0;
  unsigned column = 0;
  std::string message;
};

class Collector : public clang::DiagnosticConsumer {
public:
  std::vector<Problem> problems;

  void HandleDiagnostic(clang::DiagnosticsEngine::Level level, const clang::Diagnostic &info) override {
    clang::DiagnosticConsumer::HandleDiagnostic(level, info);
    if (level < clang::DiagnosticsEngine::Error) return;
    llvm::SmallString<256> text;
    info.FormatDiagnostic(text);
    Problem p;
    p.message = std::string(text);
    if (info.getLocation().isValid() && info.hasSourceManager()) {
      clang::PresumedLoc loc = info.getSourceManager().getPresumedLoc(info.getLocation());
      if (loc.isValid()) {
        const char *file = loc.getFilename();
        p.file = file ? file : "";
        p.line = loc.getLine();
        p.column = loc.getColumn();
      }
    }
    problems.push_back(std::move(p));
  }
};

/* What a run made: [ok] when the front end reported no error, and its
   output, which is meaningful only then. */
struct Run {
  bool ok = false;
  std::string output;
  std::vector<Problem> problems;
};

std::vector<std::string> strings_of(value args) {
  std::vector<std::string> owned;
  for (mlsize_t i = 0; i < Wosize_val(args); i++) owned.emplace_back(String_val(Field(args, i)));
  return owned;
}

/* -E's output, written to a string rather than a file. */
class Preprocess : public clang::PreprocessorFrontendAction {
public:
  explicit Preprocess(std::string &out) : out(out) {}

protected:
  void ExecuteAction() override {
    clang::CompilerInstance &ci = getCompilerInstance();
    /* What `-E` would set: the text itself, with line markers, rather than
       the macro table an invocation without it prints. */
    clang::PreprocessorOutputOptions &opts = ci.getPreprocessorOutputOpts();
    opts.ShowCPP = 1;
    opts.ShowLineMarkers = 1;
    opts.ShowMacros = 0;
    llvm::raw_string_ostream os(out);
    clang::DoPrintPreprocessedInput(ci.getPreprocessor(), &os, opts);
    os.flush();
  }

private:
  std::string &out;
};

/* The command line [args] as an invocation, and [action] run on it. */
template <typename Act> Run run(const std::vector<std::string> &args, Act act) {
  Run result;
  auto collector = std::make_unique<Collector>();
  Collector *problems = collector.get();
  std::vector<const char *> argv;
  for (const std::string &a : args) argv.push_back(a.c_str());
  llvm::CrashRecoveryContext crc;
  bool finished = crc.RunSafely([&] {
    auto diagnostics = clang::CompilerInstance::createDiagnostics(new clang::DiagnosticOptions(), problems, false);
    clang::CreateInvocationOptions options;
    options.Diags = diagnostics;
    std::shared_ptr<clang::CompilerInvocation> invocation = clang::createInvocation(argv, options);
    if (!invocation || !problems->problems.empty()) return;
    /* Without carets the instance prints no "N errors generated" of its
       own: every problem reaches OCaml through [problems] alone. */
    invocation->getDiagnosticOpts().ShowCarets = false;
    clang::CompilerInstance ci;
    ci.setInvocation(invocation);
    ci.createDiagnostics(problems, false);
    result.ok = act(ci) && !ci.getDiagnostics().hasErrorOccurred();
  });
  if (!finished) {
    result.ok = false;
    Problem p;
    p.message = "the C front end crashed";
    problems->problems.push_back(p);
  }
  result.problems = problems->problems;
  return result;
}

/* [(ok, output, problems)], each problem [(file, line, column, message)]. */
value to_value(const Run &r) {
  CAMLparam0();
  CAMLlocal4(result, list, item, cell);
  list = Val_emptylist;
  for (auto it = r.problems.rbegin(); it != r.problems.rend(); ++it) {
    item = caml_alloc_tuple(4);
    Store_field(item, 0, caml_copy_string(it->file.c_str()));
    Store_field(item, 1, Val_int(it->line));
    Store_field(item, 2, Val_int(it->column));
    Store_field(item, 3, caml_copy_string(it->message.c_str()));
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, item);
    Store_field(cell, 1, list);
    list = cell;
  }
  result = caml_alloc_tuple(3);
  Store_field(result, 0, Val_bool(r.ok));
  Store_field(result, 1, caml_alloc_initialized_string(r.output.size(), r.output.data()));
  Store_field(result, 2, list);
  CAMLreturn(result);
}

/* What a header declares, written as text for interface.ml to read: a
   stream of words, each a bare token or, for a name, its length, `:` and
   its bytes. A C type is written canonical, so a typedef reads as what it
   names: `V` void, `B` bool, `I` an integer (sign, size and width in bits,
   its name, and the standard typedef it was written through or nothing), `F` a floating type (size, whether it is IEEE, its name), `P`
   a pointer (whether its pointee is const, the pointee), `R` a struct or
   union (kind and identity, below), `A` an array (count and element), `N` a function
   with a prototype (whether variadic, the parameters, the result), `K` one
   without, and `O` any other, by its spelling. */
class Writer {
public:
  explicit Writer(clang::ASTContext &ctx) : ctx(ctx) {}
  std::string out;
  std::set<const clang::RecordDecl *> records;

  void word(const std::string &w) { out += w; out += ' '; }
  void num(uint64_t n) { word(std::to_string(n)); }
  void str(const std::string &s) { out += std::to_string(s.size()); out += ':'; out += s; out += ' '; }

  /* A struct's identity, as C spells its type: `struct` or `union` and its
     tag, or the typedef that names an anonymous one. A tag and a typedef
     name are in separate namespaces, so `struct Foo` and the anonymous
     struct a typedef `Foo` names are two records. */
  static std::string record_name(const clang::RecordDecl *d) {
    if (d->getIdentifier()) return (d->isUnion() ? "union " : "struct ") + d->getName().str();
    if (const clang::TypedefNameDecl *t = d->getTypedefNameForAnonDecl()) return t->getName().str();
    return "";
  }

  /* The standard name an integer type was written through, if any: the
     first of <stdint.h>'s and <stddef.h>'s typedefs that [q]'s sugar
     passes, so `int64_t` is known as itself where it is a `long`. */
  std::string standard_name(clang::QualType q) {
    static const std::set<std::string> standard = {
        "int8_t",  "uint8_t",  "int16_t", "uint16_t", "int32_t",  "uint32_t",  "int64_t",
        "uint64_t", "size_t",  "ptrdiff_t", "intptr_t", "uintptr_t"};
    clang::QualType cur = q;
    while (true) {
      if (const auto *t = llvm::dyn_cast<clang::TypedefType>(cur.getTypePtr())) {
        std::string name = t->getDecl()->getName().str();
        if (standard.count(name)) return name;
      }
      clang::QualType next = cur.getSingleStepDesugaredType(ctx);
      if (next == cur) return "";
      cur = next;
    }
  }

  /* [q] as written: each part is read through its sugar, so the parts of
     a pointer, an array or a function keep the typedefs they were written
     with, and only a leaf is read canonical. */
  void type(clang::QualType q) {
    std::string standard = standard_name(q);
    const clang::Type *t = q.getCanonicalType().getTypePtr();
    if (t->isVoidType()) return word("V");
    if (t->isBooleanType()) return word("B");
    if (t->isEnumeralType()) {
      word("O");
      return str(q.getCanonicalType().getUnqualifiedType().getAsString());
    }
    if (t->isIntegerType()) {
      word("I");
      word(t->isSignedIntegerType() ? "s" : "u");
      num(ctx.getTypeSize(q.getCanonicalType()));
      num(ctx.getIntWidth(q.getCanonicalType()));
      str(q.getCanonicalType().getUnqualifiedType().getAsString());
      return str(standard);
    }
    if (t->isRealFloatingType()) {
      const llvm::fltSemantics &sem = ctx.getFloatTypeSemantics(q.getCanonicalType());
      bool ieee = &sem == &llvm::APFloat::IEEEsingle() || &sem == &llvm::APFloat::IEEEdouble();
      word("F");
      num(ctx.getTypeSize(q.getCanonicalType()));
      word(ieee ? "1" : "0");
      return str(q.getCanonicalType().getUnqualifiedType().getAsString());
    }
    if (const clang::PointerType *p = q->getAs<clang::PointerType>()) {
      clang::QualType pointee = p->getPointeeType();
      word("P");
      word(pointee.isConstQualified() ? "1" : "0");
      return type(pointee);
    }
    if (const clang::RecordType *r = t->getAs<clang::RecordType>()) {
      const clang::RecordDecl *d = r->getDecl();
      records.insert(llvm::cast<clang::RecordDecl>(d->getCanonicalDecl()));
      word("R");
      word(d->isUnion() ? "u" : "s");
      return str(record_name(d));
    }
    if (const clang::ConstantArrayType *a = ctx.getAsConstantArrayType(q)) {
      word("A");
      num(a->getSize().getZExtValue());
      return type(a->getElementType());
    }
    if (const clang::FunctionProtoType *f = q->getAs<clang::FunctionProtoType>()) {
      word("N");
      word(f->isVariadic() ? "1" : "0");
      num(f->getNumParams());
      for (clang::QualType p : f->getParamTypes()) type(p);
      return type(f->getReturnType());
    }
    if (const clang::FunctionNoProtoType *f = q->getAs<clang::FunctionNoProtoType>()) {
      word("K");
      return type(f->getReturnType());
    }
    word("O");
    str(q.getCanonicalType().getUnqualifiedType().getAsString());
  }

  /* Every struct a written type reached, laid out as the target lays it
     out: its kind, whether the main file declares it, whether it is
     complete, its size and alignment in bits, and each field's name, type,
     offset in bits and bit-field width (-1 for none). A field's own struct
     is written in turn. */
  void layouts(const clang::SourceManager &sm) {
    std::set<const clang::RecordDecl *> done;
    while (true) {
      const clang::RecordDecl *next = nullptr;
      for (const clang::RecordDecl *d : records)
        if (!done.count(d)) { next = d; break; }
      if (!next) break;
      done.insert(next);
      const clang::RecordDecl *def = next->getDefinition();
      bool in_main = false;
      for (const clang::TagDecl *r : next->redecls())
        if (sm.isInMainFile(sm.getExpansionLoc(r->getLocation()))) in_main = true;
      word("rec");
      str(record_name(next));
      word(next->isUnion() ? "u" : "s");
      word(in_main ? "1" : "0");
      if (!def || def->isInvalidDecl()) {
        word("0");
        continue;
      }
      word("1");
      const clang::ASTRecordLayout &layout = ctx.getASTRecordLayout(def);
      num(ctx.toBits(layout.getSize()));
      num(ctx.toBits(layout.getAlignment()));
      std::vector<const clang::FieldDecl *> fields(def->field_begin(), def->field_end());
      num(fields.size());
      for (const clang::FieldDecl *f : fields) {
        str(f->getName().str());
        type(f->getType());
        num(layout.getFieldOffset(f->getFieldIndex()));
        word(f->isBitField() ? std::to_string(f->getBitWidthValue(ctx)) : "-1");
      }
    }
  }

private:
  clang::ASTContext &ctx;
};

/* Every function, variable and typedef whose expansion location is in the
   main file: the interface header compiled alone (docs/design/ffi.md F6). */
class Interface : public clang::ASTConsumer {
public:
  explicit Interface(std::string &out) : out(out) {}

  void HandleTranslationUnit(clang::ASTContext &ctx) override {
    const clang::SourceManager &sm = ctx.getSourceManager();
    Writer w(ctx);
    /* A function or variable declared more than once is written once, at
       its first declaration, with its most recent one's type: clang gives
       that one the composite of them all, so `int f(); int f(int);` is a
       prototype. */
    std::set<const clang::Decl *> written;
    for (clang::Decl *d : ctx.getTranslationUnitDecl()->decls()) {
      if (!sm.isInMainFile(sm.getExpansionLoc(d->getLocation()))) continue;
      if (llvm::isa<clang::FunctionDecl, clang::VarDecl>(d)) {
        if (!written.insert(d->getCanonicalDecl()).second) continue;
        d = d->getMostRecentDecl();
      }
      if (auto *f = llvm::dyn_cast<clang::FunctionDecl>(d)) {
        w.word("fun");
        w.str(f->getName().str());
        w.word(f->hasExternalFormalLinkage() ? "1" : "0");
        w.type(f->getType());
      } else if (auto *v = llvm::dyn_cast<clang::VarDecl>(d)) {
        w.word("var");
        w.str(v->getName().str());
        w.word(v->hasExternalFormalLinkage() ? "1" : "0");
        w.word(v->getTLSKind() != clang::VarDecl::TLS_None ? "1" : "0");
        w.type(v->getType());
      } else if (auto *t = llvm::dyn_cast<clang::TypedefNameDecl>(d)) {
        w.word("typedef");
        w.str(t->getName().str());
        w.type(t->getUnderlyingType());
      } else if (auto *r = llvm::dyn_cast<clang::RecordDecl>(d)) {
        if (!Writer::record_name(r).empty()) w.records.insert(llvm::cast<clang::RecordDecl>(r->getCanonicalDecl()));
      }
    }
    w.layouts(sm);
    out = w.out;
  }

private:
  std::string &out;
};

class InterfaceAction : public clang::ASTFrontendAction {
public:
  explicit InterfaceAction(std::string &out) : out(out) {}

protected:
  std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance &, llvm::StringRef) override {
    return std::make_unique<Interface>(out);
  }

private:
  std::string &out;
};

} // namespace

/* The module the command line's one source compiles to, as bitcode. */
extern "C" value zane_clang_compile(value args) {
  CAMLparam1(args);
  std::vector<std::string> owned = strings_of(args);
  std::string bitcode;
  Run r = run(owned, [&](clang::CompilerInstance &ci) {
    llvm::LLVMContext context;
    clang::EmitLLVMOnlyAction action(&context);
    if (!ci.ExecuteAction(action)) return false;
    std::unique_ptr<llvm::Module> module = action.takeModule();
    if (!module) return false;
    llvm::raw_string_ostream os(bitcode);
    llvm::WriteBitcodeToFile(*module, os);
    os.flush();
    return true;
  });
  r.output = bitcode;
  CAMLreturn(to_value(r));
}

/* The command line's one source preprocessed, with its line markers. */
extern "C" value zane_clang_preprocess(value args) {
  CAMLparam1(args);
  std::vector<std::string> owned = strings_of(args);
  std::string text;
  Run r = run(owned, [&](clang::CompilerInstance &ci) {
    Preprocess action(text);
    return ci.ExecuteAction(action);
  });
  r.output = text;
  CAMLreturn(to_value(r));
}

/* The linked clang, as `clang --version` names it. */
extern "C" value zane_clang_version(value unit) {
  CAMLparam1(unit);
  CAMLreturn(caml_copy_string(clang::getClangFullVersion().c_str()));
}

/* [triple] as LLVM normalizes it, and its architecture, operating system
   and environment, the parts that name an ABI. */
extern "C" value zane_triple_parts(value triple) {
  CAMLparam1(triple);
  CAMLlocal1(result);
  std::string normal = llvm::Triple::normalize(String_val(triple));
  llvm::Triple t(normal);
  result = caml_alloc_tuple(4);
  Store_field(result, 0, caml_copy_string(normal.c_str()));
  Store_field(result, 1, caml_copy_string(std::string(llvm::Triple::getArchTypeName(t.getArch())).c_str()));
  Store_field(result, 2, caml_copy_string(std::string(llvm::Triple::getOSTypeName(t.getOS())).c_str()));
  Store_field(result, 3, caml_copy_string(std::string(llvm::Triple::getEnvironmentTypeName(t.getEnvironment())).c_str()));
  CAMLreturn(result);
}

/* The triple of the machine the compiler runs on. */
extern "C" value zane_host_triple(value unit) {
  CAMLparam1(unit);
  CAMLreturn(caml_copy_string(llvm::sys::getDefaultTargetTriple().c_str()));
}

/* What the command line's one source, an interface header, declares, as
   the text [Interface] writes. */
extern "C" value zane_clang_interface(value args) {
  CAMLparam1(args);
  std::vector<std::string> owned = strings_of(args);
  std::string text;
  Run r = run(owned, [&](clang::CompilerInstance &ci) {
    InterfaceAction action(text);
    return ci.ExecuteAction(action);
  });
  r.output = text;
  CAMLreturn(to_value(r));
}
