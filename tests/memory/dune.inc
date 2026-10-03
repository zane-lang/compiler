; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/run/carried))
 (targets carried.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build carried.exe --package fixtures/run/carried)))

(rule
 (deps (source_tree fixtures/run/carried))
 (targets carried.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build carried.optimized.exe --optimize --package fixtures/run/carried)))

(rule
 (action
  (with-stdout-to
   carried.out.actual
   (run ./carried.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/carried.out carried.out.actual)))

(rule
 (action
  (with-stdout-to
   carried.optimized.out.actual
   (run ./carried.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/carried.out carried.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/run/floats))
 (targets floats.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build floats.exe --package fixtures/run/floats)))

(rule
 (deps (source_tree fixtures/run/floats))
 (targets floats.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build floats.optimized.exe --optimize --package fixtures/run/floats)))

(rule
 (action
  (with-stdout-to
   floats.out.actual
   (run ./floats.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/floats.out floats.out.actual)))

(rule
 (action
  (with-stdout-to
   floats.optimized.out.actual
   (run ./floats.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/floats.out floats.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/run/lending))
 (targets lending.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lending.exe --package fixtures/run/lending)))

(rule
 (deps (source_tree fixtures/run/lending))
 (targets lending.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lending.optimized.exe --optimize --package fixtures/run/lending)))

(rule
 (action
  (with-stdout-to
   lending.out.actual
   (run ./lending.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lending.out lending.out.actual)))

(rule
 (action
  (with-stdout-to
   lending.optimized.out.actual
   (run ./lending.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lending.out lending.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/run/stores))
 (targets stores.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build stores.exe --package fixtures/run/stores)))

(rule
 (deps (source_tree fixtures/run/stores))
 (targets stores.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build stores.optimized.exe --optimize --package fixtures/run/stores)))

(rule
 (action
  (with-stdout-to
   stores.out.actual
   (run ./stores.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/stores.out stores.out.actual)))

(rule
 (action
  (with-stdout-to
   stores.optimized.out.actual
   (run ./stores.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/stores.out stores.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/reject/carried))
 (action
  (with-stderr-to
   reject.carried.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/carried)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.carried.err reject.carried.err.actual)))

(rule
 (deps (source_tree fixtures/reject/moves))
 (action
  (with-stderr-to
   reject.moves.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/moves)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.moves.err reject.moves.err.actual)))

(rule
 (deps (source_tree fixtures/reject/rests))
 (action
  (with-stderr-to
   reject.rests.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/rests)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.rests.err reject.rests.err.actual)))

(rule
 (deps (source_tree fixtures/reject/returns))
 (action
  (with-stderr-to
   reject.returns.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/returns)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.returns.err reject.returns.err.actual)))

(rule
 (deps (source_tree fixtures/reject/sources))
 (action
  (with-stderr-to
   reject.sources.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/sources)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.sources.err reject.sources.err.actual)))

(rule
 (deps (source_tree fixtures/reject/stores))
 (action
  (with-stderr-to
   reject.stores.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --check --package fixtures/reject/stores)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.stores.err reject.stores.err.actual)))

