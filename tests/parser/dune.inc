; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (with-stdout-to
  desugar.cst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --cst %{dep:fixtures/desugar.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/desugar.cst.spans desugar.cst.spans.actual)))

(rule
 (with-stdout-to
  desugar.cst.tree.actual
  (run %{exe:../../bin/zanec/zanec.exe} --cst %{dep:fixtures/desugar.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/desugar.cst.tree desugar.cst.tree.actual)))

(rule
 (with-stdout-to
  desugar.sst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --sst %{dep:fixtures/desugar.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/desugar.sst.spans desugar.sst.spans.actual)))

(rule
 (with-stdout-to
  desugar.sst.tree.actual
  (run %{exe:../../bin/zanec/zanec.exe} --sst %{dep:fixtures/desugar.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/desugar.sst.tree desugar.sst.tree.actual)))

(rule
 (with-stdout-to
  main.cst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --cst %{dep:fixtures/main.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/main.cst.spans main.cst.spans.actual)))

(rule
 (with-stdout-to
  main.sst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --sst %{dep:fixtures/main.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/main.sst.spans main.sst.spans.actual)))

(rule
 (with-stderr-to
  reject.bidi-061c.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/bidi-061c.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.bidi-061c.err reject.bidi-061c.err.actual)))

(rule
 (with-stderr-to
  reject.bidi-200e.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/bidi-200e.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.bidi-200e.err reject.bidi-200e.err.actual)))

(rule
 (with-stderr-to
  reject.bidi-200f.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/bidi-200f.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.bidi-200f.err reject.bidi-200f.err.actual)))

(rule
 (with-stderr-to
  reject.bidi-202e.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/bidi-202e.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.bidi-202e.err reject.bidi-202e.err.actual)))

(rule
 (with-stderr-to
  reject.bidi-2067.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/bidi-2067.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.bidi-2067.err reject.bidi-2067.err.actual)))

(rule
 (with-stderr-to
  reject.binder.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/binder.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.binder.err reject.binder.err.actual)))

(rule
 (with-stderr-to
  reject.control-escape.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/control-escape.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.control-escape.err reject.control-escape.err.actual)))

(rule
 (with-stderr-to
  reject.identifier.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/identifier.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.identifier.err reject.identifier.err.actual)))

(rule
 (with-stderr-to
  reject.lexing.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/lexing.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.lexing.err reject.lexing.err.actual)))

(rule
 (with-stderr-to
  reject.malformed-utf8.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/malformed-utf8.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.malformed-utf8.err reject.malformed-utf8.err.actual)))

(rule
 (with-stderr-to
  reject.rejected.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/rejected.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.rejected.err reject.rejected.err.actual)))

(rule
 (with-stderr-to
  reject.statement.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/statement.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.statement.err reject.statement.err.actual)))

(rule
 (with-stderr-to
  reject.syntax.err.actual
  (with-accepted-exit-codes
   1
   (run %{exe:../../bin/zanec/zanec.exe} %{dep:fixtures/reject/syntax.zn}))))

(rule
 (alias runtest)
 (action
  (diff golden/reject.syntax.err reject.syntax.err.actual)))

(rule
 (with-stdout-to
  utf8.cst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --cst %{dep:fixtures/utf8.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/utf8.cst.spans utf8.cst.spans.actual)))

(rule
 (with-stdout-to
  utf8.sst.spans.actual
  (run %{exe:../../tools/inspect/span_dump.exe} --sst %{dep:fixtures/utf8.zn})))

(rule
 (alias runtest)
 (action
  (diff golden/utf8.sst.spans utf8.sst.spans.actual)))

