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
  same way.
