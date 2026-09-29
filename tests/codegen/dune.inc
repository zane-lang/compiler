; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

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
 (action
  (with-stdout-to
   boxes.out.actual
   (run ./boxes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/boxes.out boxes.out.actual)))

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
 (targets counting.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build counting.exe --package fixtures/counting)))

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
 (deps (source_tree fixtures/guests))
 (action
  (with-stdout-to
   guests.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/guests))))

(rule
 (alias runtest)
 (action
  (diff golden/guests.cgt guests.cgt.actual)))

(rule
 (deps (source_tree fixtures/guests))
 (targets guests.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build guests.exe --package fixtures/guests)))

(rule
 (action
  (with-stdout-to
   guests.out.actual
   (run ./guests.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/guests.out guests.out.actual)))

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
 (action
  (with-stdout-to
   hello.out.actual
   (run ./hello.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/hello.out hello.out.actual)))

(rule
 (deps (source_tree fixtures/hosts))
 (action
  (with-stdout-to
   hosts.cgt.actual
   (run %{exe:../../bin/zanec/zanec.exe} --cgt --package fixtures/hosts))))

(rule
 (alias runtest)
 (action
  (diff golden/hosts.cgt hosts.cgt.actual)))

(rule
 (deps (source_tree fixtures/hosts))
 (targets hosts.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build hosts.exe --package fixtures/hosts)))

(rule
 (action
  (with-stdout-to
   hosts.out.actual
   (run ./hosts.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/hosts.out hosts.out.actual)))

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
 (action
  (with-stdout-to
   lists.out.actual
   (run ./lists.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/lists.out lists.out.actual)))

(rule
 (deps (source_tree fixtures/operators))
 (targets operators.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build operators.exe --package fixtures/operators)))

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
 (action
  (with-stdout-to
   outcomes.out.actual
   (run ./outcomes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/outcomes.out outcomes.out.actual)))

(rule
 (deps (source_tree fixtures/range))
 (targets range.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build range.exe --package fixtures/range)))

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
 (deps (source_tree fixtures/regions))
 (targets regions.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build regions.exe --package fixtures/regions)))

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
 (action
  (with-stdout-to
   shapes.out.actual
   (run ./shapes.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/shapes.out shapes.out.actual)))

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
 (action
  (with-stdout-to
   spawns.out.actual
   (run ./spawns.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.out.actual)))

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
 (action
  (with-stdout-to
   texts.out.actual
   (run ./texts.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.out.actual)))

(rule
 (deps (source_tree fixtures/zero))
 (targets zero.exe)
 (action
  (run %{exe:../../bin/zanec/zanec.exe} --build zero.exe --package fixtures/zero)))

(rule
 (action
  (with-outputs-to
   zero.out.actual
   (with-accepted-exit-codes
    1
    (run ./zero.exe)))))

(rule
 (alias runtest)
 (action
  (diff golden/zero.out zero.out.actual)))

