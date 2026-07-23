if [[ -f "$ROOT/machine-config.txt" ]]; then
	# machine-config.txt uses shell-compatible KEY=VALUE assignments.
	# shellcheck source=/dev/null
	. "$ROOT/machine-config.txt"
fi

for name in \
	AMBIGUITY_MEMORY_MB \
	AMBIGUITY_MAX_FRONTIER_RATIO \
	AMBIGUITY_JOBS \
	AMBIGUITY_MENHIR; do
	if [[ -z "${!name:-}" ]]; then
		echo "ambiguity: $name must be set in machine-config.txt or the environment" >&2
		exit 2
	fi
done

export AMBIGUITY_MEMORY_MB
export AMBIGUITY_MAX_FRONTIER_RATIO
export AMBIGUITY_JOBS
export AMBIGUITY_MENHIR
