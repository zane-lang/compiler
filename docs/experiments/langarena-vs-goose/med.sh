#!/bin/sh
# med.sh N TEST BIN... : N interleaved runs pinned to CPU 2, median per binary.
# Runs $LANGARENA's run.js; a run that does not report OK gives no sample.
# With MED_RAW set, each sample is also written there as "ROUND POSITION BIN TIME".
N=$1; T=$2; shift 2
here=$(cd "$(dirname "$0")" && pwd)
root=${LANGARENA:?set LANGARENA to a LangArena checkout}
for r in $(seq "$N"); do
  i=0
  for b in "$@"; do
    i=$((i+1))
    t=$(taskset -c 2 "$b" "$root/run.js" "$T" | grep -E ': OK in [0-9.]+s' | grep -o 'in [0-9.]*s' | tr -d 'ins ')
    [ -n "$t" ] && echo "$r $i $b $t"
  done
  # The order rotates each round.
  first=$1; shift; set -- "$@" "$first"
done | tee "${MED_RAW:-/dev/null}" | python3 "$here/med.py"
