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
  generic verb that it uses is shared. Its other generic verb has no instance,
  so the object holds nothing for it.
- `atlas` is a library that uses `geometry`, built with it into one object.
  What atlas declares is exported, and what it reaches in geometry is local,
  an instance of geometry's generic at atlas's own type included.
- `survey` is a program that uses `geometry` from an object geometry was
  built into on its own, with its stamp. Survey's object declares geometry's
  verbs and makes the instance of geometry's generic at survey's own type,
  the program links with geometry's object, and every check it makes prints
  `yes` when it holds.

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
