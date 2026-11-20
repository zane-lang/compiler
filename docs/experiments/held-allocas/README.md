# Held allocas

Can LLVM keep every held local in registers by itself? A local the lowering
holds in its scope's arena (`Stat.Hold`, `Stat.Reserve`: an owner, or a value
that owns blocks, such as a `List`, a `String` or a struct holding one) lives
in its scope's frame today, because the runtime finds the arena a list grows
in from the address of the list's handle (`zane_region_at`). LLVM cannot keep
frame memory in registers, so `lib/codegen/frame_shadow.ml` copies frame
slots into allocas after the O2 passes, one recognised shape at a time.

The experiment passes the arena explicitly to the runtime calls that need it
on a held local, emits the held local as an alloca, and moves it back into
its frame slot after the O2 passes only where its address still escapes.

Switch: `ZANE_HELD_ALLOCAS=1` when compiling. The plan, with its decisions
D1–D7: <https://claude.ai/artifact/7vhahy9yzN6wecmLFoDi41>.

How to measure: `tests/perf/run [PROGRAM...]` under `pixi run`, once with the
switch unset and once with it set. Numbers are Callgrind's estimated cycles
(`tests/perf/README.md`), run with Valgrind 3.27.1 from the pixi
environment.

## Step 0: baseline

`main` at `15d7ede`, switch unset: every perf program, every build, in
[`baseline.txt`](baseline.txt). The programs the plan expects to move:

| program | optimized | tiered | plain |
| --- | ---: | ---: | ---: |
| subjects | 1,330,028,054 | 1,861,538,048 | 2,416,258,864 |
| tape | 13,119,424 | 13,464,720 | 34,032,835 |
| bits | 66,104,905 | 78,107,722 | 238,464,022 |
| paths | 26,195,352 | 28,031,603 | 88,436,123 |
| workers | 39,316,628 | 38,737,245 | 79,852,307 |
| refills | 34,136,961 | 36,838,870 | 101,588,778 |
| pushes | 18,549,957 | 18,829,034 | 44,966,761 |
