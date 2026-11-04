#!/usr/bin/env bash
# Builds each named package with ThreadSanitizer (ZANE_TSAN=1, tsan-cc as
# the C compiler), with ZANE_SUBJECT_REGIONS set as in the environment, and
# runs it RUNS times checked and unchecked, counting TSan's reports.
# Usage (inside `devbox run`): tsan.sh OUT_DIR PACKAGE_DIR [ARG]...
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=$1; pkg=$2; shift 2
zanec=$root/_build/default/bin/zanec/zanec.exe
name=$(basename "$pkg")
exe=$out/$name.sr${ZANE_SUBJECT_REGIONS:-0}
ZANE_TSAN=1 ZANE_CC=$here/tsan-cc "$zanec" --build "$exe" --package "$pkg" > "$exe.build" 2>&1 || { echo "$name: build failed"; tail -3 "$exe.build"; exit 1; }
for k in 0 1; do
	races=0; bad=0
	for i in $(seq "${RUNS:-5}"); do
		TSAN_OPTIONS="halt_on_error=0 report_signal_unsafe=0" ZANE_CHECK=$k timeout 300 "$exe" "$@" > "$exe.$k.out" 2> "$exe.$k.err"
		code=$?
		r=$(grep -c 'WARNING: ThreadSanitizer' "$exe.$k.err")
		races=$((races + r))
		{ [ $code = 0 ] && ! grep -q '^no' "$exe.$k.out"; } || bad=$((bad + 1))
		[ "$r" -gt 0 ] && cp "$exe.$k.err" "$exe.$k.err.kept"
	done
	echo "$name subject-regions=${ZANE_SUBJECT_REGIONS:-0} check=$k: ${RUNS:-5} runs, $races TSan reports, $bad failed"
done
