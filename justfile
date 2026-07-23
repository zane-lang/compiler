default:
	just -l

rebuild:
	dune clean
	dune build

watch:
	dune build --watch

syntax-experiment-test:
	python3 -m unittest tools.test_syntax_experiment -v

ambiguity-test:
	python3 -m unittest tools.test_ambiguity -v
