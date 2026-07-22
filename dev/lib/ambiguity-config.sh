# Shared defaults for the ambiguity-tool executables.
AMBIGUITY_MEMORY_MB=512
AMBIGUITY_MAX_FRONTIER_RATIO=1.0
AMBIGUITY_JOBS=4
AMBIGUITY_MENHIR=menhir

if [[ -f "$ROOT/machine-config.txt" ]]; then
	# machine-config.txt uses shell-compatible KEY=VALUE assignments.
	# shellcheck source=/dev/null
	. "$ROOT/machine-config.txt"
fi
