(lang dune 3.21)
(name zane-compiler)
(generate_opam_files true)

(source
 (github zane-lang/compiler))

(using menhir 3.0)

(package
 (name zane-compiler)
 (synopsis "A short synopsis")
 (description "A longer description")
 (depends ocaml)
 (tags
  ("add topics" "to describe" your project)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
