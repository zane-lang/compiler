#!/usr/bin/env bash
# Builds each named codegen fixture with ZANE_SUBJECT_REGIONS=1, plain and
# optimized, runs it checked and unchecked, and compares with its golden.
# Usage (from inside `devbox run`): fixtures.sh OUT_DIR fixture...
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=$1; shift
zanec=$root/_build/default/bin/zanec/zanec.exe
status=0
for f in "$@"; do
	for o in "" "--optimize"; do
		exe=$out/$f$o.exe
		if ! ZANE_SUBJECT_REGIONS=1 "$zanec" --build "$exe" $o --package "$root/tests/codegen/fixtures/$f" > "$out/$f$o.build" 2>&1; then
			echo "$f $o: BUILD FAILED"; tail -3 "$out/$f$o.build"; status=1; continue
		fi
		for chk in 0 1; do
			ZANE_CHECK=$chk "$exe" > "$out/$f$o.$chk.out" 2>&1
			code=$?
			if diff -q "$out/$f$o.$chk.out" "$root/tests/codegen/golden/$f.out" > /dev/null; then
				echo "$f $o check=$chk: same (exit $code)"
			else
				echo "$f $o check=$chk: DIFFERS (exit $code)"; diff "$out/$f$o.$chk.out" "$root/tests/codegen/golden/$f.out" | head -6; status=1
			fi
		done
	done
done
exit $status
