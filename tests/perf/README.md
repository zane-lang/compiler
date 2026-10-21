# Perf tests

`log/` is the other half: one large program whose estimated cycles CI logs
for every commit on `main` and holds pull requests to
([`log/README.md`](log/README.md)). The programs here are held one by one,
to exact counts.

How much work each program's optimized build does, counted rather than
timed. `run` builds each directory here with `--optimize`, runs it once
under Valgrind's Callgrind with the size in its `arguments` file, and holds
it to `golden/NAME.out`, what it printed, and `golden/NAME.counts`, the
instructions and conditional branches it executed. A count is the same on
every run and every machine that builds with the devbox's toolchain, so a
change in the code the compiler emits shows here as a change in a count,
where a timing would hide it in noise.

Only the program's own instructions are held: its code and the runtime
linked into it. The C library's and the dynamic loader's are shown in the
`libraries` column and held to nothing, since the C library picks its
`memcpy` and string functions by the processor it runs on. A count may move
by 0.1% of its golden value either way; one that moves further fails the
run, down as well as up, so the golden files keep up with the compiler.

Counts measure work, not speed: a program that executes fewer instructions
can still run slower on a given processor. A count that moves says the
emitted code changed, and the diff and a timing on real hardware say whether
for the better.

```sh
devbox run -- just test-perf                # check every program
devbox run -- tests/perf/run flips trees    # check these
devbox run -- just promote-perf             # write the golden files from this build
```

Valgrind runs on Linux only. When a change moves a count, read the table
`run` prints, satisfy yourself that the change is the one intended, and
promote; the counts diff then records the change. To see where the
instructions went, build the program with `--optimize` and run
`valgrind --tool=callgrind --dump-instr=yes` on it.

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
  ordered and swapping removals; its ordered removals' `memmove` is the C
  library's work, in the `libraries` column.
