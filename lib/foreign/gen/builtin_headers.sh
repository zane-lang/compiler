#!/bin/sh
# The linked clang's own builtin headers (<stddef.h>, <stdint.h>, the
# intrinsics), as an OCaml list of each file's name and text, from the
# resource directory of the clang beside the `ld.lld` on the path. They are
# written into the cache and named with `-resource-dir`, so the C compiler
# that is asked for the target's headers never supplies its own
# (docs/design/ffi.md F1). Only the top level is taken: the subdirectories
# wrap other languages' headers (CUDA, OpenMP, C++).
set -eu
prefix=$(dirname "$(dirname "$(command -v ld.lld)")")
dir=$(ls -d "$prefix"/lib/clang/*/include | head -n 1)
echo "let files = ["
for f in "$dir"/*.h "$dir"/module.modulemap; do
  [ -f "$f" ] || continue
  printf '  ("%s", {zane_header|' "$(basename "$f")"
  cat "$f"
  printf '|zane_header});\n'
done
echo "]"
