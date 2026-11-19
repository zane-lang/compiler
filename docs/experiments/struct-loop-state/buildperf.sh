#!/bin/sh
# Each tests/perf program, optimized, with each compiler checkout:
# MAIN, FS (#398) and SPLIT name checkouts with zanec built; into $OUT/perf.
HERE=$(cd "$(dirname "$0")" && pwd)
S=${OUT:-$HERE/out}; mkdir -p "$S/perf"
for c in main:$MAIN fs:$FS split:$SPLIT; do
  n=${c%%:*}; Z=${c#*:}/_build/default/bin/zanec/zanec.exe
  for d in $HERE/../../../tests/perf/*/; do
    p=$(basename $d); [ -f $d/main.zn ] || continue
    args="--package $p=$d"
    if [ -d $d/lib ]; then for l in $d/lib/*/; do args="$args --package $(basename $l)=$l"; done; fi
    $Z --build $S/perf/$p.$n --optimize $args > /dev/null 2>&1 || echo "FAILED $p $n"
  done
  echo "built $n"
done
