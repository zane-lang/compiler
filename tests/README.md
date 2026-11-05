# Tests

One directory per thing tested. Each suite has a `just` recipe, and `just test`
runs the compiler, grammar, ambiguity-tool and grammar-generator suites. CI
runs the slower ones separately, so a change that cannot affect the grammar or
the ambiguity tools does not wait on them (`.github/scripts/ci-suites` decides
which).

## `just test-compiler`

The compiler itself.

- `dune runtest` holds the golden files in `parser/`, `semantics/`, `codegen/`,
  `ffi/`, `runtime/`, `objects/`, `unit/` and `nesting/`. The span files in
  `parser/golden/` and `semantics/golden/` are the only place a moved span or a
  rewrite that stopped happening shows up: the Python suites ask whether a
  file parses and what shape it parsed to, never where a node is or what the
  desugared or typed tree looks like. Read the diff, check that each moved
  span still covers what its node stands for, and accept it with
  `just promote`.
  - `unit/` tests the shared helpers directly, so a broken one is named rather
    than found in a diff.
  - `nesting/` holds `just check-nesting`'s count to small fixtures.
  - `ffi/` holds packages with C code ([`docs/design/ffi.md`](../docs/design/ffi.md)).
- `parser/syntax_test.py` checks parser acceptance.
- `tiers/` runs tiered builds ([`docs/design/tiers.md`](../docs/design/tiers.md))
  as `zane run` does: a program moving to tier 1 while it runs, the libraries
  the runtime refuses, and the cache.
- `memory-probes/run --check` holds each probe to its committed `NAME.out`. It
  fails on any difference, on a probe that failed to build, and on one whose
  optimized build differs, unless the probe's `EXPECTED` file permits it. To
  accept an intended change, run `tests/memory-probes/run` without `--check`
  and read the `git diff`.
- `memory-probes/reclaim.py --check` holds each allocating loop to the same
  peak RSS at 10,000 and 1,000,000 iterations, and its leaking control to
  clear growth.

## `just test-grammar`

The grammar's ambiguity regressions in `grammar/`: token sequences with a fixed
number of derivations, and the tree each unambiguous one groups to, plus the
conflict census that [`docs/ambiguity/proof-obligations.md`](../docs/ambiguity/proof-obligations.md)
keeps. Every check expands the grammar afresh, a few seconds per case, so this
is the slow suite.

## `just test-ambiguity-tools`

The ambiguity tools' own tests in `ambiguity/`: the search engine on small
grammars, the search CLI and its profiles, and the visible-stack proof's
checker. They say whether the tools are right, not whether the grammar is.

## `just test-grammar-generation` and `just test-highlighting`

`highlighting/` tests the generator that turns `grammar/` into the compiler's
and the editors' files. `test-grammar-generation` checks the committed
generated files are current and runs the generator's unit tests.
`test-highlighting` also runs the editor grammars against the compiler parser.
It needs `tests/highlighting/requirements.txt` and the pinned Tree-sitter CLI
(`npm ci --prefix editors/tree-sitter-zane`); the Typst and Neovim consumer
tests run when those executables are present.

## `just test-perf`

`perf/` holds programs timed under Valgrind, optimized and plain, and compared
with main's numbers on the `perf-log` branch. Linux only; see
[`perf/README.md`](perf/README.md). `just promote-perf` rewrites
`perf/golden/` for a new program or one whose output moved on purpose.

## `just test-windows`

The test programs built for Windows and run under Wine, as CI runs them on
Windows itself ([`docs/design/platforms.md`](../docs/design/platforms.md)).
Needs `zig` and `wine64`; set `RUNNER` to run them some other way.

## `just verify-grammar`

Not a suite here, but the grammar's machine-checked proof: the Lean checker in
`formal/` proves the parse relation `parser.mly` defines unambiguous, then
proves the GLR parser's relation unambiguous and maps it onto the source
grammar ([`docs/ambiguity/verification-roadmap.md`](../docs/ambiguity/verification-roadmap.md)).
Needs Lean (elan) besides Menhir, and takes about ten minutes.
