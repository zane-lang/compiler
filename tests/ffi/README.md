# C interface tests

Packages holding C code (spec `ffi.md`, docs/design/ffi.md). A directory
under `fixtures/` holding `.zn` files is one package, and any other is a
build of its subdirectories in name order, the first the root.
`golden/NAME.check` holds what `zanec --check` prints for a build it
accepts, `golden/NAME.tst` its typed tree, `golden/NAME.cgt` and
`golden/NAME.optimized.cgt` its code-generation trees, and
`golden/NAME.out` what it prints, built and run as tests/codegen builds
and runs a program: unoptimized, optimized and tiered, with drains checked
and unchecked. `golden/reject.NAME.err` holds what it reports for
`fixtures/reject/NAME`. A fixture's `flags` file, one
per line, is what it is built with besides.

| Fixture | What it shows |
|---|---|
| `calls` | Foreign verbs called, each crossing into C and back: integers, a narrow C integer, `F32`, `Bool` both ways, `Unit`, a string in and one out, an array, lent where it is so C sees one address for it given twice, a list, value types with and without padding, and C state kept between calls; and two packages whose C defines the same function, variable and alias names, each calling its own, one through a header that includes nothing, not even `<stdint.h>`, and a function each package's interface header defines itself; and C functions named `result` and `args`, which the glue's own names do not hide |
| `declarations` | Every declaration semantics accepts: a foreign verb of each boundary type (scalars and narrow C integers, `Bool`, `Unit`, a string in and out, an array, a list, C-compatible value types, among them a struct tag and a typedef of the same name, a function value), a handle whose `cType` is a bare struct tag, a data handle with a setter overwritten where it is settled, a capability from a foreign variable, one of them a weak C definition and one an alias, and an outside handle made, passed, and overwritten where it roams |
| `handles` | Handles at run time, each step's log printed once its scope has drained: a data handle written through a `mut` method and replaced through its setter where it is settled, one released where it roams and one dropped by the verb it moves into, a drain releasing a statement before the connection it was prepared on, a struct holding both overwritten whole with the statement's setter first, a list of handles with an element overwritten and the list replaced whole, handles made on and moved into spawned calls, a null result aborting a verb that declares it, a file opened, written and closed through a capability from a foreign variable, and a recursive verb reading outside state through a foreign variable of its own, which runs again rather than answering from a memoization table |
| `noObject` | A null result from a foreign verb that declares no abort, which stops the program |
| `vendored` | A `c.coda` whose rows apply in order: a `source` pattern over a vendored tree (skipping a file that is not C), an `include` directory, a `define`, and a `define` for another target that does not apply |
| `reject/handleForms` | A handle declared by `alias`, without `#`, with type parameters, or with entries it does not take |
| `reject/handleC` | A handle's `cType`, free function and setter checked against the interface headers, including a type only an included header declares |
| `reject/verbForms` | A generic foreign verb, a concept or block parameter, a marked parameter, a `&` result, and abort types where they are not allowed |
| `reject/interface` | Foreign verbs checked against their C declarations: missing, the wrong count, variadic, unprototyped, other C types, `long`, structs laid out differently or with a bit-field |
| `reject/windowsInt` | A typedef that is 64 bits on Linux and 32 on Windows, refused in the Windows build only |
| `reject/positions` | Handles where they may not stand, the wrong `const`, a capability returned, an outside handle made by a method that is not `mut`, a handle made both ways, and a constructor for a handle |
| `reject/variables` | Foreign variables of the wrong type, naming a missing, undefined, thread-local or differently typed global, and one outside the root |
| `reject/overwrite` | A settled handle without a setter overwritten directly, through a struct holding it, through `this`, and through seventeen nested generic structs, beside a reference to one rebound, which is no overwrite |
| `reject/absolute` | An absolute path in a row |
| `reject/badHeader` | A `c` table whose header is not `setting value target` |
| `reject/badSetting` | A setting that does not exist |
| `reject/cError` | A C source that does not compile, reported at its line |
| `reject/escapes` | Paths that leave the package's directory through `..`, each reported |
| `reject/headerError` | An interface header that does not compile, reported at its line |
| `reject/fixedMacro` | A `define` of a macro the fixed flags set |
| `reject/noMatch` | A `source` pattern that matches no file |
| `reject/linkerSet` | C placing globals in sections named as C identifiers, linker sets, each refused, beside one in a section that is not |
| `reject/assembly` | C holding assembly, an `__asm__` statement in a function and file-scope `__asm__`, each refused until F9 routes it as an object |
| `reject/notCoda` | A `c.coda` that is not Coda, reported where the parser stopped |
