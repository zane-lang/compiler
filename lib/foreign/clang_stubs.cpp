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
#include "clang/AST/Attr.h"
#include "clang/AST/ASTContext.h"
#include "clang/AST/Decl.h"
#include "clang/AST/RecordLayout.h"
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/SourceManager.h"
#include "clang/Basic/TargetOptions.h"
#include "clang/Basic/Version.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/Frontend/MultiplexConsumer.h"
#include "clang/Frontend/Utils.h"
#include "clang/Lex/Preprocessor.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/GlobalAlias.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/MCSubtargetInfo.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/CrashRecoveryContext.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Host.h"
#include "llvm/TargetParser/Triple.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/Support/VirtualFileSystem.h"

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
    /* The engine holds the options by reference, so they live as long as
       this run does. */
    clang::DiagnosticOptions diagnostic_options;
    auto diagnostics =
        clang::CompilerInstance::createDiagnostics(*llvm::vfs::getRealFileSystem(), diagnostic_options, problems, false);
    clang::CreateInvocationOptions options;
    options.Diags = diagnostics;
    std::shared_ptr<clang::CompilerInvocation> invocation = clang::createInvocation(argv, options);
    if (!invocation || !problems->problems.empty()) return;
    /* Without carets the instance prints no "N errors generated" of its
       own: every problem reaches OCaml through [problems] alone. */
    invocation->getDiagnosticOpts().ShowCarets = false;
    clang::CompilerInstance ci(invocation);
    ci.createDiagnostics(*llvm::vfs::getRealFileSystem(), problems, false);
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
     struct a typedef `Foo` names are two records. An anonymous one with
     neither is named for where it is declared: the record and field that
     hold it, `struct Outer.a` (the field's position, `struct Outer.#0`,
     when the field has no name), or else its file, line and column. */
  static std::string record_name(const clang::RecordDecl *d) {
    if (d->getIdentifier()) return (d->isUnion() ? "union " : "struct ") + d->getName().str();
    if (const clang::TypedefNameDecl *t = d->getTypedefNameForAnonDecl()) return t->getName().str();
    if (const auto *outer = llvm::dyn_cast<clang::RecordDecl>(d->getDeclContext())) {
      unsigned i = 0;
      for (const clang::FieldDecl *f : outer->fields()) {
        const clang::RecordDecl *held = f->getType()->getBaseElementTypeUnsafe()->getAsRecordDecl();
        if (held && held->getCanonicalDecl() == d->getCanonicalDecl())
          return record_name(outer) + "." + (f->getName().empty() ? "#" + std::to_string(i) : f->getName().str());
        i++;
      }
    }
    const clang::SourceManager &sm = d->getASTContext().getSourceManager();
    clang::PresumedLoc at = sm.getPresumedLoc(sm.getExpansionLoc(d->getLocation()));
    if (at.isInvalid()) return "";
    return std::string(d->isUnion() ? "union" : "struct") + " at " + llvm::sys::path::filename(at.getFilename()).str() + ":" +
           std::to_string(at.getLine()) + ":" + std::to_string(at.getColumn());
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

  /* A function's parameter types and result type as the header spells
     them, for the glue to name them by (docs/design/ffi.md F8): how many
     parameters, then each, then the result. */
  void spellings(clang::QualType q) {
    const clang::PrintingPolicy &policy = ctx.getPrintingPolicy();
    if (const clang::FunctionProtoType *f = q->getAs<clang::FunctionProtoType>()) {
      num(f->getNumParams());
      for (clang::QualType p : f->getParamTypes()) str(p.getAsString(policy));
      return str(f->getReturnType().getAsString(policy));
    }
    num(0);
    if (const clang::FunctionType *f = q->getAs<clang::FunctionType>()) return str(f->getReturnType().getAsString(policy));
    str("");
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
      std::vector<const clang::FieldDecl *> fields;
      for (auto it = def->field_begin(); it != def->field_end(); ++it)
        fields.push_back(*it);
      num(fields.size());
      for (const clang::FieldDecl *f : fields) {
        str(f->getName().str());
        type(f->getType());
        num(layout.getFieldOffset(f->getFieldIndex()));
        word(f->isBitField() ? std::to_string(f->getBitWidthValue()) : "-1");
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
        w.spellings(f->getType());
      } else if (auto *v = llvm::dyn_cast<clang::VarDecl>(d)) {
        w.word("var");
        w.str(v->getName().str());
        w.word(v->hasExternalFormalLinkage() ? "1" : "0");
        w.word(v->getTLSKind() != clang::VarDecl::TLS_None ? "1" : "0");
        w.word(v->getType().isConstant(v->getASTContext()) ? "1" : "0");
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

/* A declaration `ZANE_ALIAS` marks (zane_ffi.h): its name, the name of
   the function or variable it is another name for, and whether the name has
   external linkage, which a `static` declaration's has not. */
struct Marked_alias {
  std::string name, target;
  bool external;
};

/* What the source's `ZANE_ALIAS` marks name, each refused with an error
   where it is written unless it is a declaration of a function or variable,
   not its definition, whose target is defined in the source with external
   linkage and is of the same kind, and neither has an `__asm__` label. Each declaration of a name counts once,
   since a redeclaration inherits the mark. */
class Alias_marks : public clang::ASTConsumer {
public:
  explicit Alias_marks(std::vector<Marked_alias> &marks) : marks(marks) {}

  bool HandleTopLevelDecl(clang::DeclGroupRef group) override {
    for (clang::Decl *d : group) {
      auto *named = llvm::dyn_cast<clang::DeclaratorDecl>(d);
      if (!named || !named->getIdentifier()) continue;
      for (const auto *a : named->specific_attrs<clang::AnnotateAttr>()) {
        llvm::StringRef text = a->getAnnotation();
        if (text.consume_front("zane.alias=") && seen.insert(named->getName().str()).second)
          found.push_back({ named, text.str(), a->getLocation() });
      }
    }
    return true;
  }

  void HandleTranslationUnit(clang::ASTContext &context) override {
    clang::DiagnosticsEngine &diagnostics = context.getDiagnostics();
    unsigned error = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "%0");
    for (const Found &f : found) {
      auto refuse = [&](const std::string &why) { diagnostics.Report(f.at, error) << why; };
      bool function = llvm::isa<clang::FunctionDecl>(f.decl);
      if (!function && !llvm::isa<clang::VarDecl>(f.decl)) {
        refuse("ZANE_ALIAS marks a declaration of a function or a variable");
        continue;
      }
      bool defined = function ? llvm::cast<clang::FunctionDecl>(f.decl)->isDefined()
                              : llvm::cast<clang::VarDecl>(f.decl)->hasDefinition() != clang::VarDecl::DeclarationOnly;
      if (defined) {
        refuse("`" + f.decl->getName().str() + "`, which ZANE_ALIAS makes another name, is defined here too");
        continue;
      }
      const clang::NamedDecl *target = nullptr;
      for (const clang::NamedDecl *t :
           context.getTranslationUnitDecl()->lookup(&context.Idents.get(f.target)))
        if (function ? llvm::isa<clang::FunctionDecl>(t) : llvm::isa<clang::VarDecl>(t)) target = t;
      bool target_defined =
          target && (function ? llvm::cast<clang::FunctionDecl>(target)->isDefined()
                              : llvm::cast<clang::VarDecl>(target)->hasDefinition() != clang::VarDecl::DeclarationOnly);
      if (!target_defined) {
        refuse("ZANE_ALIAS names `" + f.target + "`, which this source does not define as a " +
               (function ? "function" : "variable"));
        continue;
      }
      if (!target->isExternallyVisible()) {
        refuse("ZANE_ALIAS names `" + f.target + "`, which has internal linkage");
        continue;
      }
      /* An `__asm__` label names a symbol other than the C name, which is
         the name the alias is made under and its target found by. */
      if (f.decl->hasAttr<clang::AsmLabelAttr>()) {
        refuse("`" + f.decl->getName().str() + "`, which ZANE_ALIAS makes another name, has an `__asm__` label");
        continue;
      }
      if (target->hasAttr<clang::AsmLabelAttr>()) {
        refuse("ZANE_ALIAS names `" + f.target + "`, which has an `__asm__` label");
        continue;
      }
      marks.push_back({ f.decl->getName().str(), f.target, f.decl->isExternallyVisible() });
    }
  }

private:
  struct Found {
    const clang::DeclaratorDecl *decl;
    std::string target;
    clang::SourceLocation at;
  };
  std::vector<Marked_alias> &marks;
  std::vector<Found> found;
  std::set<std::string> seen;
};

/* The module a source compiles to, as `EmitLLVMOnlyAction` makes it, with
   the source's `ZANE_ALIAS` marks read before it. */
class Compile_with_aliases : public clang::EmitLLVMOnlyAction {
public:
  Compile_with_aliases(llvm::LLVMContext *context, std::vector<Marked_alias> &marks)
      : clang::EmitLLVMOnlyAction(context), marks(marks) {}

protected:
  std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance &ci, llvm::StringRef file) override {
    /* The marks are read first: code generation frees the AST once it has
       emitted the module (`-clear-ast-before-backend`, which the driver
       sets), so a consumer after it would read freed declarations. */
    std::vector<std::unique_ptr<clang::ASTConsumer>> both;
    both.push_back(std::make_unique<Alias_marks>(marks));
    both.push_back(clang::EmitLLVMOnlyAction::CreateASTConsumer(ci, file));
    return std::make_unique<clang::MultiplexConsumer>(std::move(both));
  }

private:
  std::vector<Marked_alias> &marks;
};

/* Each mark made an alias in [module], as the `alias` attribute makes one
   on the targets that have it: the name's declaration, where the source
   uses it, gives its uses to the alias, and the alias has the declaration's
   linkage, internal for a `static` one, so two sources can each have one
   of the same name. Mach-O's C has no `alias`, and an
   alias in LLVM is one on every target. */
void make_aliases(llvm::Module &module, const std::vector<Marked_alias> &marks) {
  for (const Marked_alias &m : marks) {
    /* A target the source defines but clang emits no body for, as C99's
       `inline` alone, is left out, and the link names what is missing. */
    llvm::GlobalValue *target = module.getNamedValue(m.target);
    if (!target || target->isDeclaration()) continue;
    auto *alias = llvm::GlobalAlias::create(target->getValueType(), target->getAddressSpace(),
                                            m.external ? llvm::GlobalValue::ExternalLinkage
                                                       : llvm::GlobalValue::InternalLinkage,
                                            "", target, &module);
    /* A thread-local variable's alias is thread-local too, as its uses,
       through `llvm.threadlocal.address`, require. */
    llvm::GlobalValue *declared = module.getNamedValue(m.name);
    alias->setThreadLocalMode(declared ? declared->getThreadLocalMode() : target->getThreadLocalMode());
    if (declared) {
      declared->replaceAllUsesWith(alias);
      alias->takeName(declared);
      declared->eraseFromParent();
    } else {
      alias->setName(m.name);
    }
  }
}

} // namespace

/* The module the command line's one source compiles to, as bitcode, with
   an alias for each declaration `ZANE_ALIAS` marks. */
/* [module]'s functions stamped with the processor the compile is for,
   [target]'s, made the program's code: they lose that processor, as the
   runtime's bodies do (lib/codegen/runtime_bodies.ml), and are compiled
   for the program's target. LLVM inlines a body only into a caller whose
   processor has every feature the body's has, and the program's functions
   name none, so the target machine's defaults stand for theirs; clang's
   list for AArch64 names features those defaults do not (`+v8a`), which
   would keep every C body out of the program. The compile is for the
   program's own processor (Compile.processor_flag), so a body that loses
   it is emitted for the processor it was compiled for; one whose features
   that processor lacks, as a package's `-mavx2` adds, keeps them, and so
   does a function given a processor of its own
   (`__attribute__((target))`). */
static void drop_default_processor(llvm::Module &module, const clang::TargetOptions &target) {
  std::vector<std::string> features = target.Features;
  llvm::sort(features);
  std::string joined = llvm::join(features, ",");
  llvm::InitializeAllTargetInfos();
  llvm::InitializeAllTargetMCs();
  std::string lookup;
  const llvm::Target *machine = llvm::TargetRegistry::lookupTarget(module.getTargetTriple(), lookup);
  if (!machine) return;
  std::unique_ptr<llvm::MCSubtargetInfo> processor(
      machine->createMCSubtargetInfo(module.getTargetTriple().str(), target.CPU, ""));
  if (!processor || !processor->checkFeatures(joined)) return;
  for (llvm::Function &f : module) {
    llvm::Attribute cpu = f.getFnAttribute("target-cpu");
    llvm::Attribute has = f.getFnAttribute("target-features");
    std::string own_cpu = cpu.isValid() ? cpu.getValueAsString().str() : "";
    std::string own_features = has.isValid() ? has.getValueAsString().str() : "";
    if (own_cpu != target.CPU || own_features != joined) continue;
    f.removeFnAttr("target-cpu");
    f.removeFnAttr("target-features");
    llvm::Attribute tune = f.getFnAttribute("tune-cpu");
    if (tune.isValid() && tune.getValueAsString() == target.TuneCPU) f.removeFnAttr("tune-cpu");
  }
}

extern "C" value zane_clang_compile(value args) {
  CAMLparam1(args);
  std::vector<std::string> owned = strings_of(args);
  std::string bitcode;
  Run r = run(owned, [&](clang::CompilerInstance &ci) {
    llvm::LLVMContext context;
    std::vector<Marked_alias> marks;
    Compile_with_aliases action(&context, marks);
    if (!ci.ExecuteAction(action) || ci.getDiagnostics().hasErrorOccurred()) return false;
    std::unique_ptr<llvm::Module> module = action.takeModule();
    if (!module) return false;
    make_aliases(*module, marks);
    drop_default_processor(*module, ci.getTargetOpts());
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

/* The global variables [bitcode]'s module defines for other modules to
   see, a weak definition among them, and the aliases it gives them: what
   a foreign variable may name (spec ffi.md §5.1). */
extern "C" value zane_bitcode_defined_variables(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal2(list, cell);
  std::vector<std::string> names;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalVariable &g : (*module)->globals())
        if (!g.isDeclaration() && !g.hasLocalLinkage() && !g.hasAvailableExternallyLinkage())
          names.push_back(g.getName().str());
      for (const llvm::GlobalAlias &a : (*module)->aliases())
        if (!a.hasLocalLinkage() && llvm::isa_and_nonnull<llvm::GlobalVariable>(a.getAliaseeObject()) &&
            !a.getAliaseeObject()->isDeclaration())
          names.push_back(a.getName().str());
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = names.rbegin(); it != names.rend(); ++it) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, caml_copy_string(it->c_str()));
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

/* [g]'s C name, as an object's reader names it: a name an `__asm__`
   label gave, which LLVM writes with a leading \1 and the target's global
   prefix spelled out, is the label. */
static std::string c_name(const llvm::GlobalValue &g) {
  char prefix = g.getParent()->getDataLayout().getGlobalPrefix();
  llvm::StringRef name = g.getName();
  if (name.consume_front("\1") && prefix) name.consume_front(llvm::StringRef(&prefix, 1));
  return name.str();
}

/* The private state [bitcode]'s module defines: each named variable local
   to it that the program can write, by its C name. */
extern "C" value zane_bitcode_private_state(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal2(list, cell);
  std::vector<std::string> names;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalVariable &g : (*module)->globals())
        if (g.hasLocalLinkage() && !g.isConstant() && g.hasName() && !g.getName().starts_with("llvm."))
          names.push_back(c_name(g));
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = names.rbegin(); it != names.rend(); ++it) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, caml_copy_string(it->c_str()));
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

/* Whether [v] reaches the program as an address: a use other than a
   call of it, or an entry of the constructor and destructor lists, which
   only run it. */
static bool address_seen(const llvm::Value *v) {
  for (const llvm::User *u : v->users()) {
    if (auto *call = llvm::dyn_cast<llvm::CallBase>(u)) {
      if (call->getCalledOperand() != v) return true;
    } else if (auto *g = llvm::dyn_cast<llvm::GlobalVariable>(u)) {
      if (g->getName() != "llvm.global_ctors" && g->getName() != "llvm.global_dtors") return true;
    } else if (llvm::isa<llvm::ConstantAggregate>(u) || llvm::isa<llvm::ConstantExpr>(u)) {
      if (address_seen(u)) return true;
    } else
      return true;
  }
  return false;
}

/* The private constants and functions [bitcode]'s module defines whose
   addresses the program can see: each named constant local to it whose
   address LLVM may not merge with another's, as a variable's is, and each
   function local to it whose address is taken, so a copy of either is told
   apart from it. Each is its C name. */
extern "C" value zane_bitcode_private_identities(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal2(list, cell);
  std::vector<std::string> names;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalVariable &g : (*module)->globals())
        if (g.hasLocalLinkage() && g.isConstant() && !g.hasGlobalUnnamedAddr() && g.hasName() &&
            !g.getName().starts_with("llvm."))
          names.push_back(c_name(g));
      for (const llvm::Function &f : **module)
        if (f.hasLocalLinkage() && f.hasName() && address_seen(&f)) names.push_back(c_name(f));
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = names.rbegin(); it != names.rend(); ++it) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, caml_copy_string(it->c_str()));
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

/* Every global object [bitcode]'s module places in an explicit section,
   with its section's name: the linker-set check reads them
   (docs/design/ffi.md F9). */
extern "C" value zane_bitcode_sections(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal3(list, cell, pair);
  std::vector<std::pair<std::string, std::string>> placed;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalObject &g : (*module)->global_objects())
        if (g.hasSection()) placed.emplace_back(g.getName().str(), g.getSection().str());
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = placed.rbegin(); it != placed.rend(); ++it) {
    pair = caml_alloc_tuple(2);
    Store_field(pair, 0, caml_copy_string(it->first.c_str()));
    Store_field(pair, 1, caml_copy_string(it->second.c_str()));
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, pair);
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

/* Whether [bitcode]'s module holds assembly: file-scope `__asm__`, kept as
   the module's `module asm` text, or an `__asm__` statement, kept as an
   inline-assembly call. Either can name a symbol no global value stands
   for, which renaming the module's globals would miss
   (docs/design/ffi.md F9). */
extern "C" value zane_bitcode_has_assembly(value bitcode) {
  CAMLparam1(bitcode);
  bool found = false;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      found = !(*module)->getModuleInlineAsm().empty();
      for (const llvm::Function &f : **module)
        for (const llvm::BasicBlock &b : f)
          for (const llvm::Instruction &i : b)
            if (const auto *call = llvm::dyn_cast<llvm::CallBase>(&i))
              if (call->isInlineAsm()) found = true;
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  CAMLreturn(Val_bool(found));
}

/* What [bitcode]'s module defines visible to other modules, functions,
   variables, aliases and indirect functions, and whether it runs a
   constructor or destructor, local or external: the check of a header an archive
   compiled too reads them (docs/design/ffi.md F9). Each is its C name, as
   an object's reader names it: a name an `__asm__` label gave, which LLVM
   writes with a leading \1 and the target's global prefix spelled out, is
   the label. */
extern "C" value zane_bitcode_definitions(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal3(list, cell, pair);
  std::vector<std::string> names;
  bool runs = false;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalValue &g : (*module)->global_values())
        if (!g.isDeclarationForLinker() && !g.hasLocalLinkage() && !g.hasAppendingLinkage() &&
            !g.getName().starts_with("llvm."))
          names.push_back(c_name(g));
      for (const char *name : {"llvm.global_ctors", "llvm.global_dtors"})
        if (const llvm::GlobalVariable *list = (*module)->getNamedGlobal(name))
          if (const auto *entries = llvm::dyn_cast_or_null<llvm::ConstantArray>(
                  list->hasInitializer() ? list->getInitializer() : nullptr))
            for (const llvm::Use &entry : entries->operands())
              if (const auto *s = llvm::dyn_cast<llvm::ConstantStruct>(entry.get()))
                if (llvm::isa<llvm::Function>(s->getOperand(1)->stripPointerCasts())) runs = true;
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = names.rbegin(); it != names.rend(); ++it) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, caml_copy_string(it->c_str()));
    Store_field(cell, 1, list);
    list = cell;
  }
  pair = caml_alloc(2, 0);
  Store_field(pair, 0, list);
  Store_field(pair, 1, Val_bool(runs));
  CAMLreturn(pair);
}

/* What [bitcode]'s module uses from other modules without defining it,
   functions and variables, each its C name as [zane_bitcode_definitions]
   gives one: what a header's constructor may reach in an archive that
   compiled the header too, as a variable the archive defines and its
   folded copy of the constructor set (docs/design/ffi.md F9). */
extern "C" value zane_bitcode_declarations(value bitcode) {
  CAMLparam1(bitcode);
  CAMLlocal2(list, cell);
  std::vector<std::string> names;
  {
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> module = llvm::parseBitcodeFile(buffer, context);
    if (module) {
      for (const llvm::GlobalValue &g : (*module)->global_values())
        if (g.isDeclaration() && !g.getName().starts_with("llvm.") && !g.use_empty()) names.push_back(c_name(g));
    } else {
      llvm::consumeError(module.takeError());
    }
  }
  list = Val_emptylist;
  for (auto it = names.rbegin(); it != names.rend(); ++it) {
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, caml_copy_string(it->c_str()));
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}
