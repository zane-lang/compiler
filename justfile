default:
	just -l

projectName := "zane-compiler"

run:
	dune build
	dune exec {{projectName}}
