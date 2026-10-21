# Object tests

Libraries built into objects of their own
(docs/design/separate-compilation.md). Each fixture is one package.
`golden/NAME.cgt` is a library's code-generation tree, which shows each
function's linkage, and `golden/NAME.symbols` the symbols its object defines,
as `nm` lists them without their addresses: `T` for an exported function, `W`
for a shared one such as a generic instance, `t` for one local to the
object, and `U` for one another object defines. `golden/NAME.out` is what a
program linked from several objects wrote.

## Fixtures

- `geometry` is a library on its own. Every function it declares is exported
  under the `!` placeholder, private ones included, and the instance of its
  generic verb that it uses is shared, as are the function and variables of
  the package constant one of its verbs reads. Its other generic verb has no instance,
  so the object holds nothing for it.
- `atlas` is a library package that uses `geometry` as another library
  package of the same project, built with it into one object. What both
  declare is exported under the `!` placeholder, an instance of geometry's
  generic at atlas's own type included.

  atlas is also built with a stamp of its own while geometry has none, so
  geometry is compiled into atlas's object rather than left to one of its
  own: `golden/atlas.stamped-root.symbols` shows what atlas reaches in
  geometry local to the object.
- `survey` is a program that uses `geometry` from an object geometry was
  built into on its own, with its stamp. Survey's object inlines geometry's
  smallest verbs and calls the rest, makes the instances of geometry's
  generic that it needs, at survey's own type and at the type a verb it
  takes in uses, and its own copy of the geometry constant it reads, which
  merges with geometry's. The program links with geometry's object, and
  every check it makes prints `yes` when it holds.

  geometry's own placeholder object is also rewritten with that stamp, as
  fetching rewrites a release's objects. It must define exactly what the
  object built from source with the stamp does, and survey links with it the
  same way. geometry is rewritten the same way for macOS and Windows on
  x86-64 and ARM64, and held to the stamped build for each.
  `golden/geometry.macos-x86_64.symbols` and
  `golden/geometry.windows-x86_64.symbols` list two of those rewritten
  objects' symbols, showing the instance a weak definition on macOS and in a
  COMDAT on Windows.
- `versions` holds two versions of `geometry` whose `Point`s differ in
  layout, `atlas`, which uses the first, and `app`, a program that uses the
  second under the key `geo` and uses atlas. Each library is built into an
  object of its own with its stamp, and the program links all three. Every
  check it makes prints `yes` when it holds. `golden/versions.ambiguous` is
  the error for atlas's `import geometry` when nothing says which version it
  means.

  `geometry11` is a later release of the first version, laid out the same,
  and `remapped` a program that uses it and atlas. atlas's object is
  remapped from the first version onto `geometry11`, keeps no reference to
  the first, and links with `geometry11` alone.
- `crossing` is a library of verbs that take and return values of one, two
  and three pieces, whose signatures `abi_test.py` reads for each target and
  with `--pack-aggregates`. A library exports them, so each keeps its
  function even where an unoptimized build inlines it into its callers.
- `layout` is a project laid out in `lib/` and `bin/`: `math`, which `gui`
  and its subpackage `gui.opengl` share, `_shaders`, private to the project,
  and the program `viewer`. Every library package is built into one object,
  each exported by its path, as `!gui.opengl$frame()`, and once more with a
  stamp, as a dependency compiled from source is. `viewer` is built from
  source and against the stamped object, and prints `yes` both times.
  `golden/layout.noisy.err` is the error for a library package that reaches
  `@program$`, which no package of a library's build may, and
  `golden/layout.not-given.err` the errors for `gui.opengl` importing
  packages the driver gave it no keys for.

`optimization_test.py` checks optimized consumers of stamped objects. Its
`optimization` fixture exercises a folded loop, runtime arithmetic and
private helpers, a package constant, mutation, aborts, recursion and a named
lambda. It checks LLVM inlining and that imported ordinary functions have no
definitions in the caller's object, then compares optimized and unoptimized
program output while linking the same unoptimized dependency. It also runs
`survey` optimized and builds the two-version, transitive `versions` graph
with optimization enabled.

`facts_test.py` checks what codegen tells LLVM (docs/design/lowering.md §9,
"What LLVM is told"). Its `facts` fixtures are `cells`, a library whose
verbs write list elements through an owner and read them again; `quiet`, a
program over it that spawns nothing; `busy`, the same with one spawned
call; `pool`, a library that spawns; and `relay`, a program that spawns
nothing itself and calls `pool` as a stamped dependency. Only `quiet` reads
without snapshots: `busy`, `relay` and `cells` built as a library keep them.
It also checks that the runtime's small list operations are made in line,
that the cell `drop` removes and discards, which owns no block, is held in
no scope, and
that in `quiet`'s optimized build LLVM leaves no index check in `sweep`'s
loop, then runs each program, optimized and not.

`options_test.py` checks what `zanec` accepts for the options that name and
stamp packages. A package name in `--package NAME=DIR` or an `--import` key
is held to the lexer's identifier rule, so `bücher` and `_bücher` bind a
directory and key an import, while an uppercase first letter, a leading
digit, an empty name or a keyword does not. `--stamp` takes only a
well-formed stamp, and a malformed one is a usage error that writes no
object. Its packages are written to a temporary directory, so no file name
in the repository is Unicode.
