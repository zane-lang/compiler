#!/usr/bin/env bash
# Guest instructions (Valgrind's lackey, whole process) of one package
# built two ways, optimized: today's runtime, and with
# ZANE_SUBJECT_REGIONS=1. Callgrind stops on the runtime's commit-on-touch
# fault in a spawned thread, so lackey counts instead. Valgrind runs one
# thread at a time, so this counts the work each build does, not what
# contention costs. Run inside `devbox run`.
# Usage: measure.sh OUT_DIR PACKAGE_DIR [ARGS...]
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=$1; pkg=$2; shift 2
zanec=$root/_build/default/bin/zanec/zanec.exe
name=$(basename "$pkg")
build() { env "$@" "$zanec" --build "$out/$name.$tag.exe" --optimize --package "$pkg" > "$out/$name.$tag.build" 2>&1; }
for tag in base subject; do
	case $tag in
		base) build ZANE_SUBJECT_REGIONS=0 ;;
		subject) build ZANE_SUBJECT_REGIONS=1 ;;
	esac || { echo "$tag: build failed"; cat "$out/$name.$tag.build"; exit 1; }
	valgrind --tool=lackey --basic-counts=yes "$out/$name.$tag.exe" "$@" > "$out/$name.$tag.out" 2> "$out/$name.$tag.vg"
	ir=$(grep -a "guest instrs:" "$out/$name.$tag.vg" | awk '{print $NF}')
	echo "$tag: $ir instructions; output $(sort "$out/$name.$tag.out" | uniq -c | tr '\n' ' ')"
done
