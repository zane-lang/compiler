#!/bin/bash
# The experiment on another machine, through the Shell workflow
# (.github/workflows/shell.yml), on any runner the toolchain solves for:
#
#   runner: ubuntu-latest | windows-latest | macos-15-intel | macos-latest,
#   toolchain: true, timeout: 120,
#   command: docs/experiments/tight-layouts/platform.sh
#
# Builds the compiler; checks that bench/niches prints the same in every
# mode, unoptimized and optimized; runs measure.py over the modes, the
# tests/perf programs by wall clock (programs.py, the realistic ones
# scaled up), and langbench's Zane programs against core (langbench.py).
#
# The ZANE_PACK and ZANE_UNSWITCH switches this script sets were removed in
# 2baf718 (PR 353); the compiler no longer reads them, so every mode builds
# the same program. To reproduce, check out 5c97994 (the last commit where
# they worked) and set ZANE_TIGHT_LAYOUTS_HISTORICAL=1. To compare layouts
# on current main, build two compilers and use wall14.py.
[ "${ZANE_TIGHT_LAYOUTS_HISTORICAL:-}" = 1 ] || { echo "error: The ZANE_PACK and ZANE_UNSWITCH switches this script sets were removed in 2baf718 (PR 353); the compiler no longer reads them, so every mode builds the same program. To reproduce, check out 5c97994 (the last commit where they worked) and set ZANE_TIGHT_LAYOUTS_HISTORICAL=1. To compare layouts on current main, build two compilers and use wall14.py." >&2; exit 1; }
set -euo pipefail
uname -a
sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 "model name" /proc/cpuinfo 2>/dev/null || true
PY=$(command -v python3 || command -v python)
just build
Z=$PWD/_build/default/bin/zanec/zanec.exe
W=${WORK:-$(mktemp -d)}
D=docs/experiments/tight-layouts
X=; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) X=.exe;; esac
for mode in default ZANE_PACK=niche; do
  for opt in "" --optimize; do
    if [ "$mode" = default ]; then e=(); else e=("$mode"); fi
    env ${e[@]+"${e[@]}"} "$Z" --build "$W/niches$X" $opt --package "$D/bench/niches"
    ZANE_CHECK=1 "$W/niches$X" | tr -d '\r' > "$W/out"
    if [ ! -f "$W/expected" ]; then cp "$W/out" "$W/expected"; fi
    if cmp -s "$W/out" "$W/expected"; then echo "niches, $mode $opt: same"; else echo "niches, $mode $opt: DIFFERENT"; exit 1; fi
  done
done
echo "== measure.py"
"$PY" "$D/measure.py" 10000000 10 5 default ZANE_UNSWITCH=1 ZANE_PACK=niche
echo "== programs.py"
"$PY" "$D/programs.py" 7 borrows copies depths division flips floats growth kept leaves removal repeats returns scopes stress texts trees 'particles*50' 'tokens*20' 'entities*20' 'paths*3'
echo "== langbench.py"
git clone -q --depth 1 https://github.com/zane-lang/spec "$W/spec"
git clone -q --depth 1 https://github.com/zane-lang/core "$W/core"
"$PY" "$D/langbench.py" "$W/spec/langbench" "$W/core" 5
