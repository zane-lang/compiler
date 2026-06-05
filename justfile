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
