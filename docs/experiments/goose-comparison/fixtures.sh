#!/bin/bash
# Each codegen fixture whose optimized CGT the given switches change, built
# plain and with them, and run under ZANE_CHECK=1: prints whether the two
# give the same output and exit code, or the refusal. Run from the
# repository root inside its devbox, after `dune build`:
#
#   devbox run -- docs/experiments/goose-comparison/fixtures.sh \
#     ZANE_POOLED_VARIANTS=1 ZANE_PACKED_NODES=1
#
# With ALL=1 every fixture is built and run both ways, for a switch that
# changes the runtime too (ZANE_REF32).
W=${WORK:-/tmp/zane-goose-fixtures}; mkdir -p "$W"; Z=$PWD/_build/default/bin/zanec/zanec.exe
for d in tests/codegen/fixtures/*/; do
  n=$(basename "$d"); args=(); [ -f "$d/$n" ] && mapfile -t args < "$d/$n"
  a=$($Z --cgt --optimize --package "$d" 2>&1 | md5sum); b=$(env "$@" "$Z" --cgt --optimize --package "$d" 2>&1 | md5sum)
  [ "$a" = "$b" ] && [ -z "$ALL" ] && continue
  if ! env "$@" "$Z" --build "$W/$n.new" --package "$d" >/dev/null 2>"$W/$n.err"; then
    echo "$n: refused: $(grep -o 'pooled variants[^"]*' "$W/$n.err" | head -1)"; continue
  fi
  "$Z" --build "$W/$n.old" --package "$d" >/dev/null 2>&1
  o=$(ZANE_CHECK=1 "$W/$n.old" "${args[@]}" 2>&1; echo "exit $?"); p=$(ZANE_CHECK=1 "$W/$n.new" "${args[@]}" 2>&1; echo "exit $?")
  [ "$o" = "$p" ] && echo "$n: same output" || echo "$n: DIFFERENT"
done
