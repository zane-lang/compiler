grammar_python := env_var_or_default("GRAMMAR_PYTHON", "python3")

default:
	just -l

rebuild: check-grammar-generation
	dune clean
	dune build

watch:
	dune build --watch

# Every compiler, grammar and generator suite. CI runs the slower ones separately, so that a change which
# cannot affect the grammar or the ambiguity tools does not wait on them.
test: test-compiler test-grammar test-ambiguity-tools test-grammar-generation

# grammar/ owns the concrete syntax and lexicon. Generated compiler files are
# committed so direct dune builds and the proof tools keep their existing paths.
generate-grammar: _require-menhir
	{{grammar_python}} -m tools.grammar

check-grammar-generation: _require-menhir
	{{grammar_python}} -m tools.grammar --check

test-grammar-generation: check-grammar-generation
	{{grammar_python}} -m unittest tests.highlighting.generator_test tests.highlighting.conflicts_test -v

# Install tests/highlighting/requirements.txt and the pinned Tree-sitter CLI
# (npm ci --prefix editors/tree-sitter-zane) first; Typst and Neovim consumer
# tests run when those executables are present.
test-highlighting: test-grammar-generation
	#!/usr/bin/env bash
	set -euo pipefail
	# The CLI npm installs locally comes first, so the pinned version is the one used.
	export PATH="{{justfile_directory()}}/editors/tree-sitter-zane/node_modules/.bin:$PATH"
	command -v tree-sitter >/dev/null || { echo "tree-sitter not found; npm ci --prefix editors/tree-sitter-zane" >&2; exit 1; }
	{{grammar_python}} -c 'import tree_sitter'
	dune build tests/highlighting/parser_check.exe
	{{grammar_python}} -m unittest tests.highlighting.backend_test -v

# The compiler itself: the golden expectations under tests/ and parser
# acceptance.
#
# `dune runtest` carries the expectations in tests/parser/golden/ and
# tests/semantics/golden/, which the Python suites cannot cover: those ask
# whether a file parses and what shape it parsed to, and neither question reads
# a position or looks at the desugared or typed tree. A moved span is a diff
# there and nothing anywhere else, and so is a rewrite that stopped happening.
# Promote an intended move with `just promote`.
test-compiler: _require-menhir
	dune build bin/zanec/zanec.exe
	dune runtest tests/parser tests/semantics tests/codegen tests/runtime tests/objects
	python3 -m unittest tests.parser.syntax_test -v

# The test programs built for Windows and run under Wine, as CI runs them on
# Windows itself (docs/design/platforms.md). Needs `zig` and `wine64`; set
# RUNNER to run them some other way.
test-windows:
	dev/bin/windows-programs _build/windows-programs
	RUNNER="${RUNNER:-wine64}" dev/bin/check-programs _build/windows-programs

# The grammar's ambiguity regressions: token sequences with a fixed number of
# derivations, and the tree each unambiguous one groups to. A few seconds per
# case, since every check expands the grammar afresh, so this is the slow suite.
# Also the conflict census, the ledger docs/ambiguity/proof-obligations.md keeps.
test-grammar: _require-menhir
	dune build tools/ambiguity/engine/ambiguity_search.exe tools/inspect/parser_shape.exe
	dune runtest tests/grammar
	python3 -m unittest tests.grammar.ambiguity_test -v

# The ambiguity tools' own tests: the search engine on small grammars, the
# search CLI and its profiles, and the visible-stack proof's checker. They say
# whether the tools are right, not whether the grammar is.
test-ambiguity-tools: _require-menhir
	dune build tools/ambiguity/engine/ambiguity_search.exe
	python3 -m unittest discover -s tests/ambiguity -p '*_test.py' -t . -v

# The machine-checked unambiguity theorems (docs/ambiguity/verification-roadmap.md):
# the Lean checker in formal/ proves the parse relation parser.mly defines
# unambiguous, then proves the GLR parser's relation unambiguous and maps it
# onto the source grammar. Needs Lean (elan) besides Menhir; about ten minutes.
verify-grammar: _require-menhir
	#!/usr/bin/env bash
	set -euo pipefail
	command -v lake >/dev/null || { echo "lake not found on PATH; install Lean with elan" >&2; exit 1; }
	(cd formal && lake build zane-ambiguity-check)
	dir=$(mktemp -d)
	trap 'rm -rf "$dir"' EXIT
	cp lib/cst/parser.mly "$dir/"
	(cd "$dir" && menhir --GLR --dump parser.mly >/dev/null 2>"$dir/menhir.log") || { cat "$dir/menhir.log" >&2; exit 1; }
	formal/.lake/build/bin/zane-ambiguity-check prove-source lib/cst/parser.mly
	formal/.lake/build/bin/zane-ambiguity-check prove-glr lib/cst/parser.mly "$dir/parser.automaton"

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

# Dump Menhir's LR automaton or its conflict explanations -- the obligation
# ledger docs/ambiguity/README.md refers to. Expanded exactly as the ambiguity tools
# expand it, so a state number cited by a search report selects the state that
# produced it; running menhir on the unexpanded grammar renumbers everything.
#
#   just explain --state 27
#   just explain --conflicts
#   just explain --search list_verb_type_suffix_
explain *ARGS:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the devbox shell first" >&2; exit 1; }
	python3 -m tools.ambiguity.explain_automaton {{ARGS}}
