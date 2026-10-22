# Tiered builds: an experiment

Whether a program can start as a plain build and finish as an optimized one,
so that the time from the command to its result, compile and run together,
is as short as it can be. Nothing here is part of the compiler's supported
interface; every switch is an environment variable.

- `ZANE_TIER=0` builds tier 0: the plain program, with each call between its
  own functions made through a slot (`lib/codegen/tiers.ml`), and its
  symbols exported so a shared object can use its runtime.
- `ZANE_TIER=1` builds tier 1: the optimized program, with a table of its
  functions under the keys tier 0's slots carry. `tier1.sh` links it as a
  shared object.
- `tier.c`, linked into tier 0 with `--link`, starts a thread that waits for
  the shared object named by `ZANE_TIER_UP`, loads it and fills each slot.
  A call already running finishes in tier 0; the next one runs tier 1.
- `ZANE_NO_FOLD` skips stage 5 in an optimized build, and `ZANE_LLVM_ARGS`
  passes options to LLVM, such as `-unroll-runtime=false`.

    cc -O2 -fPIC -c dev/tiering/tier.c -o dev/tiering/tier.o
    python3 dev/tiering/gen.py 400 /tmp/big400       # a generated program of 400 kernels
    python3 dev/tiering/measure.py /tmp/big400 300000 plain,o2nr,tier:o2nr

`measure.py` times each mode from the start of the compile to the program's
first line and to its exit, through a terminal so the first line is not held
in a buffer. A tiered mode builds both tiers at once and runs tier 0 as soon
as it is built.
