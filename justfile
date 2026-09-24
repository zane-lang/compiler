default:
	just -l

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

# Every suite below. CI runs the three separately, so that a change which
# cannot affect the grammar or the ambiguity tools does not wait on them.
test: test-compiler test-grammar test-ambiguity-tools

# The compiler itself: the golden expectations under test/ and parser
# acceptance.
#
# `dune runtest` carries the expectations in test/parser/golden/ and
# test/semantics/golden/, which the Python suites cannot cover: those ask
# whether a file parses and what shape it parsed to, and neither question reads
# a position or looks at the desugared or typed tree. A moved span is a diff
# there and nothing anywhere else, and so is a rewrite that stopped happening.
# Promote an intended move with `just promote`.
test-compiler: _require-menhir
	dune build tools/parser/parser_accept.exe
	dune runtest
	python3 -m unittest test.parser.syntax_test -v

# The grammar's ambiguity regressions: token sequences with a fixed number of
# derivations, and the tree each unambiguous one groups to. A few seconds per
# case, since every check expands the grammar afresh, so this is the slow suite.
test-grammar: _require-menhir
	dune build tools/ambiguity/ambiguity_search.exe tools/parser/parser_shape.exe
	python3 -m unittest test.parser.ambiguity_test -v

# The ambiguity tools' own tests: the prover's soundness corpus, the search
# CLI, and the sweep's process runner. They say whether the tools are right,
# not whether the grammar is.
test-ambiguity-tools: _require-menhir
	dune build tools/ambiguity/ambiguity_search.exe
	python3 -m unittest \
		test.ambiguity.cli_test \
		test.ambiguity.precision_sweep_test \
		test.ambiguity.prover.soundness_test \
		test.ambiguity.prover.history_cegar_test \
		test.ambiguity.prover.refinement_test \
		test.ambiguity.prover.diagnostics_test \
		test.ambiguity.prover.verdict_test \
		test.ambiguity.prover.survey_test \
		-v

# The engine-backed tests skip themselves unless the executables and Menhir are
# present, so fail loudly on a missing Menhir rather than reporting a green run
# that silently skipped them. The leading underscore keeps it out of `just -l`.
_require-menhir:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }

# Accept the span expectation as it currently stands, after reading the diff
# `just test-compiler` printed and satisfying yourself that each moved span
# still covers what its node stands for.
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
