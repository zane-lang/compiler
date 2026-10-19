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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arguments.checked.out.actual
    (run ./arguments.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5")))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arguments.unchecked.out.actual
    (run ./arguments.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5")))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arguments.optimized.checked.out.actual
    (run ./arguments.optimized.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5")))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arguments.optimized.unchecked.out.actual
    (run ./arguments.optimized.exe "42" "-7" "3.25" "12x" "" "99999999999999999999" "9223372036854775807" "-9223372036854775808" "+5" " 5")))))

(rule
 (alias runtest)
 (action
  (diff golden/arguments.out arguments.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arrayrefs.checked.out.actual
    (run ./arrayrefs.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arrayrefs.unchecked.out.actual
    (run ./arrayrefs.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arrayrefs.optimized.checked.out.actual
    (run ./arrayrefs.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arrayrefs.optimized.unchecked.out.actual
    (run ./arrayrefs.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrayrefs.out arrayrefs.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arrays.checked.out.actual
    (run ./arrays.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arrays.unchecked.out.actual
    (run ./arrays.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    arrays.optimized.checked.out.actual
    (run ./arrays.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    arrays.optimized.unchecked.out.actual
    (run ./arrays.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/arrays.out arrays.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/bigCalls))
 (targets bigCalls.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build bigCalls.exe --package fixtures/bigCalls)))

(rule
 (deps (source_tree fixtures/bigCalls))
 (targets bigCalls.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build bigCalls.optimized.exe --optimize --package fixtures/bigCalls)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    bigCalls.checked.out.actual
    (run ./bigCalls.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bigCalls.out bigCalls.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    bigCalls.unchecked.out.actual
    (run ./bigCalls.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bigCalls.out bigCalls.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    bigCalls.optimized.checked.out.actual
    (run ./bigCalls.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bigCalls.out bigCalls.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    bigCalls.optimized.unchecked.out.actual
    (run ./bigCalls.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/bigCalls.out bigCalls.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    bounds.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./bounds.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    bounds.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./bounds.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    bounds.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./bounds.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    bounds.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./bounds.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/bounds.out bounds.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/boundsNegative))
 (targets boundsNegative.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build boundsNegative.exe --package fixtures/boundsNegative)))

(rule
 (deps (source_tree fixtures/boundsNegative))
 (targets boundsNegative.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build boundsNegative.optimized.exe --optimize --package fixtures/boundsNegative)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    boundsNegative.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./boundsNegative.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/boundsNegative.out boundsNegative.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    boundsNegative.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./boundsNegative.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/boundsNegative.out boundsNegative.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    boundsNegative.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./boundsNegative.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/boundsNegative.out boundsNegative.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    boundsNegative.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./boundsNegative.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/boundsNegative.out boundsNegative.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    boxes.checked.out.actual
    (run ./boxes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    boxes.unchecked.out.actual
    (run ./boxes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    boxes.optimized.checked.out.actual
    (run ./boxes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    boxes.optimized.unchecked.out.actual
    (run ./boxes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    constants.checked.out.actual
    (run ./constants.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    constants.unchecked.out.actual
    (run ./constants.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    constants.optimized.checked.out.actual
    (run ./constants.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    constants.optimized.unchecked.out.actual
    (run ./constants.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/constants.out constants.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    counting.checked.out.actual
    (run ./counting.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    counting.unchecked.out.actual
    (run ./counting.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    counting.optimized.checked.out.actual
    (run ./counting.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    counting.optimized.unchecked.out.actual
    (run ./counting.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/counting.out counting.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/crossing))
 (targets crossing.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build crossing.exe --package fixtures/crossing)))

(rule
 (deps (source_tree fixtures/crossing))
 (targets crossing.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build crossing.optimized.exe --optimize --package fixtures/crossing)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    crossing.checked.out.actual
    (run ./crossing.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossing.out crossing.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    crossing.unchecked.out.actual
    (run ./crossing.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossing.out crossing.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    crossing.optimized.checked.out.actual
    (run ./crossing.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossing.out crossing.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    crossing.optimized.unchecked.out.actual
    (run ./crossing.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossing.out crossing.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/crossingPacked))
 (targets crossingPacked.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build crossingPacked.exe "--pack-aggregates" --package fixtures/crossingPacked)))

(rule
 (deps (source_tree fixtures/crossingPacked))
 (targets crossingPacked.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build crossingPacked.optimized.exe --optimize "--pack-aggregates" --package fixtures/crossingPacked)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    crossingPacked.checked.out.actual
    (run ./crossingPacked.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossingPacked.out crossingPacked.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    crossingPacked.unchecked.out.actual
    (run ./crossingPacked.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossingPacked.out crossingPacked.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    crossingPacked.optimized.checked.out.actual
    (run ./crossingPacked.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossingPacked.out crossingPacked.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    crossingPacked.optimized.unchecked.out.actual
    (run ./crossingPacked.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/crossingPacked.out crossingPacked.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/deepFrames))
 (targets deepFrames.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build deepFrames.exe "--fixed-region" "2097152" --package fixtures/deepFrames)))

(rule
 (deps (source_tree fixtures/deepFrames))
 (targets deepFrames.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build deepFrames.optimized.exe --optimize "--fixed-region" "2097152" --package fixtures/deepFrames)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    deepFrames.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./deepFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/deepFrames.out deepFrames.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    deepFrames.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./deepFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/deepFrames.out deepFrames.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    deepFrames.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./deepFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/deepFrames.out deepFrames.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    deepFrames.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./deepFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/deepFrames.out deepFrames.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    defaults.checked.out.actual
    (run ./defaults.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    defaults.unchecked.out.actual
    (run ./defaults.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    defaults.optimized.checked.out.actual
    (run ./defaults.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    defaults.optimized.unchecked.out.actual
    (run ./defaults.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/defaults.out defaults.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/doubling))
 (targets doubling.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build doubling.exe --package fixtures/doubling)))

(rule
 (deps (source_tree fixtures/doubling))
 (targets doubling.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build doubling.optimized.exe --optimize --package fixtures/doubling)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    doubling.checked.out.actual
    (run ./doubling.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/doubling.out doubling.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    doubling.unchecked.out.actual
    (run ./doubling.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/doubling.out doubling.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    doubling.optimized.checked.out.actual
    (run ./doubling.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/doubling.out doubling.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    doubling.optimized.unchecked.out.actual
    (run ./doubling.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/doubling.out doubling.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryArray))
 (targets entryArray.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryArray.exe --package fixtures/entryArray)))

(rule
 (deps (source_tree fixtures/entryArray))
 (targets entryArray.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryArray.optimized.exe --optimize --package fixtures/entryArray)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryArray.checked.out.actual
    (run ./entryArray.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArray.out entryArray.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryArray.unchecked.out.actual
    (run ./entryArray.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArray.out entryArray.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryArray.optimized.checked.out.actual
    (run ./entryArray.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArray.out entryArray.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryArray.optimized.unchecked.out.actual
    (run ./entryArray.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArray.out entryArray.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryArrayConstant))
 (targets entryArrayConstant.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryArrayConstant.exe --package fixtures/entryArrayConstant)))

(rule
 (deps (source_tree fixtures/entryArrayConstant))
 (targets entryArrayConstant.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryArrayConstant.optimized.exe --optimize --package fixtures/entryArrayConstant)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryArrayConstant.checked.out.actual
    (run ./entryArrayConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArrayConstant.out entryArrayConstant.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryArrayConstant.unchecked.out.actual
    (run ./entryArrayConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArrayConstant.out entryArrayConstant.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryArrayConstant.optimized.checked.out.actual
    (run ./entryArrayConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArrayConstant.out entryArrayConstant.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryArrayConstant.optimized.unchecked.out.actual
    (run ./entryArrayConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryArrayConstant.out entryArrayConstant.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryString))
 (targets entryString.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryString.exe --package fixtures/entryString)))

(rule
 (deps (source_tree fixtures/entryString))
 (targets entryString.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryString.optimized.exe --optimize --package fixtures/entryString)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryString.checked.out.actual
    (run ./entryString.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryString.out entryString.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryString.unchecked.out.actual
    (run ./entryString.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryString.out entryString.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryString.optimized.checked.out.actual
    (run ./entryString.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryString.out entryString.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryString.optimized.unchecked.out.actual
    (run ./entryString.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryString.out entryString.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryStringConstant))
 (targets entryStringConstant.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStringConstant.exe --package fixtures/entryStringConstant)))

(rule
 (deps (source_tree fixtures/entryStringConstant))
 (targets entryStringConstant.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStringConstant.optimized.exe --optimize --package fixtures/entryStringConstant)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStringConstant.checked.out.actual
    (run ./entryStringConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStringConstant.out entryStringConstant.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStringConstant.unchecked.out.actual
    (run ./entryStringConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStringConstant.out entryStringConstant.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStringConstant.optimized.checked.out.actual
    (run ./entryStringConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStringConstant.out entryStringConstant.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStringConstant.optimized.unchecked.out.actual
    (run ./entryStringConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStringConstant.out entryStringConstant.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryStruct))
 (targets entryStruct.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStruct.exe --package fixtures/entryStruct)))

(rule
 (deps (source_tree fixtures/entryStruct))
 (targets entryStruct.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStruct.optimized.exe --optimize --package fixtures/entryStruct)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStruct.checked.out.actual
    (run ./entryStruct.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStruct.out entryStruct.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStruct.unchecked.out.actual
    (run ./entryStruct.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStruct.out entryStruct.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStruct.optimized.checked.out.actual
    (run ./entryStruct.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStruct.out entryStruct.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStruct.optimized.unchecked.out.actual
    (run ./entryStruct.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStruct.out entryStruct.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryStructConstant))
 (targets entryStructConstant.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStructConstant.exe --package fixtures/entryStructConstant)))

(rule
 (deps (source_tree fixtures/entryStructConstant))
 (targets entryStructConstant.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryStructConstant.optimized.exe --optimize --package fixtures/entryStructConstant)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStructConstant.checked.out.actual
    (run ./entryStructConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStructConstant.out entryStructConstant.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStructConstant.unchecked.out.actual
    (run ./entryStructConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStructConstant.out entryStructConstant.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryStructConstant.optimized.checked.out.actual
    (run ./entryStructConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStructConstant.out entryStructConstant.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryStructConstant.optimized.unchecked.out.actual
    (run ./entryStructConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryStructConstant.out entryStructConstant.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryUnit))
 (targets entryUnit.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryUnit.exe --package fixtures/entryUnit)))

(rule
 (deps (source_tree fixtures/entryUnit))
 (targets entryUnit.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryUnit.optimized.exe --optimize --package fixtures/entryUnit)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryUnit.checked.out.actual
    (run ./entryUnit.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnit.out entryUnit.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryUnit.unchecked.out.actual
    (run ./entryUnit.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnit.out entryUnit.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryUnit.optimized.checked.out.actual
    (run ./entryUnit.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnit.out entryUnit.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryUnit.optimized.unchecked.out.actual
    (run ./entryUnit.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnit.out entryUnit.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryUnitConstant))
 (targets entryUnitConstant.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryUnitConstant.exe --package fixtures/entryUnitConstant)))

(rule
 (deps (source_tree fixtures/entryUnitConstant))
 (targets entryUnitConstant.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryUnitConstant.optimized.exe --optimize --package fixtures/entryUnitConstant)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryUnitConstant.checked.out.actual
    (run ./entryUnitConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnitConstant.out entryUnitConstant.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryUnitConstant.unchecked.out.actual
    (run ./entryUnitConstant.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnitConstant.out entryUnitConstant.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryUnitConstant.optimized.checked.out.actual
    (run ./entryUnitConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnitConstant.out entryUnitConstant.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryUnitConstant.optimized.unchecked.out.actual
    (run ./entryUnitConstant.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryUnitConstant.out entryUnitConstant.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/entryWide))
 (targets entryWide.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryWide.exe --package fixtures/entryWide)))

(rule
 (deps (source_tree fixtures/entryWide))
 (targets entryWide.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build entryWide.optimized.exe --optimize --package fixtures/entryWide)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryWide.checked.out.actual
    (run ./entryWide.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryWide.out entryWide.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryWide.unchecked.out.actual
    (run ./entryWide.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryWide.out entryWide.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    entryWide.optimized.checked.out.actual
    (run ./entryWide.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryWide.out entryWide.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    entryWide.optimized.unchecked.out.actual
    (run ./entryWide.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/entryWide.out entryWide.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    folding.checked.out.actual
    (run ./folding.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    folding.unchecked.out.actual
    (run ./folding.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    folding.optimized.checked.out.actual
    (run ./folding.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    folding.optimized.unchecked.out.actual
    (run ./folding.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/folding.out folding.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/frames))
 (targets frames.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build frames.exe --package fixtures/frames)))

(rule
 (deps (source_tree fixtures/frames))
 (targets frames.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build frames.optimized.exe --optimize --package fixtures/frames)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    frames.checked.out.actual
    (run ./frames.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/frames.out frames.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    frames.unchecked.out.actual
    (run ./frames.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/frames.out frames.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    frames.optimized.checked.out.actual
    (run ./frames.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/frames.out frames.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    frames.optimized.unchecked.out.actual
    (run ./frames.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/frames.out frames.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/headers))
 (targets headers.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build headers.exe --package fixtures/headers)))

(rule
 (deps (source_tree fixtures/headers))
 (targets headers.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build headers.optimized.exe --optimize --package fixtures/headers)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    headers.checked.out.actual
    (run ./headers.exe "6")))))

(rule
 (alias runtest)
 (action
  (diff golden/headers.out headers.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    headers.unchecked.out.actual
    (run ./headers.exe "6")))))

(rule
 (alias runtest)
 (action
  (diff golden/headers.out headers.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    headers.optimized.checked.out.actual
    (run ./headers.optimized.exe "6")))))

(rule
 (alias runtest)
 (action
  (diff golden/headers.out headers.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    headers.optimized.unchecked.out.actual
    (run ./headers.optimized.exe "6")))))

(rule
 (alias runtest)
 (action
  (diff golden/headers.out headers.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    hello.checked.out.actual
    (run ./hello.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    hello.unchecked.out.actual
    (run ./hello.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    hello.optimized.checked.out.actual
    (run ./hello.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    hello.optimized.unchecked.out.actual
    (run ./hello.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/keeping))
 (action
  (with-stdout-to
   keeping.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/keeping))))

(rule
 (alias runtest)
 (action
  (diff golden/keeping.cgt keeping.cgt.actual)))

(rule
 (deps (source_tree fixtures/keeping))
 (targets keeping.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build keeping.exe --package fixtures/keeping)))

(rule
 (deps (source_tree fixtures/keeping))
 (targets keeping.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build keeping.optimized.exe --optimize --package fixtures/keeping)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    keeping.checked.out.actual
    (run ./keeping.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/keeping.out keeping.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    keeping.unchecked.out.actual
    (run ./keeping.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/keeping.out keeping.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    keeping.optimized.checked.out.actual
    (run ./keeping.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/keeping.out keeping.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    keeping.optimized.unchecked.out.actual
    (run ./keeping.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/keeping.out keeping.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    lambdas.checked.out.actual
    (run ./lambdas.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    lambdas.unchecked.out.actual
    (run ./lambdas.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    lambdas.optimized.checked.out.actual
    (run ./lambdas.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    lambdas.optimized.unchecked.out.actual
    (run ./lambdas.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lambdas.out lambdas.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    lists.checked.out.actual
    (run ./lists.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    lists.unchecked.out.actual
    (run ./lists.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    lists.optimized.checked.out.actual
    (run ./lists.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    lists.optimized.unchecked.out.actual
    (run ./lists.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/longChain))
 (targets longChain.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build longChain.exe --package fixtures/longChain)))

(rule
 (deps (source_tree fixtures/longChain))
 (targets longChain.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build longChain.optimized.exe --optimize --package fixtures/longChain)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    longChain.checked.out.actual
    (run ./longChain.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/longChain.out longChain.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    longChain.unchecked.out.actual
    (run ./longChain.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/longChain.out longChain.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    longChain.optimized.checked.out.actual
    (run ./longChain.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/longChain.out longChain.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    longChain.optimized.unchecked.out.actual
    (run ./longChain.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/longChain.out longChain.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/math))
 (action
  (with-stdout-to
   math.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/math))))

(rule
 (alias runtest)
 (action
  (diff golden/math.optimized.cgt math.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/math))
 (targets math.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build math.exe --package fixtures/math)))

(rule
 (deps (source_tree fixtures/math))
 (targets math.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build math.optimized.exe --optimize --package fixtures/math)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    math.checked.out.actual
    (run ./math.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/math.out math.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    math.unchecked.out.actual
    (run ./math.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/math.out math.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    math.optimized.checked.out.actual
    (run ./math.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/math.out math.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    math.optimized.unchecked.out.actual
    (run ./math.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/math.out math.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    operators.checked.out.actual
    (run ./operators.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    operators.unchecked.out.actual
    (run ./operators.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    operators.optimized.checked.out.actual
    (run ./operators.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    operators.optimized.unchecked.out.actual
    (run ./operators.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/operators.out operators.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    outcomes.checked.out.actual
    (run ./outcomes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    outcomes.unchecked.out.actual
    (run ./outcomes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    outcomes.optimized.checked.out.actual
    (run ./outcomes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    outcomes.optimized.unchecked.out.actual
    (run ./outcomes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    owners.checked.out.actual
    (run ./owners.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    owners.unchecked.out.actual
    (run ./owners.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    owners.optimized.checked.out.actual
    (run ./owners.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    owners.optimized.unchecked.out.actual
    (run ./owners.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/owners.out owners.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    probed.checked.out.actual
    (run ./probed.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    probed.unchecked.out.actual
    (run ./probed.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    probed.optimized.checked.out.actual
    (run ./probed.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    probed.optimized.unchecked.out.actual
    (run ./probed.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/probed.out probed.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    range.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./range.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    range.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./range.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    range.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./range.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    range.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./range.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/range.out range.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/rangeZero))
 (targets rangeZero.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build rangeZero.exe --package fixtures/rangeZero)))

(rule
 (deps (source_tree fixtures/rangeZero))
 (targets rangeZero.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build rangeZero.optimized.exe --optimize --package fixtures/rangeZero)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    rangeZero.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./rangeZero.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/rangeZero.out rangeZero.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    rangeZero.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./rangeZero.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/rangeZero.out rangeZero.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    rangeZero.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./rangeZero.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/rangeZero.out rangeZero.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    rangeZero.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./rangeZero.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/rangeZero.out rangeZero.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/recursion))
 (targets recursion.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build recursion.exe --package fixtures/recursion)))

(rule
 (deps (source_tree fixtures/recursion))
 (targets recursion.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build recursion.optimized.exe --optimize --package fixtures/recursion)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    recursion.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./recursion.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/recursion.out recursion.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    recursion.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./recursion.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/recursion.out recursion.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    recursion.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./recursion.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/recursion.out recursion.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    recursion.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./recursion.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/recursion.out recursion.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    references.checked.out.actual
    (run ./references.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    references.unchecked.out.actual
    (run ./references.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    references.optimized.checked.out.actual
    (run ./references.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    references.optimized.unchecked.out.actual
    (run ./references.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/references.out references.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    regions.checked.out.actual
    (run ./regions.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    regions.unchecked.out.actual
    (run ./regions.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    regions.optimized.checked.out.actual
    (run ./regions.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    regions.optimized.unchecked.out.actual
    (run ./regions.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/regions.out regions.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/removal))
 (targets removal.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removal.exe --package fixtures/removal)))

(rule
 (deps (source_tree fixtures/removal))
 (targets removal.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removal.optimized.exe --optimize --package fixtures/removal)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    removal.checked.out.actual
    (run ./removal.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removal.out removal.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    removal.unchecked.out.actual
    (run ./removal.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removal.out removal.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    removal.optimized.checked.out.actual
    (run ./removal.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removal.out removal.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    removal.optimized.unchecked.out.actual
    (run ./removal.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removal.out removal.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/removalFolded))
 (action
  (with-stdout-to
   removalFolded.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/removalFolded))))

(rule
 (alias runtest)
 (action
  (diff golden/removalFolded.optimized.cgt removalFolded.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/removalFolded))
 (targets removalFolded.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removalFolded.exe --package fixtures/removalFolded)))

(rule
 (deps (source_tree fixtures/removalFolded))
 (targets removalFolded.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removalFolded.optimized.exe --optimize --package fixtures/removalFolded)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    removalFolded.checked.out.actual
    (run ./removalFolded.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removalFolded.out removalFolded.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    removalFolded.unchecked.out.actual
    (run ./removalFolded.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removalFolded.out removalFolded.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    removalFolded.optimized.checked.out.actual
    (run ./removalFolded.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removalFolded.out removalFolded.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    removalFolded.optimized.unchecked.out.actual
    (run ./removalFolded.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/removalFolded.out removalFolded.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/removeRange))
 (targets removeRange.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removeRange.exe --package fixtures/removeRange)))

(rule
 (deps (source_tree fixtures/removeRange))
 (targets removeRange.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build removeRange.optimized.exe --optimize --package fixtures/removeRange)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    removeRange.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./removeRange.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/removeRange.out removeRange.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    removeRange.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./removeRange.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/removeRange.out removeRange.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    removeRange.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./removeRange.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/removeRange.out removeRange.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    removeRange.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./removeRange.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/removeRange.out removeRange.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    replayed.checked.out.actual
    (run ./replayed.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    replayed.unchecked.out.actual
    (run ./replayed.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    replayed.optimized.checked.out.actual
    (run ./replayed.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    replayed.optimized.unchecked.out.actual
    (run ./replayed.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/replayed.out replayed.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/runs))
 (action
  (with-stdout-to
   runs.optimized.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --optimize --package fixtures/runs))))

(rule
 (alias runtest)
 (action
  (diff golden/runs.optimized.cgt runs.optimized.cgt.actual)))

(rule
 (deps (source_tree fixtures/runs))
 (targets runs.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build runs.exe --package fixtures/runs)))

(rule
 (deps (source_tree fixtures/runs))
 (targets runs.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build runs.optimized.exe --optimize --package fixtures/runs)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    runs.checked.out.actual
    (run ./runs.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/runs.out runs.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    runs.unchecked.out.actual
    (run ./runs.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/runs.out runs.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    runs.optimized.checked.out.actual
    (run ./runs.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/runs.out runs.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    runs.optimized.unchecked.out.actual
    (run ./runs.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/runs.out runs.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    scalarTexts.checked.out.actual
    (run ./scalarTexts.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    scalarTexts.unchecked.out.actual
    (run ./scalarTexts.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    scalarTexts.optimized.checked.out.actual
    (run ./scalarTexts.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    scalarTexts.optimized.unchecked.out.actual
    (run ./scalarTexts.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalarTexts.out scalarTexts.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    scalars.checked.out.actual
    (run ./scalars.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    scalars.unchecked.out.actual
    (run ./scalars.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    scalars.optimized.checked.out.actual
    (run ./scalars.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    scalars.optimized.unchecked.out.actual
    (run ./scalars.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/scalars.out scalars.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    settled.checked.out.actual
    (run ./settled.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    settled.unchecked.out.actual
    (run ./settled.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    settled.optimized.checked.out.actual
    (run ./settled.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    settled.optimized.unchecked.out.actual
    (run ./settled.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/settled.out settled.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    shapes.checked.out.actual
    (run ./shapes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    shapes.unchecked.out.actual
    (run ./shapes.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    shapes.optimized.checked.out.actual
    (run ./shapes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    shapes.optimized.unchecked.out.actual
    (run ./shapes.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    spawned.checked.out.actual
    (run ./spawned.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    spawned.unchecked.out.actual
    (run ./spawned.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    spawned.optimized.checked.out.actual
    (run ./spawned.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    spawned.optimized.unchecked.out.actual
    (run ./spawned.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawned.out spawned.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/spawnedFrames))
 (targets spawnedFrames.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawnedFrames.exe "--spawned-fixed-region" "2097152" --package fixtures/spawnedFrames)))

(rule
 (deps (source_tree fixtures/spawnedFrames))
 (targets spawnedFrames.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build spawnedFrames.optimized.exe --optimize "--spawned-fixed-region" "2097152" --package fixtures/spawnedFrames)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    spawnedFrames.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./spawnedFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/spawnedFrames.out spawnedFrames.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    spawnedFrames.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./spawnedFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/spawnedFrames.out spawnedFrames.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    spawnedFrames.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./spawnedFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/spawnedFrames.out spawnedFrames.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    spawnedFrames.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./spawnedFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/spawnedFrames.out spawnedFrames.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    spawns.checked.out.actual
    (run ./spawns.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    spawns.unchecked.out.actual
    (run ./spawns.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    spawns.optimized.checked.out.actual
    (run ./spawns.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    spawns.optimized.unchecked.out.actual
    (run ./spawns.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/stringArrays))
 (targets stringArrays.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build stringArrays.exe --package fixtures/stringArrays)))

(rule
 (deps (source_tree fixtures/stringArrays))
 (targets stringArrays.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build stringArrays.optimized.exe --optimize --package fixtures/stringArrays)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    stringArrays.checked.out.actual
    (run ./stringArrays.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/stringArrays.out stringArrays.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    stringArrays.unchecked.out.actual
    (run ./stringArrays.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/stringArrays.out stringArrays.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    stringArrays.optimized.checked.out.actual
    (run ./stringArrays.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/stringArrays.out stringArrays.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    stringArrays.optimized.unchecked.out.actual
    (run ./stringArrays.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/stringArrays.out stringArrays.optimized.unchecked.out.actual)))

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
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    texts.checked.out.actual
    (run ./texts.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    texts.unchecked.out.actual
    (run ./texts.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    texts.optimized.checked.out.actual
    (run ./texts.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    texts.optimized.unchecked.out.actual
    (run ./texts.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/walks))
 (targets walks.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build walks.exe --package fixtures/walks)))

(rule
 (deps (source_tree fixtures/walks))
 (targets walks.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build walks.optimized.exe --optimize --package fixtures/walks)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    walks.checked.out.actual
    (run ./walks.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/walks.out walks.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    walks.unchecked.out.actual
    (run ./walks.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/walks.out walks.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-stdout-to
    walks.optimized.checked.out.actual
    (run ./walks.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/walks.out walks.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-stdout-to
    walks.optimized.unchecked.out.actual
    (run ./walks.optimized.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/walks.out walks.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/wideFrames))
 (targets wideFrames.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build wideFrames.exe "--fixed-region" "2097152" --package fixtures/wideFrames)))

(rule
 (deps (source_tree fixtures/wideFrames))
 (targets wideFrames.optimized.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build wideFrames.optimized.exe --optimize "--fixed-region" "2097152" --package fixtures/wideFrames)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    wideFrames.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./wideFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/wideFrames.out wideFrames.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    wideFrames.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./wideFrames.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/wideFrames.out wideFrames.unchecked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   1
   (with-outputs-to
    wideFrames.optimized.checked.out.actual
    (with-accepted-exit-codes
     1
     (run ./wideFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/wideFrames.out wideFrames.optimized.checked.out.actual)))

(rule
 (action
  (setenv
   ZANE_CHECK
   0
   (with-outputs-to
    wideFrames.optimized.unchecked.out.actual
    (with-accepted-exit-codes
     1
     (run ./wideFrames.optimized.exe))))))

(rule
 (alias runtest)
 (action
  (diff golden/wideFrames.out wideFrames.optimized.unchecked.out.actual)))

(rule
 (deps (source_tree fixtures/reject/beyondLimit))
 (action
  (with-stderr-to
   reject.beyondLimit.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/beyondLimit)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.beyondLimit.err reject.beyondLimit.err.actual)))

(rule
 (deps (source_tree fixtures/reject/hugeArray))
 (action
  (with-stderr-to
   reject.hugeArray.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/hugeArray)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.hugeArray.err reject.hugeArray.err.actual)))

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
 (deps (source_tree fixtures/reject/nestedArray))
 (action
  (with-stderr-to
   reject.nestedArray.err.actual
   (with-accepted-exit-codes
    1
    (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/reject/nestedArray)))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.nestedArray.err reject.nestedArray.err.actual)))

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

