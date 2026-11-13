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
  so the object holds nothing for it. Its lambda-variable `double` has a
  type C can call, so the object also defines its adapter and C entry
  (docs/design/ffi.md F11), which call into the runtime for a context when
  C calls `double` on a thread of its own. The body of its generic verb
  `same` holds a lambda of such a type too, lifted with each instance, so
  that lambda's adapter and C entry are shared, as the instance is.
- `atlas` is a library package that uses `geometry` as another library
  package of the same project, built with it into one object. What both
  declare is exported under the `!` placeholder, an instance of geometry's
  generic at atlas's own type included.

  atlas is also built with a stamp of its own while geometry has none, so
  geometry is compiled into atlas's object rather than left to one of its
  own: `golden/atlas.stamped-root.symbols` shows what atlas reaches in
  geometry local to the object.
- `survey` is a program that uses `geometry` from an object geometry was
  built into on its own, with its stamp. Survey's object writes out
  geometry's verbs whose body is one expression and calls the rest, among
  them `shifted`, which takes and returns a struct, calls through
  `double`, which carries geometry's C entry before its code, makes the instances of
  geometry's generic that it needs, at survey's own type and at the type a
  verb it takes in uses, with the adapter and C entry of the lambda in it,
  which merge with geometry's, and its own copy of the geometry constant it reads, which
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
- `doubling` is a program of 24 verbs, each calling the one below it
  twice. `optimization_test.py` checks that an unoptimized build keeps the
  upper levels as calls rather than inlining 2^24 copies of the first.
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
It also checks that the runtime's functions are declared with the
attributes `lib/codegen/runtime_facts.ml` gives them, in a plain build and
after an optimized one links the runtime's bodies, that the runtime's small
list operations are made in line,
that the cell `drop` removes and discards, which owns no block, is held in
no scope, and
that in `quiet`'s optimized build LLVM leaves no index check in `sweep`'s
loop, then runs each program, optimized and not. `culls` is a program whose
`main` removes, in order, from a list of scalar structs and from a list of
strings: the scalar list's moves carry the scalar tag and, in the optimized
build, its loop keeps the count in a register, and the string list's moves
carry none. `pushes` is a program whose `gather` pushes four
scalars in a row onto a list of its own: each element it moves in carries
the scalar tag. `fills` is a program whose counted loop pushes once each
time round through a verb whose body is that push, as `core`'s `push` is:
its optimized build makes room for the whole loop with one
`zane_list_room` before it, and the loop that may return keeps its pushes.
`cases` is a program whose `deaths` tests each element of
a list of packed optional `Int`s, one-byte tag and payload: in the
optimized build that test is a `select`, with no branch on the tag around
the payload's load. `escapes` is a program with two counted loops that
return early: every build marks its arithmetic escape test to be unrolled
twice, and the optimized build unrolls it, while `first`'s loop, which
calls, is not marked. `walks` is a program whose loop calls `find`, a search
through a table it is given that returns from inside its own loop, which
the loop writes out while `main`'s call outside any loop calls it, and
`depth`, which calls itself, `spin`, given only a number, and `weighed`,
whose constructor's left-out default makes it too big, which stay calls;
each build prints the same. `taking` is a library whose `Text` constructor
copies the string it is given once into the value it makes, and `takes` a
program over it, built against `taking`'s object: the fresh string it
passes goes to a local copy of `Text` that takes it with no copy, the string
it reads again is copied, the instance of its generic `Held` constructor,
which the program shares, takes a fresh string the same way, `named` returns
its local by moving it out, and the library's object still defines `Text` as
compiled and exports no copy. `lookahead` is a program whose `scan` reads
records at indices loaded from another list and branches on each: its optimized
build prefetches 32 iterations ahead and its plain one does not, nor does
an optimized build with `ZANE_PREFETCH=0`; the early reads reach the index
list's 40 entries past the records' end, and its own end, without stopping
the program, while the loop's own read of a bad index still stops it.
`gathers` is the same loop with no branch, which no build prefetches.
`interleaves` looks keys up in a binary search tree, one search an
iteration, in loops an optimized build interleaves
(`lib/codegen/interleave.ml`): a sum, retired in any order, and a push, a
float sum and a store to `out[i]`, retired in iteration order, while a
search keyed by a running total, a write before the walk and a walk of the
list the loop pushes onto are left alone (`ZANE_INTERLEAVE_REPORT=1` says
which). Each build prints the same at counts below, at and above the 64
that interleaving needs, the float sum's bits included, and a chain with a
link out of range stops the program with the plain loop's message after
the same output.
`payloads` reads a list held in one case of a variant, only in that case's
arm and beside a call; holding the other case, it runs to the plain
build's answer, since no prefetch reads a list's handle through a variant's
payload.

`options_test.py` checks what `zanec` accepts for the options that name and
stamp packages. A package name in `--package NAME=DIR` or an `--import` key
is held to the lexer's identifier rule, so `bücher` and `_bücher` bind a
directory and key an import, while an uppercase first letter, a leading
digit, an empty name or a keyword does not. `--stamp` takes only a
well-formed stamp, and a malformed one is a usage error that writes no
object. Its packages are written to a temporary directory, so no file name
in the repository is Unicode.

`memo_test.py` checks calls remembered while the program runs
(docs/design/memoization.md). Its `memo` fixtures are programs, each built
plain, optimized and tiered (tier 1 loaded before `main`), with and without
`--no-memoize`, and each must print the same in all six. `fib`, `ttt` (a board array), `moves` (a variant) and
`constant` (which reads a package constant) repeat their arguments and get
one table each, and so does `zeros`, whose first call of 0 meets an empty
entry and must miss. `tree`, `phase` and `shallowin` mostly do not repeat them. `rejected` holds recursions that are
left alone: one that calls itself once, one that takes a `String`, and one
that prints. `spawning` runs `fib` from two spawned calls at once, which
share its table, as do the threads of `memolibraryuser`, a program that
spawns and calls `fib` in the object of `memolibrary`, a library.
`merged` makes the same call twice, so it gets none in any build, since an
optimizer makes the two calls one, and so does `inlined`, whose first call
is inside a verb written out where it is called, which always runs. `stepped` makes two calls that read the
same local, which a mutating call between them changes through its address,
so they count as two and it gets a table. `apart` makes the same call in two
blocks that may each run without the other, so it gets one too. Every build gives the same functions a
table, so the two tiers of a tiered build emit the same module, every
table starts on a cache line, and none holds more than 256 KiB.
