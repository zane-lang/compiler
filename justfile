set dotenv-load := true
set dotenv-filename := "machine-config.txt"

grammarFile := "lib/cst/parser.mly"

ambiguity_memory_mb := env_var_or_default("AMBIGUITY_MEMORY_MB", "512")
ambiguity_max_frontier_ratio := env_var_or_default("AMBIGUITY_MAX_FRONTIER_RATIO", "1.0")
ambiguity_jobs := env_var_or_default("AMBIGUITY_JOBS", "4")
ambiguity_menhir := env_var_or_default("AMBIGUITY_MENHIR", "menhir")

default:
	just -l

# Show the machine-specific ambiguity-search settings currently in effect.
ambiguity-config:
	@echo "memory: {{ ambiguity_memory_mb }} MiB total"
	@echo "frontier ratio: {{ ambiguity_max_frontier_ratio }}"
	@echo "workers: {{ ambiguity_jobs }}"
	@echo "menhir: {{ ambiguity_menhir }}"

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
ambiguities max_tokens="50" timeout="1800" max_witnesses="50":
	dune exec tools/ambiguity_search.exe -- {{ grammarFile }} --menhir {{ ambiguity_menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --memory-mb {{ ambiguity_memory_mb }} --max-frontier-ratio {{ ambiguity_max_frontier_ratio }} --jobs {{ ambiguity_jobs }} --max-witnesses {{ max_witnesses }}

# Conservative unambiguity proof attempt: exit 0 proven, 1 ambiguous, 3 not proven.
prove level="2" max_tokens="12" timeout="120":
	dune exec tools/ambiguity_search.exe -- {{ grammarFile }} --prove {{ level }} --menhir {{ ambiguity_menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --memory-mb {{ ambiguity_memory_mb }} --max-frontier-ratio {{ ambiguity_max_frontier_ratio }} --jobs {{ ambiguity_jobs }}

# Compare all controlled syntax variants and write Markdown/JSON reports.
syntax-experiments max_tokens="12" timeout="15" max_witnesses="10":
	dune build tools/ambiguity_search.exe
	python3 tools/syntax_experiments.py {{ grammarFile }} --menhir {{ ambiguity_menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --memory-mb {{ ambiguity_memory_mb }} --max-frontier-ratio {{ ambiguity_max_frontier_ratio }} --max-witnesses {{ max_witnesses }} --jobs {{ ambiguity_jobs }}

# Run one named variant, for example: just syntax-experiment semicolon-separated
syntax-experiment variant max_tokens="16" timeout="60" max_witnesses="20":
	dune build tools/ambiguity_search.exe
	python3 tools/syntax_experiments.py {{ grammarFile }} --variant {{ variant }} --menhir {{ ambiguity_menhir }} --max-tokens {{ max_tokens }} --timeout {{ timeout }} --memory-mb {{ ambiguity_memory_mb }} --max-frontier-ratio {{ ambiguity_max_frontier_ratio }} --max-witnesses {{ max_witnesses }} --jobs 1 --search-jobs {{ ambiguity_jobs }}

syntax-experiments-list:
	python3 tools/syntax_experiments.py --list

syntax-experiments-test:
	python3 -m unittest tools.test_syntax_experiments -v
