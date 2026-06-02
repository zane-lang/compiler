default:
	just -l

run:
	dune exec bin/compiler/main.exe

watch:
	dune build --watch
