; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/calls))
 (action
  (with-stdout-to
   calls.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/calls/app --package fixtures/calls/lib))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.cgt calls.cgt.actual)))

(rule
 (deps (source_tree fixtures/calls))
 (action
  (with-stdout-to
   calls.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/calls/app --package fixtures/calls/lib))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.optimized.cgt calls.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/calls))
 (targets calls.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build calls.exe --package fixtures/calls/app --package fixtures/calls/lib)))

(rule
 (deps (source_tree fixtures/calls))
 (targets calls.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build calls.optimized.exe --optimize --package fixtures/calls/app --package fixtures/calls/lib)))

(rule
 (deps (source_tree fixtures/calls))
 (targets calls.tiered.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build calls.tiered.exe --tiered --package fixtures/calls/app --package fixtures/calls/lib)))

(rule
 (deps (source_tree fixtures/calls))
 (targets calls.tier1)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --tier-up calls.tier1 --package fixtures/calls/app --package fixtures/calls/lib)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    calls.checked.out.actual
    (run ./calls.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    calls.unchecked.out.actual
    (run ./calls.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    calls.optimized.checked.out.actual
    (run ./calls.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    calls.optimized.unchecked.out.actual
    (run ./calls.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.optimized.unchecked.out.actual)))

(rule
 (deps calls.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./calls.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    calls.tiered.checked.out.actual
    (run ./calls.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.tiered.checked.out.actual)))

(rule
 (deps calls.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./calls.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    calls.tiered.unchecked.out.actual
    (run ./calls.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/calls.out calls.tiered.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/functions))
 (action
  (with-stdout-to
   functions.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/functions))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.cgt functions.cgt.actual)))

(rule
 (deps (source_tree fixtures/functions))
 (targets functions.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build functions.exe --package fixtures/functions)))

(rule
 (deps (source_tree fixtures/functions))
 (targets functions.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build functions.optimized.exe --optimize --package fixtures/functions)))

(rule
 (deps (source_tree fixtures/functions))
 (targets functions.tiered.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build functions.tiered.exe --tiered --package fixtures/functions)))

(rule
 (deps (source_tree fixtures/functions))
 (targets functions.tier1)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --tier-up functions.tier1 --package fixtures/functions)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    functions.checked.out.actual
    (run ./functions.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    functions.unchecked.out.actual
    (run ./functions.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    functions.optimized.checked.out.actual
    (run ./functions.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    functions.optimized.unchecked.out.actual
    (run ./functions.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.optimized.unchecked.out.actual)))

(rule
 (deps functions.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./functions.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    functions.tiered.checked.out.actual
    (run ./functions.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.tiered.checked.out.actual)))

(rule
 (deps functions.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./functions.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    functions.tiered.unchecked.out.actual
    (run ./functions.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/functions.out functions.tiered.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/handles))
 (action
  (with-stdout-to
   handles.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/handles))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.cgt handles.cgt.actual)))

(rule
 (deps (source_tree fixtures/handles))
 (targets handles.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build handles.exe --package fixtures/handles)))

(rule
 (deps (source_tree fixtures/handles))
 (targets handles.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build handles.optimized.exe --optimize --package fixtures/handles)))

(rule
 (deps (source_tree fixtures/handles))
 (targets handles.tiered.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build handles.tiered.exe --tiered --package fixtures/handles)))

(rule
 (deps (source_tree fixtures/handles))
 (targets handles.tier1)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --tier-up handles.tier1 --package fixtures/handles)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    handles.checked.out.actual
    (run ./handles.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    handles.unchecked.out.actual
    (run ./handles.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    handles.optimized.checked.out.actual
    (run ./handles.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    handles.optimized.unchecked.out.actual
    (run ./handles.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.optimized.unchecked.out.actual)))

(rule
 (deps handles.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./handles.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    handles.tiered.checked.out.actual
    (run ./handles.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.tiered.checked.out.actual)))

(rule
 (deps handles.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./handles.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    handles.tiered.unchecked.out.actual
    (run ./handles.tiered.exe)))))))

(rule
 (alias runtest)
 (action
  (diff golden/handles.out handles.tiered.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/noObject))
 (targets noObject.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build noObject.exe --package fixtures/noObject)))

(rule
 (deps (source_tree fixtures/noObject))
 (targets noObject.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build noObject.optimized.exe --optimize --package fixtures/noObject)))

(rule
 (deps (source_tree fixtures/noObject))
 (targets noObject.tiered.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build noObject.tiered.exe --tiered --package fixtures/noObject)))

(rule
 (deps (source_tree fixtures/noObject))
 (targets noObject.tier1)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --tier-up noObject.tier1 --package fixtures/noObject)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    noObject.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    noObject.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    noObject.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    noObject.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.optimized.unchecked.out.actual)))

(rule
 (deps noObject.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./noObject.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    noObject.tiered.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.tiered.exe))))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.tiered.checked.out.actual)))

(rule
 (deps noObject.tier1)
 (action
  (setenv
   ZANE_TIER_UP
   ./noObject.tier1
   (setenv
    ZANE_TIER_WAIT
    1
    (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    noObject.tiered.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./noObject.tiered.exe))))))))

(rule
 (alias runtest)
 (action
  (diff golden/noObject.out noObject.tiered.unchecked.out.actual)))

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
 (deps (source_tree fixtures/reject/assembly))
 (action
  (with-stderr-to
   reject.assembly.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/assembly)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.assembly.err reject.assembly.err.actual)))

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
 (deps (source_tree fixtures/reject/linkerSet))
 (action
  (with-stderr-to
   reject.linkerSet.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/linkerSet)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.linkerSet.err reject.linkerSet.err.actual)))

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
 (deps (source_tree fixtures/reject/sharedState))
 (action
  (with-stderr-to
   reject.sharedState.ll.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --ll --package fixtures/reject/sharedState)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.sharedState.ll.err reject.sharedState.ll.err.actual)))

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
 (deps (source_tree fixtures/reject/views))
 (action
  (with-stderr-to
   reject.views.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/views)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.views.err reject.views.err.actual)))

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

