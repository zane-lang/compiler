default:
	just -l

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

syntax-experiment-test:
	python3 -m unittest tools.test_syntax_experiment -v

# The engine-backed tests skip themselves unless the executable and Menhir are
# both present, so build the engine first and fail loudly on a missing Menhir
# rather than reporting a green run that silently skipped them.
ambiguity-test:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }
	dune build tools/ambiguity_search.exe
	python3 -m unittest tools.test_ambiguity tools.test_parser_ambiguity -v
