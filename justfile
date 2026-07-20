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
ambiguities max_tokens="20" timeout="60" max_frontiers="500000" jobs="4" menhir="menhir":
	dune exec tools/ambiguity_search.exe -- {{ grammarFile }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }} --jobs {{ jobs }}

# Slower reference implementation, useful for cross-checking the OCaml search.
ambiguities-python max_tokens="20" timeout="60" max_frontiers="500000" menhir="menhir":
	python3 tools/find_ambiguity.py {{ grammarFile }} --menhir {{ menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --max-frontiers {{ max_frontiers }}
