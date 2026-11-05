#!/bin/sh
# The flags that build and link LLD into the compiler (lld_stubs.cpp), as a
# dune S-expression: `cxx` for the compile, `libs` for the link. LLD's
# headers and static libraries sit beside the `ld.lld` on the path, in the
# devbox profile; LLVM's own, and the compression libraries LLD's archives
# call, come from `$LLVM_CONFIG`.
set -eu
prefix=$(dirname "$(dirname "$(command -v ld.lld)")")
llvm_config=${LLVM_CONFIG:-llvm-config}
case "$1" in
cxx) printf '(-std=c++17 -fno-exceptions -I%s/include -I%s)\n' "$prefix" "$("$llvm_config" --includedir)" ;;
libs)
	# LLD's archives are static and compress output sections by calling
	# zlib and zstd themselves, so those two are named here when LLVM was
	# built with them. A shared LLVM reports its system libraries only for
	# its static set, and the rest (libxml2, say) libLLVM carries itself.
	system_libs=
	for lib in $("$llvm_config" --link-static --system-libs 2>/dev/null || true); do
		case "$lib" in -lz | -lzstd) system_libs="$system_libs $lib" ;; esac
	done
	printf '(-L%s/lib -llldCOFF -llldELF -llldMachO -llldMinGW -llldCommon -L%s -lLLVM %s -lstdc++)\n' \
		"$prefix" "$("$llvm_config" --libdir)" "$system_libs" ;;
esac
