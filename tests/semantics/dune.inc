; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/typing/accept))
 (action
  (with-stdout-to
   typing.accept.decls.actual
   (run %{exe:../../bin/zanec/zanec.exe} --decls --package fixtures/typing/accept/app --package fixtures/typing/accept/shapes))))

(rule
 (alias runtest)
 (action
  (diff golden/typing.accept.decls typing.accept.decls.actual)))

(rule
 (deps (source_tree fixtures/typing/accept))
 (action
  (with-stdout-to
   typing.accept.tst.actual
   (run %{exe:../../bin/zanec/zanec.exe} --tst --package fixtures/typing/accept/app --package fixtures/typing/accept/shapes))))

(rule
 (alias runtest)
 (action
  (diff golden/typing.accept.tst typing.accept.tst.actual)))

(rule
 (deps (source_tree fixtures/typing/accept))
 (action
  (with-stdout-to
   typing.accept.tst.spans.actual
   (run %{exe:../../tools/inspect/span_dump.exe} --tst --package fixtures/typing/accept/app --package fixtures/typing/accept/shapes))))

(rule
 (alias runtest)
 (action
  (diff golden/typing.accept.tst.spans typing.accept.tst.spans.actual)))

(rule
 (deps (source_tree fixtures/typing/exiting))
 (action
  (with-stderr-to
   typing.exiting.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/typing/exiting/exiting)))))

(rule
 (alias runtest)
 (action
  (diff golden/typing.exiting.err typing.exiting.err.actual)))

(rule
 (deps (source_tree fixtures/typing/reject))
 (action
  (with-stderr-to
   typing.reject.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/typing/reject/bad --package fixtures/typing/reject/lib)))))

(rule
 (alias runtest)
 (action
  (diff golden/typing.reject.err typing.reject.err.actual)))

