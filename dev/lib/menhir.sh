# shellcheck shell=bash
# Sourced by the grammar-* commands; ROOT is set by the caller.
#
# They need only a Menhir, so they take the ambiguity tools' AMBIGUITY_MENHIR
# when one is configured and fall back to the one on PATH. The rest of the
# ambiguity configuration (memory, jobs, frontier ratio) is for searches they
# never run.

if [[ -z "${AMBIGUITY_MENHIR:-}" && -f "$ROOT/dev/machine-config.txt" ]]; then
	# shellcheck source=/dev/null
	. "$ROOT/dev/machine-config.txt"
fi

MENHIR="${AMBIGUITY_MENHIR:-menhir}"
