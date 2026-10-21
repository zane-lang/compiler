# Perf tests

How fast each program's optimized build runs, as estimated cycles from
Valgrind's simulators rather than as a timing, so the number is the same on
every run of one build. CI keeps every program's number for the last commit
on `main`, and the history of one of them, `stress`, for every commit, and
fails a pull request that makes a program slower.

## The number

`run` builds each directory here with `--optimize` and runs it once, with
the size in its `arguments` file, under Callgrind with the cache and branch
simulators on. It holds what the program printed to `golden/NAME.out`, so a
build that breaks a program is caught rather than measured. The caches are
fixed rather than read from the machine, so every machine simulates the same
ones: 32 KiB first-level instruction and data caches and an 8 MiB last-level
cache, each with 64-byte lines. From what the simulators count it estimates
cycles:

    instructions + 10 x first-level misses + 100 x last-level misses
                 + 20 x mispredicted branches

The weights are roughly what each costs on a current core. The whole process
is counted, the C library's work included. The result is an estimate for a
generic processor, not a time on any real one: it moves when the compiler's
code does more work, misses the cache more often or branches less
predictably. Runs of one build in different environments differ by a few
hundredths of a percent.

## The log and the check

The `perf-log` branch holds two files, both written by CI:

- `latest.tsv`, one row per program for the newest commit pushed to
  `main`: the program, the commit, its date in UTC, the estimated cycles,
  and the instructions, first-level misses, last-level misses and
  mispredicted branches they come from. Each push writes it over, so a
  commit that makes a program faster is what the next pull request is held
  to. A run that finishes after a later commit's keeps that commit's rows.
- `stress.tsv`, the `stress` program's row for every commit pushed to
  `main`, in date order. It starts at v0.14.

`.github/workflows/perf.yml` runs `.github/scripts/perf`:

- on a pull request, it measures every program and fails when one prints
  the wrong output, or when its estimated cycles are more than 1% above its
  row in `latest.tsv`. Labelling the pull request `perf-accepted` turns a
  slowdown into a warning, for a change that is slower on purpose, and the
  push to `main` then records the new numbers. Any label change measures
  again;
- on a push to `main`, it measures, writes `latest.tsv` and appends to
  `stress.tsv`;
- in the merge queue and on a manual run, it measures and compares, and
  fails only on a wrong output.

Every run but a push fails when it cannot read the branch, so a missing
baseline never passes as a comparison.

```sh
devbox run -- just test-perf              # every program against main's rows
devbox run -- tests/perf/run flips trees  # these alone, compared with nothing
devbox run -- just promote-perf           # write golden/ from this build's output
```

Valgrind runs on Linux only. To see where a change moved a number, compare
the columns `run` prints, then build the program with `--optimize` and run
`valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes --dump-instr=yes`
on it. A change to a program here changes what its row measures, so say so
in its pull request, label it `perf-accepted` if the number rises, and
promote its output if that changed.

## Programs

Each is written against `@primitives$` and `@operators$` only, so it measures
the compiler and its runtime, not `core`. Most port a program of the spec
repo's `langbench/` and print what it prints at the same size.

- `flips` is fannkuch-redux: small lists indexed, written and rotated in
  place in short loops, and a recursion that counts flips.
- `trees` is binary-trees: reference nodes that own their children, built,
  walked and dropped.
- `division` is trial division against a table a sieve builds: integer
  division by a divisor read from a list, and flags written at a stride.
- `floats` is the Mandelbrot set: floating-point arithmetic and comparison
  in nested loops, with an early return.
- `growth` is a list of four-field value structs pushed one at a time into a
  block that doubles.
- `copies` is a tree of value variants copied whole and summed.
- `texts` is numbers written as text, joined onto two lines and compared.
- `removal` is a list of value structs that grows by pushes and shrinks by
  ordered and swapping removals.
- `stress` is the logged one, a large program of sixteen sections:
  fannkuch-redux over small lists, binary-trees of reference nodes, trial
  division, the Mandelbrot set, bodies in a list pulled together, a list
  grown and one shrunk in order and by swapping, value trees copied whole,
  strings built and compared, a working set past the simulated last-level
  cache read at random, a matrix read by columns, quicksort and binary
  search over random numbers, an open-addressed hash table, a bytecode
  interpreter matching on variants, calls through function values chosen at
  random, and plain recursion. Its argument is how many times the sections
  run.
