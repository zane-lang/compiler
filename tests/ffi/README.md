# C interface tests

Packages holding C code (spec `ffi.md`, docs/design/ffi.md), each directory
under `fixtures/` one package. `golden/NAME.check` holds what
`zanec --check` prints for a package it accepts, and
`golden/reject.NAME.err` what it reports for `fixtures/reject/NAME`.

| Fixture | What it shows |
|---|---|
| `vendored` | A `c.coda` whose rows apply in order: a `source` pattern over a vendored tree (skipping a file that is not C), an `include` directory, a `define`, and a `define` for another target that does not apply |
| `reject/absolute` | An absolute path in a row |
| `reject/badHeader` | A `c` table whose header is not `setting value target` |
| `reject/badSetting` | A setting that does not exist |
| `reject/cError` | A C source that does not compile, reported at its line |
| `reject/escapes` | Paths that leave the package's directory through `..`, each reported |
| `reject/headerError` | An interface header that does not compile, reported at its line |
| `reject/fixedMacro` | A `define` of a macro the fixed flags set |
| `reject/noMatch` | A `source` pattern that matches no file |
| `reject/notCoda` | A `c.coda` that is not Coda, reported where the parser stopped |
