/* LLD linked into the compiler, so a build links without starting the C
   compiler and a linker as programs of their own: each of those loads
   LLVM's shared library again, which costs more than the link itself.
   [zane_lld_link] runs the linker its arguments name first (`ld.lld`,
   `ld64.lld`, `lld-link`, or `ld.lld -m i386pep` for MinGW) and gives back
   its exit code, whether it can run again in this process, and what it
   wrote. */

#include "lld/Common/Driver.h"
#include "llvm/Support/CrashRecoveryContext.h"
#include "llvm/Support/raw_ostream.h"

#include <string>
#include <vector>

extern "C" {
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

LLD_HAS_DRIVER(elf)
LLD_HAS_DRIVER(coff)
LLD_HAS_DRIVER(mingw)
LLD_HAS_DRIVER(macho)

extern "C" value zane_lld_link(value args) {
  CAMLparam1(args);
  CAMLlocal2(result, message);
  std::vector<std::string> owned;
  for (mlsize_t i = 0; i < Wosize_val(args); i++) owned.emplace_back(String_val(Field(args, i)));
  std::vector<const char *> argv;
  for (const std::string &arg : owned) argv.push_back(arg.c_str());
  std::string text;
  llvm::raw_string_ostream out(text);
  /* Without crash recovery a fatal error in LLD, such as a corrupt input
     file, exits the whole process; with it, the link fails and returns.
     Its signal handlers are installed only while LLD runs. */
  llvm::CrashRecoveryContext::Enable();
  lld::Result linked = lld::lldMain(argv, out, out,
                                    {{lld::Gnu, &lld::elf::link},
                                     {lld::WinLink, &lld::coff::link},
                                     {lld::MinGW, &lld::mingw::link},
                                     {lld::Darwin, &lld::macho::link}});
  llvm::CrashRecoveryContext::Disable();
  out.flush();
  message = caml_copy_string(text.c_str());
  result = caml_alloc_tuple(3);
  Store_field(result, 0, Val_int(linked.retCode));
  Store_field(result, 1, Val_bool(linked.canRunAgain));
  Store_field(result, 2, message);
  CAMLreturn(result);
}
