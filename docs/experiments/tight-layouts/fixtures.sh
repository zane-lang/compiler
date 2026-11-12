#!/bin/bash
# Every codegen fixture built plain and with the given switches, unoptimized
# and with --optimize, each run under ZANE_CHECK=1: prints the fixtures whose
# output or exit code differ, or which a build refuses. Run from the
# repository root after `pixi run just build`:
#
#   pixi run -- docs/experiments/tight-layouts/fixtures.sh ZANE_PACK=structs
W=${WORK:-/tmp/zane-tight-fixtures}; mkdir -p "$W"; Z=$PWD/_build/default/bin/zanec/zanec.exe
same=0; differ=0
for d in tests/codegen/fixtures/*/; do
  n=$(basename "$d"); args=()
  if [ -f "$d/$n" ]; then while IFS= read -r line; do args+=("$line"); done < "$d/$n"; fi
  for opt in "" --optimize; do
    tag="$n${opt:+ (optimized)}"
    if ! "$Z" --build "$W/$n.old" $opt --package "$d" >/dev/null 2>&1; then continue; fi
    if ! env "$@" "$Z" --build "$W/$n.new" $opt --package "$d" >/dev/null 2>"$W/$n.err"; then
      echo "$tag: refused: $(grep -m1 . "$W/$n.err")"; differ=$((differ+1)); continue
    fi
    o=$(cd "$d" && ZANE_CHECK=1 timeout 60 "$W/$n.old" "${args[@]}" 2>&1; echo "exit $?")
    p=$(cd "$d" && ZANE_CHECK=1 timeout 60 "$W/$n.new" "${args[@]}" 2>&1; echo "exit $?")
    if [ "$o" = "$p" ]; then same=$((same+1)); else echo "$tag: DIFFERENT"; differ=$((differ+1)); fi
  done
done
echo "same: $same, different or refused: $differ"
