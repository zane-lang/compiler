# Perf tests

How fast each program runs, as estimated cycles from Valgrind's simulators
rather than as a timing, so the number is the same on every run of one
build. Each program is measured in three builds: `optimized`, built with
`--optimize`; `tiered`, as `zane run` builds it ([`tiers.md`](../../docs/design/tiers.md)),
run with tier 1 in place before `main` runs; and `plain`, the program
unoptimized, as `zane run` built it before tiers. CI keeps every build's
numbers of every program for the last commit on `main`, and the history of
one of them, `stress`, for every commit, and the merge queue fails a pull
request that makes any build of a program slower.

## The number

`run` builds each directory here three times, with `--optimize`, without it,
and tiered with its tier 1 beside it, and runs each build once, with the size in its `arguments` file, under
Callgrind with the cache and branch simulators on. It holds what each build
printed to `golden/NAME.out`, which the three share, so a build that breaks a
program is caught rather than measured. The caches are
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

The `perf-log` branch holds three files, all written by CI:

- `latest.tsv`, one row per program and build for the newest commit pushed
  to `main`: the program, the commit, its date in UTC, the estimated
  cycles, the instructions, first-level misses, last-level misses and
  mispredicted branches they come from, the build's key (below), and the
  build, `optimized`, `plain` or `tiered`. A row with no build is an optimized one,
  from before plain builds were measured. Each push writes it over, so a
  commit that makes a program faster is what the next pull request is held
  to. A run that finishes after a later commit's keeps that commit's rows.
- `stress.tsv`, the `stress` program's optimized row for every commit
  pushed to `main`, in date order. It starts at v0.14.
- `stress-plain.tsv` and `stress-tiered.tsv`, the same for its plain and
  tiered builds. Each starts at the first commit whose push measured that
  build.

`.github/workflows/perf.yml` runs `.github/scripts/perf` in the merge queue
and by hand, and `.github/workflows/perf-record.yml` runs it on each push to
`main`. On a pull request the check skips itself and passes, so the queue is
where a slowdown is caught:

- in the merge queue, it builds every build of every program, measures each
  one whose key is not its row's (below), and fails when one prints the
  wrong output, or when its estimated cycles are more than 1% above its row
  in `latest.tsv`; a build with no row passes. The queue measures the commit
  `main` will become, so pull requests queued together are checked
  together. When the last pull request queued in the group is labelled
  `perf-accepted`, a slowdown is a warning instead, for a change that is
  slower on purpose, and the push to `main` then records the new numbers. A
  pull request the queue removes for a slowdown can be labelled and queued
  again;
- on a push to `main`, it measures every build, writes `latest.tsv` and
  appends to the histories;
- on a manual run, it measures and compares, and fails only on a wrong
  output. Starting Perf by hand on a pull request's branch shows its numbers
  before it is queued.

A build's key hashes what its counts follow from: the executable
built, and a tiered build's tier-1 library, its `arguments`, what it printed, `run` itself, and Valgrind's
version and resolved path, which under Nix names the store path it was built
as. The executable holds the compiler's code and the runtime as clang built
and linked them, and names the C library it loads by its Nix store path, so
every input the build scripts use is in it without being listed.
In the merge queue, on a manual run and in `just test-perf`, a build is
not run again when it, taken with its golden output, has its row's key: it
reports its row's counts, since the same build run the same way counts the
same, and `run --fresh` measures it anyway. A push to `main` always measures
every build.

Every run but a push fails when it cannot read the branch, so a missing
baseline never passes as a comparison. The rows are measured on x86-64, so
on another machine `just test-perf` checks outputs and compares nothing.

```sh
pixi run just test-perf              # every program against main's rows
pixi run tests/perf/run flips trees  # these alone, compared with nothing
pixi run tests/perf/run --build plain  # one build of each program
pixi run just promote-perf           # write golden/ from this build's output
```

Valgrind runs on Linux only. To see where a change moved a number, compare
the columns `run` prints, then build the program as the slower build was
built, with or without `--optimize`, and run
`valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes --dump-instr=yes`
on it. A change to a program here changes what its row measures, so say so
in its pull request, label it `perf-accepted` before queueing it if the
number rises, and promote its output if that changed.

## Programs

Each is written against `@primitives$` and `@operators$` only, so it measures
the compiler and its runtime, not `core`. `stress`, `trees` and `copies` name some of their arithmetic
through one-line local functions such as `minus` and `below`, the shape of
`core`'s wrappers, so their plain builds measure how well it inlines them. Most port a program of the spec
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
- `returns` is results of three words returned from recursive calls:
  langbench's ntree, four-way trees whose nodes own a growable list of
  children, each node returned whole as its list's handle, and numbers
  summed by halves, each half returned as a struct of three integers.
- `kept` is a random generator held in a value struct, drawn from on
  both sides of a call the running program makes on another local. An
  optimized build works out both sets of draws while compiling, since the
  call is given no address of the generator, so its optimized number moves
  when folding forgets more than that call can write.
- `leaves` is a recursion whose arguments repeat only on its last level,
  where each call does least. A table of its results hits on half its
  calls, and must stop looking, since each hit saves less than the lookups
  cost ([`memoization.md`](../../docs/design/memoization.md) M3).
- `depths` is a recursion that calls itself once, called from a loop that
  asks for the same 500 depths over and over. A table of its results finds
  every call after the first pass, so its numbers rise sharply when a table
  stops being picked for such a recursion or its hits stop paying
  ([`memoization.md`](../../docs/design/memoization.md) M1).
- `repeats` is a heavy call in a loop that asks for the same 64 arguments
  over and over, with no recursion. A table of its results hits on all but
  the first 64 calls, so its numbers rise sharply when a table stops being
  picked for such a call or its hits stop paying
  ([`memoization.md`](../../docs/design/memoization.md) M1).
- `borrows` is two lists of floats in a struct, read through an `&`
  reference by a recursive function that stays out of line: one list on
  every pass of a loop, the other only on the passes a comparison picks. Its
  optimized and tiered numbers rise when the function is no longer told the
  reference's whole slot is there to read
  ([`lowering.md`](../../docs/design/lowering.md) §9), since it then reads
  the second list's count and block after each check, inside the loop.
- `scopes` measures short-lived lists, one to a call: each call pushes eight
  floats into a fresh list in a scope of its own and sums it, so its
  numbers rise when such a scope's block costs it a chunk again
  ([`lowering.md`](../../docs/design/lowering.md) §9).
- `removal` is a list of value structs that grows by pushes and shrinks by
  ordered and swapping removals.
- `particles` is a particle simulation over a list of value structs that mix
  four floats with an `alive` flag, so each struct has padding. Each step is
  sequential passes over the list: integrate, bounce off the walls and the
  floor, then kill the settled and respawn the dead from a generator.
- `tokens` is a tokenizer: a text of character codes generated from a seeded
  generator is scanned into a list of `{kind, start, length}` value structs
  whose kind is a variant, then a second pass matches on each kind to count
  them and sum their lengths.
- `entities` is an entity table with optional components: a list of value
  structs whose position, velocity and health are each a variant that is
  empty or holds a value. Movement, damage and a sweep run over the list
  every frame and act only on the entities that have the components they
  need.
- `paths` is an Option-heavy graph search: breadth-first search over a
  square grid with a quarter of its cells blocked, from random cells, with
  each cell's predecessor held in a variant that is empty until the cell is
  reached. Each query walks the predecessors back from a target, and the
  path lengths are summed.
- `stress` is the logged one, a large program of sixteen sections:
  fannkuch-redux over small lists, binary-trees of reference nodes, trial
  division, the Mandelbrot set, bodies in a list pulled together, a list
  grown and one shrunk in order and by swapping, value trees copied whole,
  strings built and compared, a working set past the simulated last-level
  cache read at random, a matrix read by columns, quicksort and binary
  search over random numbers, an open-addressed hash table, a bytecode
  interpreter matching on variants, calls through function values chosen at
  random, and plain recursion. Its argument is how many times the sections
  run, and each section is given the round it runs in, so a table of its
  results never finds a round it has seen. The round seeds a section's
  generator, or is added to its checksum: `bodies` starts its generator at
  7 plus the round, `removal` at 42, `scattered` at 3, `sorting` at 11,
  `hashing` at 5 and `calls` at 9. Nothing else varies, so every run does
  the same work and prints `golden/stress.out`.
