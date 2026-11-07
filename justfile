# Project actions. `just` lists them by group; tests/README.md says what each
# suite covers. Run in the pixi environment (`pixi shell`, or `pixi run just ...`),
# which provides the toolchain (README.md, "Setup").

set shell := ["bash", "-euo", "pipefail", "-c"]
set script-interpreter := ["bash", "-euo", "pipefail"]

# The Python that runs every Python suite and tool. CI and grammar/README.md
# point GRAMMAR_PYTHON at a virtualenv holding the grammar requirements.
python := env("GRAMMAR_PYTHON", "python3")

[private]
default:
	@just --list --unsorted

# --- Building ---------------------------------------------------------------

[group('build')]
[doc('Build everything')]
build:
	dune build

[group('build')]
[doc('Delete the build directory')]
clean:
	dune clean

[group('build')]
[doc('Build everything from clean, and check the generated grammar files are current')]
rebuild: clean build check-grammar-generation

[group('build')]
[doc('Rebuild on every change')]
watch:
	dune build --watch

[group('build')]
[doc('Accept the golden files the last test run moved; read the diff first')]
promote:
	dune promote

# --- Grammar ----------------------------------------------------------------

[group('grammar')]
[doc('Regenerate the compiler and editor files grammar/ is the source of')]
generate-grammar: _require-menhir
	{{python}} -m tools.grammar

[group('grammar')]
[doc('Fail if a generated grammar file differs from what grammar/ generates')]
check-grammar-generation: _require-menhir
	{{python}} -m tools.grammar --check

[group('grammar')]
[doc('Dump the expanded LR automaton: --state N, --conflicts, --search NAME')]
explain *ARGS: _require-menhir
	{{python}} -m tools.ambiguity.explain_automaton {{ARGS}}

[group('grammar')]
[doc('Prove the grammar unambiguous with the Lean checker in formal/ (needs elan, ~10 min)')]
[script]
verify-grammar: _require-menhir
	command -v lake >/dev/null || { echo "lake not found on PATH; install Lean with elan" >&2; exit 1; }
	(cd formal && lake build zane-ambiguity-check)
	dir=$(mktemp -d)
	trap 'rm -rf "$dir"' EXIT
	cp lib/cst/parser.mly "$dir/"
	(cd "$dir" && menhir --GLR --dump parser.mly >/dev/null 2>"$dir/menhir.log") || { cat "$dir/menhir.log" >&2; exit 1; }
	formal/.lake/build/bin/zane-ambiguity-check prove-source lib/cst/parser.mly
	formal/.lake/build/bin/zane-ambiguity-check prove-glr lib/cst/parser.mly "$dir/parser.automaton"

# --- Tests ------------------------------------------------------------------

[group('test')]
[doc('Every compiler, grammar and generator suite')]
test: test-compiler test-grammar test-ambiguity-tools test-grammar-generation

[group('test')]
[doc('The compiler: golden files, parser acceptance, tiers and memory probes')]
test-compiler: _require-menhir _zanec
	dune runtest tests/parser tests/semantics tests/codegen tests/ffi tests/runtime tests/objects tests/unit tests/nesting
	{{python}} -m unittest tests.parser.syntax_test -v
	{{python}} -m unittest tests.tiers.tiers_test -v
	tests/memory-probes/run --check
	{{python}} tests/memory-probes/reclaim.py --check

[group('test')]
[doc('The grammar: ambiguity regressions and the conflict census (slow)')]
test-grammar: _require-menhir
	dune build tools/ambiguity/engine/ambiguity_search.exe tools/inspect/parser_shape.exe
	dune runtest tests/grammar
	{{python}} -m unittest tests.grammar.ambiguity_test tests.grammar.type_arguments_test -v

[group('test')]
[doc("The ambiguity tools' own tests: engine, CLI and proof checker")]
test-ambiguity-tools: _require-menhir
	dune build tools/ambiguity/engine/ambiguity_search.exe
	{{python}} -m unittest discover -s tests/ambiguity -p '*_test.py' -t . -v

[group('test')]
[doc('The grammar generator: generated files current, and its unit tests')]
test-grammar-generation: check-grammar-generation
	{{python}} -m unittest tests.highlighting.generator_test tests.highlighting.conflicts_test -v

# Neovim's consumer test also needs the zane-nvim plugin, cloned into .zane-nvim
# (or named by ZANE_NVIM_PLUGIN); it is skipped without one.
[group('test')]
[doc('The editor grammars against the compiler parser (needs the pinned tree-sitter)')]
[script]
test-highlighting: test-grammar-generation
	# The CLI npm installs locally comes first, so the pinned version is the one used.
	export PATH="{{justfile_directory()}}/editors/tree-sitter-zane/node_modules/.bin:$PATH"
	command -v tree-sitter >/dev/null || { echo "tree-sitter not found; npm ci --prefix editors/tree-sitter-zane" >&2; exit 1; }
	{{python}} -c 'import tree_sitter'
	dune build tests/highlighting/parser_check.exe tools/inspect/span_dump.exe
	{{python}} -m unittest tests.highlighting.backend_test -v

[group('test')]
[doc('The test programs built for Windows and run under Wine (set RUNNER to change)')]
test-windows:
	dev/bin/cross-programs x86_64-windows-gnu _build/windows-programs
	RUNNER="${RUNNER:-wine64}" dev/bin/check-programs _build/windows-programs

[group('test')]
[doc("Each perf program's cycles under Valgrind, against main's (Linux only)")]
test-perf: _zanec
	EVENT_NAME=local .github/scripts/perf

[group('test')]
[doc("Write tests/perf/golden/ from this build's output")]
promote-perf: _zanec
	tests/perf/run --promote

# --- Checks -----------------------------------------------------------------

[group('check')]
[doc('Every hand-written source file under 2,000 lines')]
check-file-sizes:
	.github/scripts/file-sizes

[group('check')]
[doc('Hand-written OCaml under lib/, bin/ and tools/ nested at most five deep')]
check-nesting:
	dune build tools/nesting/nesting.exe
	git ls-files -z -- 'lib/*.ml' 'bin/*.ml' 'tools/*.ml' | xargs -0 _build/default/tools/nesting/nesting.exe

# --- Benchmarks -------------------------------------------------------------

[group('bench')]
[doc('How aggregates cross calls, measured; --quick only checks it works')]
bench-abi *ARGS:
	dev/bin/abi-bench {{ARGS}}

# --- Helpers ----------------------------------------------------------------

_zanec:
	dune build bin/zanec/zanec.exe

# The engine-backed tests skip themselves without Menhir, so a missing one
# fails here instead of reporting a green run that skipped them.
_require-menhir:
	@command -v menhir >/dev/null || { echo "menhir not found on PATH; enter the pixi environment first (pixi shell)" >&2; exit 1; }
