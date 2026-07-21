grammarFile := "lib/cst/parser.mly"

default:
	just -l

run:
	dune exec bin/compiler/main.exe

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

stats:
	menhir {{ grammarFile }} --no-code-generation --infer

conflicts:
	menhir {{ grammarFile }} --random-sentence-concrete package --random-seed 1 --random-sentence-length 16

# Find a short complete ambiguity within a bounded, parallel GLR search.
ambiguities max_tokens="20" timeout="60" max_frontiers="500000" jobs="4" max_witnesses="20" menhir="menhir":
	dune exec tools/ambiguity_search.exe -- {{ grammarFile }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }} --jobs {{ jobs }} --max-witnesses {{ max_witnesses }}

# Slower reference implementation, useful for cross-checking the OCaml search.
ambiguities-python max_tokens="20" timeout="60" max_frontiers="500000" menhir="menhir":
	python3 tools/find_ambiguity.py {{ grammarFile }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }}

# Compare all controlled syntax variants and write Markdown/JSON reports.
syntax-experiments max_tokens="12" timeout="15" max_frontiers="150000" max_witnesses="10" jobs="4" menhir="menhir":
	dune build tools/ambiguity_search.exe
	python3 tools/syntax_experiments.py {{ grammarFile }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }} --max-witnesses {{ max_witnesses }} --jobs {{ jobs }}

# Run one named variant, for example: just syntax-experiment semicolon-separated
syntax-experiment variant max_tokens="16" timeout="60" max_frontiers="500000" max_witnesses="20" menhir="menhir":
	dune build tools/ambiguity_search.exe
	python3 tools/syntax_experiments.py {{ grammarFile }} --variant {{ variant }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }} --max-witnesses {{ max_witnesses }}

syntax-experiments-list:
	python3 tools/syntax_experiments.py --list

syntax-experiments-test:
	python3 -m unittest tools.test_syntax_experiments -v
