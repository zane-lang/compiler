(lang dune 3.21)
(name zane-compiler)
(generate_opam_files true)

(source
 (github zane-lang/compiler))

(using menhir 3.0)

(package
 (name zane-compiler)
 (synopsis "Compiler and CLI for the Zane programming language")
 (description
  "The Zane compiler: a sedlex lexer, a Menhir GLR grammar producing a concrete\nsyntax tree, and the developer tooling used to keep that grammar unambiguous.")
 (depends
  ; The project targets OCaml 5: devbox provides ocaml@latest and CI builds on
  ; the ocaml-system switch that gives. 5.0 was the transitional first release
  ; of the series, so the floor is the one after it.
  (ocaml (>= 5.1))
  ; lib/cst/dune builds the grammar with --GLR, which the 20260122 release line
  ; introduced along with the menhirGLR runtime that lib/cst links against.
  (menhir (>= 20260122))
  menhirGLR
  sedlex)
 (tags
  ("compiler" "zane" "parser" "menhir" "ocaml")))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
