; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps (source_tree fixtures/arguments))
 (action
  (with-stdout-to
   arguments.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/arguments))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.optimized.cgt arguments.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/arguments))
 (targets arguments.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arguments.exe --package fixtures/arguments)))

(rule
 (deps (source_tree fixtures/arguments))
 (targets arguments.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arguments.optimized.exe --optimize --package fixtures/arguments)))

(rule
 (action
  (with-stdout-to
   arguments.out.actual
   (run ./arguments.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5"))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.out.actual)))

(rule
 (action
  (with-stdout-to
   arguments.optimized.out.actual
   (run ./arguments.optimized.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5"))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/arrayrefs))
 (action
  (with-stdout-to
   arrayrefs.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/arrayrefs))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.cgt arrayrefs.cgt.actual)))

(rule
 (deps (source_tree fixtures/arrayrefs))
 (targets arrayrefs.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arrayrefs.exe --package fixtures/arrayrefs)))

(rule
 (deps (source_tree fixtures/arrayrefs))
 (targets arrayrefs.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arrayrefs.optimized.exe --optimize --package fixtures/arrayrefs)))

(rule
 (action
  (with-stdout-to
   arrayrefs.out.actual
   (run ./arrayrefs.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.out.actual)))

(rule
 (action
  (with-stdout-to
   arrayrefs.optimized.out.actual
   (run ./arrayrefs.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/arrays))
 (action
  (with-stdout-to
   arrays.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/arrays))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.cgt arrays.cgt.actual)))

(rule
 (deps (source_tree fixtures/arrays))
 (targets arrays.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arrays.exe --package fixtures/arrays)))

(rule
 (deps (source_tree fixtures/arrays))
 (targets arrays.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build arrays.optimized.exe --optimize --package fixtures/arrays)))

(rule
 (action
  (with-stdout-to
   arrays.out.actual
   (run ./arrays.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.out.actual)))

(rule
 (action
  (with-stdout-to
   arrays.optimized.out.actual
   (run ./arrays.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/bounds))
 (targets bounds.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build bounds.exe --package fixtures/bounds)))

(rule
 (deps (source_tree fixtures/bounds))
 (targets bounds.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build bounds.optimized.exe --optimize --package fixtures/bounds)))

(rule
 (action
  (with-outputs-to
   bounds.out.actual
   (with-accepted-exit-codes
    1
    (run ./bounds.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.out.actual)))

(rule
 (action
  (with-outputs-to
   bounds.optimized.out.actual
   (with-accepted-exit-codes
    1
    (run ./bounds.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/boxes))
 (action
  (with-stdout-to
   boxes.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/boxes))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.cgt boxes.cgt.actual)))

(rule
 (deps (source_tree fixtures/boxes))
 (targets boxes.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build boxes.exe --package fixtures/boxes)))

(rule
 (deps (source_tree fixtures/boxes))
 (targets boxes.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build boxes.optimized.exe --optimize --package fixtures/boxes)))

(rule
 (action
  (with-stdout-to
   boxes.out.actual
   (run ./boxes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.out.actual)))

(rule
 (action
  (with-stdout-to
   boxes.optimized.out.actual
   (run ./boxes.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/constants))
 (action
  (with-stdout-to
   constants.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/constants))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.cgt constants.cgt.actual)))

(rule
 (deps (source_tree fixtures/constants))
 (action
  (with-stdout-to
   constants.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/constants))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.optimized.cgt constants.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/constants))
 (targets constants.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build constants.exe --package fixtures/constants)))

(rule
 (deps (source_tree fixtures/constants))
 (targets constants.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build constants.optimized.exe --optimize --package fixtures/constants)))

(rule
 (action
  (with-stdout-to
   constants.out.actual
   (run ./constants.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.out.actual)))

(rule
 (action
  (with-stdout-to
   constants.optimized.out.actual
   (run ./constants.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/counting))
 (action
  (with-stdout-to
   counting.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/counting))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.cgt counting.cgt.actual)))

(rule
 (deps (source_tree fixtures/counting))
 (action
  (with-stdout-to
   counting.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/counting))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.optimized.cgt counting.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/counting))
 (targets counting.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build counting.exe --package fixtures/counting)))

(rule
 (deps (source_tree fixtures/counting))
 (targets counting.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build counting.optimized.exe --optimize --package fixtures/counting)))

(rule
 (action
  (with-stdout-to
   counting.out.actual
   (run ./counting.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.out.actual)))

(rule
 (action
  (with-stdout-to
   counting.optimized.out.actual
   (run ./counting.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/defaults))
 (action
  (with-stdout-to
   defaults.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/defaults))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.cgt defaults.cgt.actual)))

(rule
 (deps (source_tree fixtures/defaults))
 (targets defaults.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build defaults.exe --package fixtures/defaults)))

(rule
 (deps (source_tree fixtures/defaults))
 (targets defaults.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build defaults.optimized.exe --optimize --package fixtures/defaults)))

(rule
 (action
  (with-stdout-to
   defaults.out.actual
   (run ./defaults.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.out.actual)))

(rule
 (action
  (with-stdout-to
   defaults.optimized.out.actual
   (run ./defaults.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/folding))
 (action
  (with-stdout-to
   folding.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/folding))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.cgt folding.cgt.actual)))

(rule
 (deps (source_tree fixtures/folding))
 (action
  (with-stdout-to
   folding.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/folding))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.optimized.cgt folding.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/folding))
 (targets folding.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build folding.exe --package fixtures/folding)))

(rule
 (deps (source_tree fixtures/folding))
 (targets folding.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build folding.optimized.exe --optimize --package fixtures/folding)))

(rule
 (action
  (with-stdout-to
   folding.out.actual
   (run ./folding.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.out.actual)))

(rule
 (action
  (with-stdout-to
   folding.optimized.out.actual
   (run ./folding.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/hello))
 (action
  (with-stdout-to
   hello.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/hello))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.cgt hello.cgt.actual)))

(rule
 (deps (source_tree fixtures/hello))
 (targets hello.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build hello.exe --package fixtures/hello)))

(rule
 (deps (source_tree fixtures/hello))
 (targets hello.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build hello.optimized.exe --optimize --package fixtures/hello)))

(rule
 (action
  (with-stdout-to
   hello.out.actual
   (run ./hello.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.out.actual)))

(rule
 (action
  (with-stdout-to
   hello.optimized.out.actual
   (run ./hello.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/lambdas))
 (action
  (with-stdout-to
   lambdas.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/lambdas))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.cgt lambdas.cgt.actual)))

(rule
 (deps (source_tree fixtures/lambdas))
 (targets lambdas.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lambdas.exe --package fixtures/lambdas)))

(rule
 (deps (source_tree fixtures/lambdas))
 (targets lambdas.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lambdas.optimized.exe --optimize --package fixtures/lambdas)))

(rule
 (action
  (with-stdout-to
   lambdas.out.actual
   (run ./lambdas.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.out.actual)))

(rule
 (action
  (with-stdout-to
   lambdas.optimized.out.actual
   (run ./lambdas.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/lists))
 (action
  (with-stdout-to
   lists.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/lists))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.cgt lists.cgt.actual)))

(rule
 (deps (source_tree fixtures/lists))
 (targets lists.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lists.exe --package fixtures/lists)))

(rule
 (deps (source_tree fixtures/lists))
 (targets lists.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build lists.optimized.exe --optimize --package fixtures/lists)))

(rule
 (action
  (with-stdout-to
   lists.out.actual
   (run ./lists.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.out.actual)))

(rule
 (action
  (with-stdout-to
   lists.optimized.out.actual
   (run ./lists.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/operators))
 (targets operators.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build operators.exe --package fixtures/operators)))

(rule
 (deps (source_tree fixtures/operators))
 (targets operators.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build operators.optimized.exe --optimize --package fixtures/operators)))

(rule
 (action
  (with-stdout-to
   operators.out.actual
   (run ./operators.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.out.actual)))

(rule
 (action
  (with-stdout-to
   operators.optimized.out.actual
   (run ./operators.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/outcomes))
 (action
  (with-stdout-to
   outcomes.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/outcomes))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.cgt outcomes.cgt.actual)))

(rule
 (deps (source_tree fixtures/outcomes))
 (targets outcomes.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build outcomes.exe --package fixtures/outcomes)))

(rule
 (deps (source_tree fixtures/outcomes))
 (targets outcomes.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build outcomes.optimized.exe --optimize --package fixtures/outcomes)))

(rule
 (action
  (with-stdout-to
   outcomes.out.actual
   (run ./outcomes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.out.actual)))

(rule
 (action
  (with-stdout-to
   outcomes.optimized.out.actual
   (run ./outcomes.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/owners))
 (action
  (with-stdout-to
   owners.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/owners))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.cgt owners.cgt.actual)))

(rule
 (deps (source_tree fixtures/owners))
 (targets owners.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build owners.exe --package fixtures/owners)))

(rule
 (deps (source_tree fixtures/owners))
 (targets owners.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build owners.optimized.exe --optimize --package fixtures/owners)))

(rule
 (action
  (with-stdout-to
   owners.out.actual
   (run ./owners.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.out.actual)))

(rule
 (action
  (with-stdout-to
   owners.optimized.out.actual
   (run ./owners.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/probed))
 (targets probed.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build probed.exe --package fixtures/probed)))

(rule
 (deps (source_tree fixtures/probed))
 (targets probed.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build probed.optimized.exe --optimize --package fixtures/probed)))

(rule
 (action
  (with-stdout-to
   probed.out.actual
   (run ./probed.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.out.actual)))

(rule
 (action
  (with-stdout-to
   probed.optimized.out.actual
   (run ./probed.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/range))
 (targets range.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build range.exe --package fixtures/range)))

(rule
 (deps (source_tree fixtures/range))
 (targets range.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build range.optimized.exe --optimize --package fixtures/range)))

(rule
 (action
  (with-outputs-to
   range.out.actual
   (with-accepted-exit-codes
    1
    (run ./range.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.out.actual)))

(rule
 (action
  (with-outputs-to
   range.optimized.out.actual
   (with-accepted-exit-codes
    1
    (run ./range.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/references))
 (action
  (with-stdout-to
   references.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/references))))

(rule
 (alias runtest)
 (action
  (diff golden/references.cgt references.cgt.actual)))

(rule
 (deps (source_tree fixtures/references))
 (targets references.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build references.exe --package fixtures/references)))

(rule
 (deps (source_tree fixtures/references))
 (targets references.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build references.optimized.exe --optimize --package fixtures/references)))

(rule
 (action
  (with-stdout-to
   references.out.actual
   (run ./references.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.out.actual)))

(rule
 (action
  (with-stdout-to
   references.optimized.out.actual
   (run ./references.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/regions))
 (targets regions.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build regions.exe --package fixtures/regions)))

(rule
 (deps (source_tree fixtures/regions))
 (targets regions.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build regions.optimized.exe --optimize --package fixtures/regions)))

(rule
 (action
  (with-stdout-to
   regions.out.actual
   (run ./regions.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.out.actual)))

(rule
 (action
  (with-stdout-to
   regions.optimized.out.actual
   (run ./regions.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/replayed))
 (action
  (with-stdout-to
   replayed.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/replayed))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.optimized.cgt replayed.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/replayed))
 (targets replayed.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build replayed.exe --package fixtures/replayed)))

(rule
 (deps (source_tree fixtures/replayed))
 (targets replayed.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build replayed.optimized.exe --optimize --package fixtures/replayed)))

(rule
 (action
  (with-stdout-to
   replayed.out.actual
   (run ./replayed.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.out.actual)))

(rule
 (action
  (with-stdout-to
   replayed.optimized.out.actual
   (run ./replayed.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/scalarTexts))
 (targets scalarTexts.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build scalarTexts.exe --package fixtures/scalarTexts)))

(rule
 (deps (source_tree fixtures/scalarTexts))
 (targets scalarTexts.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build scalarTexts.optimized.exe --optimize --package fixtures/scalarTexts)))

(rule
 (action
  (with-stdout-to
   scalarTexts.out.actual
   (run ./scalarTexts.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.out.actual)))

(rule
 (action
  (with-stdout-to
   scalarTexts.optimized.out.actual
   (run ./scalarTexts.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/scalars))
 (action
  (with-stdout-to
   scalars.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/scalars))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.optimized.cgt scalars.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/scalars))
 (targets scalars.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build scalars.exe --package fixtures/scalars)))

(rule
 (deps (source_tree fixtures/scalars))
 (targets scalars.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build scalars.optimized.exe --optimize --package fixtures/scalars)))

(rule
 (action
  (with-stdout-to
   scalars.out.actual
   (run ./scalars.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.out.actual)))

(rule
 (action
  (with-stdout-to
   scalars.optimized.out.actual
   (run ./scalars.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/settled))
 (action
  (with-stdout-to
   settled.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/settled))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.cgt settled.cgt.actual)))

(rule
 (deps (source_tree fixtures/settled))
 (targets settled.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build settled.exe --package fixtures/settled)))

(rule
 (deps (source_tree fixtures/settled))
 (targets settled.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build settled.optimized.exe --optimize --package fixtures/settled)))

(rule
 (action
  (with-stdout-to
   settled.out.actual
   (run ./settled.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.out.actual)))

(rule
 (action
  (with-stdout-to
   settled.optimized.out.actual
   (run ./settled.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/shapes))
 (action
  (with-stdout-to
   shapes.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/shapes))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.cgt shapes.cgt.actual)))

(rule
 (deps (source_tree fixtures/shapes))
 (targets shapes.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build shapes.exe --package fixtures/shapes)))

(rule
 (deps (source_tree fixtures/shapes))
 (targets shapes.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build shapes.optimized.exe --optimize --package fixtures/shapes)))

(rule
 (action
  (with-stdout-to
   shapes.out.actual
   (run ./shapes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.out.actual)))

(rule
 (action
  (with-stdout-to
   shapes.optimized.out.actual
   (run ./shapes.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/spawned))
 (action
  (with-stdout-to
   spawned.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/spawned))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.cgt spawned.cgt.actual)))

(rule
 (deps (source_tree fixtures/spawned))
 (targets spawned.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawned.exe --package fixtures/spawned)))

(rule
 (deps (source_tree fixtures/spawned))
 (targets spawned.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawned.optimized.exe --optimize --package fixtures/spawned)))

(rule
 (action
  (with-stdout-to
   spawned.out.actual
   (run ./spawned.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.out.actual)))

(rule
 (action
  (with-stdout-to
   spawned.optimized.out.actual
   (run ./spawned.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/spawns))
 (action
  (with-stdout-to
   spawns.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/spawns))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.cgt spawns.cgt.actual)))

(rule
 (deps (source_tree fixtures/spawns))
 (targets spawns.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawns.exe --package fixtures/spawns)))

(rule
 (deps (source_tree fixtures/spawns))
 (targets spawns.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawns.optimized.exe --optimize --package fixtures/spawns)))

(rule
 (action
  (with-stdout-to
   spawns.out.actual
   (run ./spawns.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.out.actual)))

(rule
 (action
  (with-stdout-to
   spawns.optimized.out.actual
   (run ./spawns.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/texts))
 (action
  (with-stdout-to
   texts.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/texts))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.cgt texts.cgt.actual)))

(rule
 (deps (source_tree fixtures/texts))
 (targets texts.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build texts.exe --package fixtures/texts)))

(rule
 (deps (source_tree fixtures/texts))
 (targets texts.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build texts.optimized.exe --optimize --package fixtures/texts)))

(rule
 (action
  (with-stdout-to
   texts.out.actual
   (run ./texts.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.out.actual)))

(rule
 (action
  (with-stdout-to
   texts.optimized.out.actual
   (run ./texts.optimized.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.optimized.out.actual)))

(rule
 (deps (source_tree fixtures/reject/literalOperator))
 (action
  (with-stderr-to
   reject.literalOperator.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/literalOperator)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.literalOperator.err reject.literalOperator.err.actual)))

(rule
 (deps (source_tree fixtures/reject/literalRange))
 (action
  (with-stderr-to
   reject.literalRange.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/literalRange)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.literalRange.err reject.literalRange.err.actual)))

(rule
 (deps (source_tree fixtures/reject/unitFuture))
 (action
  (with-stderr-to
   reject.unitFuture.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/unitFuture)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.unitFuture.err reject.unitFuture.err.actual)))

(rule
 (deps (source_tree fixtures/reject/valueFlow))
 (action
  (with-stderr-to
   reject.valueFlow.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/valueFlow)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.valueFlow.err reject.valueFlow.err.actual)))

