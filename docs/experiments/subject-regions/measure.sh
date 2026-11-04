#!/usr/bin/env bash
# Instructions (Valgrind's `Ir`, whole process) of one package built three
# ways, optimized: today's runtime, with ZANE_SUBJECT_REGIONS=1, and the
# control (no locks, no subject regions). Valgrind runs the threads one at
# a time, so a lock is never contended here: this counts the work each
# build does, not what contention costs. Run inside `devbox run`.
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
	valgrind --tool=callgrind --callgrind-out-file="$out/$name.$tag.cg" "$out/$name.$tag.exe" "$@" > "$out/$name.$tag.out" 2> "$out/$name.$tag.vg"
	ir=$(grep -a "Collected" "$out/$name.$tag.vg" | awk '{print $4}')
	echo "$tag: $ir instructions; output $(sort "$out/$name.$tag.out" | uniq -c | tr '\n' ' ')"
done
