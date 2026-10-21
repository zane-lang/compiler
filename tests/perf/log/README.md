# Performance log

How fast the compiler's code runs, commit by commit on `main`, as one
number: the estimated cycles of `stress/`, a large program that exercises
much of what the compiler emits. The program is measured under Valgrind, so
the number is the same on every run of one build. CI keeps the log and holds
pull requests to it.

## The number

`measure` builds `stress/` with `--optimize` and runs it once under
Callgrind with the cache and branch simulators on. The caches are fixed
rather than read from the machine, so every machine simulates the same ones:
32 KiB first-level instruction and data caches and an 8 MiB last-level
cache, each with 64-byte lines. From what the simulators count it estimates
cycles:

    instructions + 10 x first-level misses + 100 x last-level misses
                 + 20 x mispredicted branches

The weights are roughly what each costs on a current core. The whole process
is counted, the C library's work included. The result is an estimate for a
generic processor, not a time on any real one: it moves when the compiler's
code does more work, misses the cache more often or branches less
predictably. Before the number is taken, the program's output is held to
`stress.out`, so a build that breaks it is caught rather than measured.

`stress/` runs sixteen sections: fannkuch-redux over small lists,
binary-trees of reference nodes, trial division, the Mandelbrot set, bodies
in a list pulled together, a list grown and one shrunk in order and by
swapping, value trees copied whole, strings built and compared, a working
set past the simulated last-level cache read at random, a matrix read by
columns, quicksort and binary search over random numbers, an open-addressed
hash table, a bytecode interpreter matching on variants, calls through
function values chosen at random, and plain recursion. Its argument is how
many times the sections run.

## The log and the check

The log is `perf-log.tsv` on the `perf-log` branch, one row per commit
pushed to `main`: the commit, when it was measured, the estimated cycles,
and the instructions, first-level misses, last-level misses and mispredicted
branches they come from. `.github/workflows/perf-log.yml` runs
`.github/scripts/perf-log`:

- on a push to `main`, it measures and appends that commit's row;
- on a pull request, it measures and fails when the estimated cycles are
  more than 1% above the log's last row. Labelling the pull request
  `perf-accepted` turns the failure into a warning, for a change that is
  slower on purpose, and the next push to `main` logs the new number;
- in the merge queue and on a manual run, it measures and compares, and
  fails on nothing.

To see where a change moved the number, compare the columns of the two rows,
and the per-program counts of `tests/perf/` (`just test-perf`).

```sh
devbox run -- just perf-log            # this build against the log's last row
devbox run -- tests/perf/log/measure   # this build's numbers alone
```

A change that moves `stress/` itself changes what the log measures, so the
row after it is not comparable with the rows before; say so in its pull
request, label it `perf-accepted` if the number rises, and update
`stress.out` when the output changes.
