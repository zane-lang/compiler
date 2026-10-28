; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/declarations))
 (action
  (with-stdout-to
   declarations.tst.actual
   (run %{exe:../../bin/zanec/zanec.exe} --tst --package fixtures/declarations/app --package fixtures/declarations/fs))))

(rule
 (alias runtest)
 (action
  (diff golden/declarations.tst declarations.tst.actual)))

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
 (deps (source_tree fixtures/reject/handleC))
 (action
  (with-stderr-to
   reject.handleC.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/handleC)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.handleC.err reject.handleC.err.actual)))

(rule
 (deps (source_tree fixtures/reject/handleForms))
 (action
  (with-stderr-to
   reject.handleForms.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/handleForms)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.handleForms.err reject.handleForms.err.actual)))

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
 (deps (source_tree fixtures/reject/interface))
 (action
  (with-stderr-to
   reject.interface.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/interface)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.interface.err reject.interface.err.actual)))

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
 (deps (source_tree fixtures/reject/overwrite))
 (action
  (with-stderr-to
   reject.overwrite.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/overwrite/app --package fixtures/reject/overwrite/fs)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.overwrite.err reject.overwrite.err.actual)))

(rule
 (deps (source_tree fixtures/reject/positions))
 (action
  (with-stderr-to
   reject.positions.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/positions/app --package fixtures/reject/positions/io)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.positions.err reject.positions.err.actual)))

(rule
 (deps (source_tree fixtures/reject/variables))
 (action
  (with-stderr-to
   reject.variables.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/variables/app --package fixtures/reject/variables/lib)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.variables.err reject.variables.err.actual)))

(rule
 (deps (source_tree fixtures/reject/verbForms))
 (action
  (with-stderr-to
   reject.verbForms.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/verbForms)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.verbForms.err reject.verbForms.err.actual)))

(rule
 (deps (source_tree fixtures/reject/windowsInt))
 (action
  (with-stderr-to
   reject.windowsInt.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check "--target" "x86_64-windows-gnu" --package fixtures/reject/windowsInt)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.windowsInt.err reject.windowsInt.err.actual)))

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

