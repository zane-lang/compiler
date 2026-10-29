/* Clang's front end linked into the compiler, of the compiler's own LLVM
   (docs/design/ffi.md F1), so a package's C is compiled in this process
   and its IR read by the same LLVM that reads the Zane code's.

   Each entry takes a command line as clang's driver reads one, its first
   word the driver's name. The linked driver turns it into a
   [CompilerInvocation] for the target the line names, so every front-end
   option is one this clang made itself. What an entry gives back is plain
   data: bitcode, preprocessed text, and the errors the front end reported,
   each with the file, line and column it points at. */

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

#include <memory>
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
