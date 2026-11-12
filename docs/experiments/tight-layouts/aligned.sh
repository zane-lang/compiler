#!/bin/bash
# Step 12 on a runner, through the Shell workflow: the layout shapes and
# the realistic programs under default, niche and aligned, both without
# unswitching.
#
#   command: docs/experiments/tight-layouts/aligned.sh
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
