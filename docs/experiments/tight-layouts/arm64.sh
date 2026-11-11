#!/bin/bash
# The experiment on another machine, through the Shell workflow
# (.github/workflows/shell.yml) on an AArch64 runner:
#
#   runner: macos-latest, toolchain: true, timeout: 90,
#   command: docs/experiments/tight-layouts/arm64.sh
#
# Builds the compiler, checks that bench/niches prints the same in every
# mode, unoptimized and optimized, and runs measure.py over the modes.
set -euo pipefail
uname -a
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
just build
Z=$PWD/_build/default/bin/zanec/zanec.exe
W=${WORK:-$(mktemp -d)}
D=docs/experiments/tight-layouts
for mode in default ZANE_PACK=structs ZANE_PACK=all ZANE_PACK=niche; do
  for opt in "" --optimize; do
    if [ "$mode" = default ]; then e=(); else e=("$mode"); fi
    env ${e[@]+"${e[@]}"} "$Z" --build "$W/niches" $opt --package "$D/bench/niches"
    ZANE_CHECK=1 "$W/niches" > "$W/out"
    if [ ! -f "$W/expected" ]; then cp "$W/out" "$W/expected"; fi
    if cmp -s "$W/out" "$W/expected"; then echo "niches, $mode $opt: same"; else echo "niches, $mode $opt: DIFFERENT"; exit 1; fi
  done
done
python3 "$D/measure.py" 10000000 10 5 default ZANE_PACK=structs,ZANE_PACK_HINTS=0 ZANE_PACK=structs ZANE_PACK=all ZANE_PACK=niche
