#!/bin/sh
# The flags that build and link LLD into the compiler (lld_stubs.cpp), as a
# dune S-expression: `cxx` for the compile, `libs` for the link. LLD's
# headers and static libraries sit beside the `ld.lld` on the path, in the
# devbox profile; LLVM's own come from `$LLVM_CONFIG`.
set -eu
prefix=$(dirname "$(dirname "$(command -v ld.lld)")")
llvm_config=${LLVM_CONFIG:-llvm-config}
case "$1" in
cxx) printf '(-std=c++17 -fno-exceptions -I%s/include -I%s)\n' "$prefix" "$("$llvm_config" --includedir)" ;;
libs) printf '(-L%s/lib -llldCOFF -llldELF -llldMachO -llldMinGW -llldCommon -L%s -lLLVM -lstdc++)\n' "$prefix" "$("$llvm_config" --libdir)" ;;
esac
