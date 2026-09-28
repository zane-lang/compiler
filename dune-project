(lang dune 3.21)
(name zane-compiler)
(generate_opam_files true)

(source
 (github zane-lang/compiler))

(license GPL-3.0-only)

(authors "Manuel Stieger")

(maintainers "Manuel Stieger")

(using menhir 3.0)

(package
 (name zane-compiler)
 (synopsis "Compiler and CLI for the Zane programming language")
 (description
  "The Zane compiler, zanec: a sedlex lexer and a Menhir GLR grammar producing\na concrete syntax tree, desugaring into the SST, semantic analysis into the\ntyped TST, lowering into the CGT, LLVM code generation, and the C runtime\nlinked into every program. Also the developer tooling used to keep the grammar\nunambiguous.")
 (depends
  ; The project targets OCaml 5: devbox provides ocaml@latest and CI builds on
  ; the ocaml-system switch that gives. 5.0 was the transitional first release
  ; of the series, so the floor is the one after it.
  (ocaml (>= 5.1))
  ; lib/cst/dune builds the grammar with --GLR, which the 20260122 release line
  ; introduced along with the menhirGLR runtime that lib/cst links against.
  (menhir (>= 20260122))
  menhirGLR
  sedlex
  ; Codegen builds its LLVM module through the bindings (docs/design/lowering.md L2).
  llvm)
 (tags
  ("compiler" "zane" "parser" "menhir" "ocaml")))
