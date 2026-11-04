#!/usr/bin/env bash
# Builds each named codegen fixture, plain and optimized, runs it checked and unchecked, and compares with its golden,
# with the fixture's `flags`, `arguments` and `expected-status` as
# tests/codegen/README.md gives them.
# Usage (from inside `devbox run`): fixtures.sh OUT_DIR fixture...
set -u
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=$1; shift
zanec=$root/_build/default/bin/zanec/zanec.exe
status=0
lines() { [ -f "$1" ] && mapfile -t "$2" < "$1" || eval "$2=()"; }
for f in "$@"; do
	dir=$root/tests/codegen/fixtures/$f
	lines "$dir/flags" flags
	lines "$dir/arguments" args
	want=0
	[ -f "$dir/expected-status" ] && want=$(cat "$dir/expected-status")
	for o in "" "--optimize"; do
		exe=$out/$f$o.exe
		if ! "$zanec" --build "$exe" $o "${flags[@]}" --package "$dir" > "$out/$f$o.build" 2>&1; then
			echo "$f $o: BUILD FAILED"; tail -3 "$out/$f$o.build"; status=1; continue
		fi
		for chk in 0 1; do
			ZANE_CHECK=$chk "$exe" "${args[@]}" > "$out/$f$o.$chk.out" 2>&1
			code=$?
			if [ "$code" != "$want" ]; then
				echo "$f $o check=$chk: EXIT $code, expected $want"; status=1
			elif diff -q "$out/$f$o.$chk.out" "$root/tests/codegen/golden/$f.out" > /dev/null; then
				echo "$f $o check=$chk: same (exit $code)"
			else
				echo "$f $o check=$chk: DIFFERS (exit $code)"; diff "$out/$f$o.$chk.out" "$root/tests/codegen/golden/$f.out" | head -6; status=1
			fi
		done
	done
done
exit $status
