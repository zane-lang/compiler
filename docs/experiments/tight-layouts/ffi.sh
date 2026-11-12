#!/bin/bash
# Every FFI fixture built with the given switches, unoptimized and with
# --optimize, run under ZANE_CHECK=1 and compared with its golden output.
# Run from the repository root after `pixi run just build`:
#
#   pixi run -- docs/experiments/tight-layouts/ffi.sh ZANE_PACK=structs
W=${WORK:-/tmp/zane-tight-ffi}; mkdir -p "$W"; Z=$PWD/_build/default/bin/zanec/zanec.exe
cd tests/ffi || exit 1
grep -o -- '--build [A-Za-z]*\.exe --package.*)))' dune.inc | sed 's/)))$//' | while read -r _ exe rest; do
  n=${exe%.exe}; [ -f "golden/$n.out" ] || continue
  for opt in "" --optimize; do
    tag="$n${opt:+ (optimized)}"
    if ! env "$@" "$Z" --build "$W/$exe" $opt $rest >/dev/null 2>"$W/$n.err"; then
      echo "$tag: refused: $(grep -m1 . "$W/$n.err")"; continue
    fi
    if [ -n "$opt" ] && [ -f "golden/$n.optimized.out" ]; then want="golden/$n.optimized.out"; else want="golden/$n.out"; fi
    if ZANE_CHECK=1 timeout 60 "$W/$exe" >"$W/$n.out" 2>/dev/null && cmp -s "$W/$n.out" "$want"; then echo "$tag: same"; else echo "$tag: DIFFERENT"; fi
  done
done
