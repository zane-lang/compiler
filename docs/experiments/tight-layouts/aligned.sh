#!/bin/bash
# Step 12 on a runner, through the Shell workflow: the layout shapes and
# the realistic programs under default, niche and aligned, both without
# unswitching.
#
#   command: docs/experiments/tight-layouts/aligned.sh
#
# The ZANE_PACK and ZANE_UNSWITCH switches this script sets were removed in
# 2baf718 (PR 353); the compiler no longer reads them, so every mode builds
# the same program. To reproduce, fetch the PR 353 branch (git fetch origin
# pull/353/head) and check out 506bb97, the last commit that reads them
# (0b88f63 removed them), and set ZANE_TIGHT_LAYOUTS_HISTORICAL=1. To compare
# layouts on current main, build two compilers and use wall14.py.
if [ "${ZANE_TIGHT_LAYOUTS_HISTORICAL:-}" != 1 ]; then
  echo "error: ZANE_PACK/ZANE_UNSWITCH no longer exist; see the header of $0." >&2
  echo "Set ZANE_TIGHT_LAYOUTS_HISTORICAL=1 on 506bb97 to run." >&2
  exit 1
fi
set -euo pipefail
uname -a
sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 "model name" /proc/cpuinfo 2>/dev/null || true
PY=$(command -v python3 || command -v python)
just build >/dev/null 2>&1
D=docs/experiments/tight-layouts
"$PY" "$D/measure.py" 10000000 10 7 default ZANE_PACK=niche,ZANE_UNSWITCH=0 ZANE_PACK=aligned,ZANE_UNSWITCH=0
for i in 1 2; do
  MODES=default,niche-unswitch,aligned-unswitch "$PY" "$D/programs.py" 15 'particles*100' 'tokens*50' 'entities*50' 'paths*10'
done
