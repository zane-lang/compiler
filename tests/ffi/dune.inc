; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/reject/absolute))
 (action
  (with-stderr-to
   reject.absolute.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/absolute)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.absolute.err reject.absolute.err.actual)))

(rule
 (deps (source_tree fixtures/reject/badHeader))
 (action
  (with-stderr-to
   reject.badHeader.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/badHeader)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.badHeader.err reject.badHeader.err.actual)))

(rule
 (deps (source_tree fixtures/reject/badSetting))
 (action
  (with-stderr-to
   reject.badSetting.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/badSetting)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.badSetting.err reject.badSetting.err.actual)))

(rule
 (deps (source_tree fixtures/reject/cError))
 (action
  (with-stderr-to
   reject.cError.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/cError)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.cError.err reject.cError.err.actual)))

(rule
 (deps (source_tree fixtures/reject/escapes))
 (action
  (with-stderr-to
   reject.escapes.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/escapes)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.escapes.err reject.escapes.err.actual)))

(rule
 (deps (source_tree fixtures/reject/fixedMacro))
 (action
  (with-stderr-to
   reject.fixedMacro.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/fixedMacro)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.fixedMacro.err reject.fixedMacro.err.actual)))

(rule
 (deps (source_tree fixtures/reject/headerError))
 (action
  (with-stderr-to
   reject.headerError.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/headerError)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.headerError.err reject.headerError.err.actual)))

(rule
 (deps (source_tree fixtures/reject/noMatch))
 (action
  (with-stderr-to
   reject.noMatch.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/noMatch)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.noMatch.err reject.noMatch.err.actual)))

(rule
 (deps (source_tree fixtures/reject/notCoda))
 (action
  (with-stderr-to
   reject.notCoda.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/notCoda)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.notCoda.err reject.notCoda.err.actual)))

(rule
 (deps (source_tree fixtures/vendored))
 (action
  (with-outputs-to
   vendored.check.actual
   (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/vendored))))

(rule
 (alias runtest)
 (action
  (diff golden/vendored.check vendored.check.actual)))

