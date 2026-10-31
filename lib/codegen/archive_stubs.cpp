/* A static library written from its members (docs/design/ffi.md F4, F9):
   an `archive` row's library once its members are renamed, written by
   LLVM's archive writer in the kind the target's linker reads, with a
   symbol table, and nothing in it that differs between builds of the same
   members. */

#include "llvm/Object/Archive.h"
#include "llvm/Object/ArchiveWriter.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <string>
#include <vector>

extern "C" {
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
}

/* [members], each its name and its bytes, as a library of [kind]: 0 for
   GNU's, which ELF linkers read, 1 for Darwin's, 2 for COFF's. Gives
   [Ok bytes] or [Error message]. */
extern "C" value zane_write_archive(value kind, value members) {
  CAMLparam2(kind, members);
  CAMLlocal2(result, text);
  std::vector<std::string> names, contents;
  for (value l = members; l != Val_emptylist; l = Field(l, 1)) {
    value member = Field(l, 0);
    names.emplace_back(String_val(Field(member, 0)), caml_string_length(Field(member, 0)));
    contents.emplace_back(String_val(Field(member, 1)), caml_string_length(Field(member, 1)));
  }
  std::string written, failure;
  {
    std::vector<llvm::NewArchiveMember> news;
    for (size_t i = 0; i < names.size(); ++i)
      news.emplace_back(llvm::MemoryBufferRef(contents[i], names[i]));
    llvm::object::Archive::Kind k;
    switch (Int_val(kind)) {
    case 1: k = llvm::object::Archive::K_DARWIN; break;
    case 2: k = llvm::object::Archive::K_COFF; break;
    default: k = llvm::object::Archive::K_GNU; break;
    }
    llvm::Expected<std::unique_ptr<llvm::MemoryBuffer>> buffer =
        llvm::writeArchiveToBuffer(news, llvm::SymtabWritingMode::NormalSymtab, k, true, false);
    if (buffer)
      written = (*buffer)->getBuffer().str();
    else {
      llvm::raw_string_ostream out(failure);
      out << buffer.takeError();
    }
  }
  if (failure.empty()) {
    text = caml_alloc_initialized_string(written.size(), written.data());
    result = caml_alloc(1, 0);
  } else {
    text = caml_alloc_initialized_string(failure.size(), failure.data());
    result = caml_alloc(1, 1);
  }
  Store_field(result, 0, text);
  CAMLreturn(result);
}
