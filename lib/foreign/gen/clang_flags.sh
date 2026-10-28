#!/bin/sh
# The flags that build and link clang's front end into the compiler
# (clang_stubs.cpp), as a dune S-expression: `cxx` for the compile, `libs`
# for the link. Clang's headers and libraries sit beside the `ld.lld` on the
# path, in the devbox profile, as LLD's do (lib/codegen/gen/lld_flags.sh);
# LLVM's own come from `$LLVM_CONFIG`.
set -eu
prefix=$(dirname "$(dirname "$(command -v ld.lld)")")
llvm_config=${LLVM_CONFIG:-llvm-config}
case "$1" in
cxx) printf '(-std=c++17 -fno-exceptions -fno-rtti -I%s/include -I%s)\n' "$prefix" "$("$llvm_config" --includedir)" ;;
libs) printf '(-L%s/lib -lclang-cpp -L%s -lLLVM -lstdc++)\n' "$prefix" "$("$llvm_config" --libdir)" ;;
esac
