# LangArena under Callgrind

`run` measures the Zane port of LangArena (`zane/` in the LangArena
repository, built with `zane build`) one test at a time under Callgrind and
writes each test's instruction count to a TSV file. From the port's
directory:

```sh
/path/to/compiler/dev/bench/langarena/run out/host/zane ../run.js counts.tsv
/path/to/compiler/dev/bench/langarena/run out/host/zane ../run.js counts.tsv Maze::BFS Graph::BFS
```

A test's count is kept only when the run printed `NAME: OK` and exited 0.
Anything else is listed as `FAILED`, with what the test printed, and the
sweep exits 1. Counts once came from runs that had gone wrong: before the
runtime made a context's whole frame range usable up front under Valgrind
(`runtime/region.c`, `zane_reserve`), the three Maze tests crashed there
and Graph::BFS printed a wrong checksum, while natively all four were OK.
A count from such a run measures a different program.
