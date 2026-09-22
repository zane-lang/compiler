default:
	just -l

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

syntax-experiment-test:
	python3 -m unittest test.syntax_experiment.experiment_test -v

# The parser suite: acceptance, grammar ambiguity, the prover's soundness
# corpus, the search CLI's own tests, and the sweep's process runner. The
# engine-backed tests skip themselves unless the executables and Menhir are
# present, so build them first and fail loudly on a missing Menhir rather than
# reporting a green run that silently skipped them.
#
# `dune runtest` carries the expectations in test/parser/golden/, which the
# Python suite cannot cover: those tests ask whether a file parses and what
# shape it parsed
# to, and neither question reads a position or looks at the desugared tree. A
# moved span is a diff there and nothing anywhere else, and so is a rewrite
# that stopped happening. Promote an intended move with `just promote`.
test:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }
	dune build tools/ambiguity/ambiguity_search.exe tools/parser/parser_shape.exe tools/parser/parser_accept.exe
	dune runtest
	python3 -m unittest \
		test.ambiguity.cli_test \
		test.ambiguity.precision_sweep_test \
		test.ambiguity.validity_test \
		test.ambiguity.prover.soundness_test \
		test.ambiguity.prover.refinement_test \
		test.ambiguity.prover.diagnostics_test \
		test.ambiguity.prover.verdict_test \
		test.ambiguity.prover.survey_test \
		test.parser.ambiguity_test \
		test.parser.syntax_test \
		-v

# Accept the span expectation as it currently stands, after reading the diff
# `just test` printed and satisfying yourself that each moved span still covers
# what its node stands for.
promote:
	dune promote

# Sweep the prover's abstraction level over a grammar to tell a bounded blind
# spot from an unbounded one. A bounded one keeps its shape and disappears once
# the window is wider than the widest competing reduction; an unbounded one
# holds its accepting-pair count flat at every level and never proves. Defaults
# to Zane's own grammar; pass a path or `--corpus NAME` for anything else.
#
# Levels cost roughly an order of magnitude each, so start narrow and widen.
sweep GRAMMAR="lib/cst/parser.mly" *ARGS:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }
	dune build tools/ambiguity/ambiguity_search.exe
	python3 tools/ambiguity/precision_sweep.py {{GRAMMAR}} {{ARGS}}

# Dump Menhir's LR automaton or its conflict explanations -- the obligation
# ledger docs/ambiguity.md refers to. Expanded exactly as the ambiguity tools
# expand it, so a state number cited by a proof report selects the state that
# produced it; running menhir on the unexpanded grammar renumbers everything.
#
#   just explain --state 27
#   just explain --conflicts
#   just explain --search list_verb_type_suffix_
explain *ARGS:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }
	python3 tools/ambiguity/explain_automaton.py {{ARGS}}
