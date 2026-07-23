default:
	just -l

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

syntax-experiments-test:
	python3 -m unittest tools.test_syntax_experiments -v

ambiguities-test:
	python3 -m unittest tools.test_ambiguities -v
