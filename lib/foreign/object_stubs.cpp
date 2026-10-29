/* Object files read and made for a package's C that does not reach the
   package's module (docs/design/ffi.md F4, F9): an `archive` row's static
   library, read member by member, and a C source whose module holds
   assembly, optimized and emitted as an object of its own. What an entry
   gives back is plain data: bytes, names, and why it failed. */

#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Object/Archive.h"
#include "llvm/Object/MachO.h"
#include "llvm/Object/ObjectFile.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/Triple.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

extern "C" {
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

namespace {

std::string message_of(llvm::Error e) {
  std::string s;
  llvm::raw_string_ostream out(s);
  out << e;
  return out.str();
}

/* [items] as an OCaml list, each made by [make]. */
template <typename T, typename F> value list_of(const std::vector<T> &items, F make) {
  CAMLparam0();
  CAMLlocal3(list, cell, item);
  list = Val_emptylist;
  for (auto it = items.rbegin(); it != items.rend(); ++it) {
    item = make(*it);
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, item);
    Store_field(cell, 1, list);
    list = cell;
  }
  CAMLreturn(list);
}

value pair_of(const std::pair<std::string, std::string> &p) {
  CAMLparam0();
  CAMLlocal3(pair, first, second);
  first = caml_alloc_initialized_string(p.first.size(), p.first.data());
  second = caml_alloc_initialized_string(p.second.size(), p.second.data());
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, first);
  Store_field(pair, 1, second);
  CAMLreturn(pair);
}

value string_of(const std::string &s) { return caml_alloc_initialized_string(s.size(), s.data()); }

/* [Ok v] or [Error message], as OCaml's [result]. */
value ok(value v) {
  CAMLparam1(v);
  CAMLlocal1(r);
  r = caml_alloc(1, 0);
  Store_field(r, 0, v);
  CAMLreturn(r);
}

value error(const std::string &message) {
  CAMLparam0();
  CAMLlocal2(r, m);
  m = string_of(message);
  r = caml_alloc(1, 1);
  Store_field(r, 0, m);
  CAMLreturn(r);
}

} // namespace

/* [bitcode]'s module optimized as clang's `-O2` would, then emitted as an
   object for [triple] and [cpu], position-independent, as the code
   generator an unoptimized build emits its C with makes one
   (docs/design/ffi.md F14). Its assembly is assembled with it. */
extern "C" value zane_object_emit(value bitcode, value triple, value cpu) {
  CAMLparam3(bitcode, triple, cpu);
  CAMLlocal1(result);
  std::string object, failure;
  {
    llvm::InitializeAllTargetInfos();
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllAsmPrinters();
    llvm::LLVMContext context;
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bitcode), caml_string_length(bitcode)), "c");
    llvm::Expected<std::unique_ptr<llvm::Module>> parsed = llvm::parseBitcodeFile(buffer, context);
    std::string name = String_val(triple), lookup;
    const llvm::Target *target = parsed ? llvm::TargetRegistry::lookupTarget(name, lookup) : nullptr;
    if (!parsed)
      failure = message_of(parsed.takeError());
    else if (!target)
      failure = lookup;
    else {
      std::unique_ptr<llvm::Module> m = std::move(*parsed);
      std::unique_ptr<llvm::TargetMachine> tm(target->createTargetMachine(
          name, String_val(cpu), "", llvm::TargetOptions(), llvm::Reloc::PIC_, std::nullopt, llvm::CodeGenOptLevel::Default));
      m->setTargetTriple(name);
      m->setDataLayout(tm->createDataLayout());
      llvm::LoopAnalysisManager lam;
      llvm::FunctionAnalysisManager fam;
      llvm::CGSCCAnalysisManager cam;
      llvm::ModuleAnalysisManager mam;
      llvm::PassBuilder pb(tm.get());
      pb.registerModuleAnalyses(mam);
      pb.registerCGSCCAnalyses(cam);
      pb.registerFunctionAnalyses(fam);
      pb.registerLoopAnalyses(lam);
      pb.crossRegisterProxies(lam, fam, cam, mam);
      pb.buildPerModuleDefaultPipeline(llvm::OptimizationLevel::O2).run(*m, mam);
      llvm::SmallVector<char, 0> bytes;
      llvm::raw_svector_ostream out(bytes);
      llvm::legacy::PassManager emit;
      if (tm->addPassesToEmitFile(emit, out, nullptr, llvm::CodeGenFileType::ObjectFile))
        failure = "the target cannot emit an object file";
      else {
        emit.run(*m);
        object.assign(bytes.data(), bytes.size());
      }
    }
  }
  if (failure.empty())
    result = ok(string_of(object));
  else
    result = error(failure);
  CAMLreturn(result);
}

/* What the object [bytes] holds, as far as renaming it needs: the C names
   of the global symbols it defines, each with whether it is data, and the
   names of its sections. A Mach-O name is read without the `_` every C
   name takes there, and one without it, which no C name can be, is left
   out; a Mach-O section is named `SEGMENT,section`, as C's `section`
   attribute names one. */
extern "C" value zane_object_read(value bytes) {
  CAMLparam1(bytes);
  CAMLlocal5(result, tuple, defined, sections, arch);
  std::vector<std::pair<std::string, std::string>> names, placed;
  std::string failure, architecture;
  {
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bytes), caml_string_length(bytes)), "object");
    llvm::Expected<std::unique_ptr<llvm::object::ObjectFile>> file = llvm::object::ObjectFile::createObjectFile(buffer);
    if (!file)
      failure = message_of(file.takeError());
    else {
      llvm::object::ObjectFile &o = **file;
      bool macho = o.isMachO();
      architecture = llvm::Triple::getArchTypeName(o.getArch()).str();
      for (const llvm::object::SymbolRef &s : o.symbols()) {
        using F = llvm::object::BasicSymbolRef;
        llvm::Expected<uint32_t> flags = s.getFlags();
        if (!flags) {
          llvm::consumeError(flags.takeError());
          continue;
        }
        if ((*flags & F::SF_Undefined) || (*flags & F::SF_FormatSpecific)) continue;
        llvm::Expected<llvm::StringRef> name = s.getName();
        if (!name) {
          llvm::consumeError(name.takeError());
          continue;
        }
        llvm::Expected<llvm::object::SymbolRef::Type> type = s.getType();
        if (!type) {
          llvm::consumeError(type.takeError());
          continue;
        }
        std::string n = name->str();
        if (macho) {
          if (n.empty() || n[0] != '_') continue;
          n = n.substr(1);
        }
        bool data = *type == llvm::object::SymbolRef::ST_Data;
        // A local symbol matters only as private state: a variable of its
        // own, which an interface header the glue compiles may define too.
        if (!(*flags & F::SF_Global)) {
          if (data && !n.empty()) names.emplace_back(n, "local");
          continue;
        }
        names.emplace_back(n, data ? "data" : "code");
      }
      for (const llvm::object::SectionRef &s : o.sections()) {
        llvm::Expected<llvm::StringRef> name = s.getName();
        if (!name) {
          llvm::consumeError(name.takeError());
          continue;
        }
        std::string n = name->str();
        if (auto *m = llvm::dyn_cast<llvm::object::MachOObjectFile>(&o))
          n = m->getSectionFinalSegmentName(s.getRawDataRefImpl()).str() + "," + n;
        placed.emplace_back(n, "");
      }
    }
  }
  if (!failure.empty()) {
    result = error(failure);
    CAMLreturn(result);
  }
  defined = list_of(names, pair_of);
  sections = list_of(placed, [](const std::pair<std::string, std::string> &p) { return string_of(p.first); });
  arch = string_of(architecture);
  tuple = caml_alloc_tuple(3);
  Store_field(tuple, 0, defined);
  Store_field(tuple, 1, sections);
  Store_field(tuple, 2, arch);
  result = ok(tuple);
  CAMLreturn(result);
}

/* The architecture [triple] names, spelled as [zane_object_read] spells an
   object's. */
extern "C" value zane_triple_arch(value triple) {
  CAMLparam1(triple);
  CAMLlocal1(result);
  std::string t(String_val(triple), caml_string_length(triple));
  result = string_of(llvm::Triple::getArchTypeName(llvm::Triple(llvm::Triple::normalize(t)).getArch()).str());
  CAMLreturn(result);
}

/* The members of the static library [bytes], each its name and its bytes,
   in the order the library holds them. A thin library, whose members are
   files beside it, is refused, since it does not move with its package. */
extern "C" value zane_archive_members(value bytes) {
  CAMLparam1(bytes);
  CAMLlocal1(result);
  std::vector<std::pair<std::string, std::string>> members;
  std::string failure;
  {
    llvm::MemoryBufferRef buffer(llvm::StringRef(String_val(bytes), caml_string_length(bytes)), "archive");
    llvm::Expected<std::unique_ptr<llvm::object::Archive>> archive = llvm::object::Archive::create(buffer);
    if (!archive)
      failure = message_of(archive.takeError());
    else if ((*archive)->isThin())
      failure = "it is a thin archive, whose members are files of their own";
    else {
      llvm::Error e = llvm::Error::success();
      for (const llvm::object::Archive::Child &c : (*archive)->children(e)) {
        llvm::Expected<llvm::StringRef> name = c.getName();
        if (!name) {
          failure = message_of(name.takeError());
          break;
        }
        llvm::Expected<llvm::StringRef> data = c.getBuffer();
        if (!data) {
          failure = message_of(data.takeError());
          break;
        }
        members.emplace_back(name->str(), data->str());
      }
      if (e) failure = message_of(std::move(e));
    }
  }
  if (failure.empty())
    result = ok(list_of(members, pair_of));
  else
    result = error(failure);
  CAMLreturn(result);
}
