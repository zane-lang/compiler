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
`fixtures/reject/NAME`, checked, or built when the fixture holds a file
named `build`, for one refused only when it is built, and
`golden/reject.NAME.ll.err` what `zanec --ll` reports for one only
codegen refuses. `golden/NAME.released.out` holds what the fixture's root
prints linked against releases of its other packages, as `released`
builds them: each by `zanec --object`, its objects and its file of C
module hashes rewritten with a stamp as fetching rewrites them, and the
root built against them given those hashes, unoptimized and optimized, its
drains checked and unchecked. `golden/NAME.released.calls` holds what of
those packages the optimized build still calls, their thunks and their C
functions, having inlined the rest of the C it retained (docs/design/ffi.md
F13), and the same for hashes none of which agree. A fixture's `flags` file, one per line, is what it is
built with besides. A directory `NAME.archive` anywhere in a fixture
holds the C sources of the static library `NAME.a` beside it, which an
`archive` row names: the rules build it for the host with `archive`,
from `ZANE_CC` and `llvm-ar` (`AR` when set), and
`dev/bin/windows-programs` builds it for Windows in a copy of the
fixtures. One holding a file `target` is built for the triple the file
names, or, when it is empty, for an architecture other than the host's.
One holding a file `strip` has its objects stripped of the symbols no
relocation needs, by `llvm-strip` (`STRIP` when set).

| Fixture | What it shows |
|---|---|
| `calls` | Foreign verbs called, each crossing into C and back: integers, a narrow C integer, `F32`, `Bool` both ways, `Unit`, a string in and one out, an array, lent where it is so C sees one address for it given twice, a list, value types with and without padding, and C state kept between calls, which a recursive function reading it sees change, since a call to C keeps a function from being remembered; and two packages whose C defines the same function, variable and alias names, each calling its own, one through a header that includes nothing, not even `<stdint.h>`, a function each package's interface header defines itself, and functions, a variable, an alias and, on glibc, an indirect function a header defines with external linkage that a source including it defines too, each defined once though the glue includes the header as well, a constructor of that header's own, which no optimizer can run as it compiles it, run once, and one with external linkage, run once too, one setting up the header's private state, which a `static inline` function a thunk calls reads, directly, through a function of the header's it calls and through a pointer a variable of the header's holds, and private state of that header an external function of it sets, which a `static inline` function a thunk calls reads, one variable in the package as in the C alone, and constants of the header whose addresses the two compare, one a number, one pointing at another such constant and one at a string literal, a struct of that header an external function of it sets, and pointer variables of the header holding a `static` function of it and a constructor of it, which the glue compares with those functions, the constructor still running once, and constructors in an interface header no source includes, which run beside a source's own, one beside a source's of the same name doing the same that is not the header's; a `static inline` function of a header that selects glibc's GNU features before it includes a system header, which the glue includes before `<stdint.h>`; a C function taking the address of `atoi`, which `<stdlib.h>` may define `available_externally`, and C functions named `result` and `args`, which the glue's own names do not hide |
| `declarations` | Every declaration semantics accepts: a foreign verb of each boundary type (scalars and narrow C integers, `Bool`, `Unit`, a string in and out, an array, a list, C-compatible value types, among them a struct tag and a typedef of the same name and one holding each struct below it twice, 65,536 fields in all, a function value), a handle whose `cType` is a bare struct tag, a data handle with a setter overwritten where it is settled, a capability from a foreign variable, one of them a weak C definition and one an alias, and an outside handle made, passed, and overwritten where it roams |
| `handles` | Handles at run time, each step's log printed once its scope has drained: a data handle written through a `mut` method and replaced through its setter where it is settled, one released where it roams and one dropped by the verb it moves into, a drain releasing a statement before the connection it was prepared on, a struct holding both overwritten whole with the statement's setter first, a list of handles with an element overwritten and the list replaced whole, handles made on and moved into spawned calls, a null result aborting a verb that declares it, a file opened, written and closed through a capability from a foreign variable, and a recursive verb reading outside state through a foreign variable of its own, which runs again rather than answering from a memoization table |
| `functions` | Function values passed to C (F11): lambdas declared at package scope and written in place, called by C with numbers, a `Bool`, a value type holding an array, and no result; one writing the console; a comparison a C sort calls; one building a list, called on four threads C starts itself, each with an alternate signal stack of its own that it still has after the call; one calling into C with a lambda of its own; and the same values called from Zane, stored in a struct, and called through directly; value types of one `F32` field and of an array alone, which C passes as structs, and one holding a value type with no fields, C's empty struct, passed and returned through C; and lambdas taking a `Unit` or a value type holding itself, which C cannot call and which stay Zane functions |
| `assembly` | C holding assembly, each source assembled as an object of its own and renamed: file-scope `__asm__` defining `jump`, which jumps to a C function of another source and which a thunk and C both call, and `__asm__` statements in a function; an interface header that source includes defines a function, variables, one named by an `__asm__` label, and constructors, one local and one external, each defined, and each constructor run, once |
| `archives` | Two packages vendoring two versions of one C library, `tally`, as `archive` rows' static libraries defining the same names: each reaches its own version's function, alias and, on glibc, indirect function, its own callback into the package's C, its `system` row's `cbrt`, and its own function in file-scope assembly that jumps to a C function of another of its sources, and its own seed, a variable a header defines that only the glue compiles and a second member of the archive reads, also linked against a release of each package: its object and the one assembled from `hop.c`, written by `--object` and stamped, and its archive renamed from its source at the program's link, the release's C retained but for what its archives and assembled objects hold |
| `retained` | A dependency's C linked as a release and retained where its hashes agree: a pure function, one reading a `static const` table, and one reading what a constructor with external linkage counted, which runs once, inlined with every thunk; one counting in a `static` variable, one storing a `static const`'s address and one comparing it, and one in a source holding assembly, called, each printing what it prints compiled in |
| `noObject` | A null result from a foreign verb that declares no abort, which stops the program |
| `vendored` | A `c.coda` whose rows apply in order: a `source` pattern over a vendored tree (skipping a file that is not C), an `include` directory, a `define`, and a `define` for another target that does not apply |
| `reject/handleForms` | A handle declared by `alias`, without `#`, with type parameters, or with entries it does not take |
| `reject/handleC` | A handle's `cType`, free function and setter checked against the interface headers, including a type only an included header declares |
| `reject/verbForms` | A generic foreign verb, a concept or block parameter, a marked parameter, a `&` result, and abort types where they are not allowed |
| `reject/interface` | Foreign verbs checked against their C declarations: missing, the wrong count, variadic, unprototyped, other C types, `long`, structs laid out differently, aligned more strictly by `_Alignas` or with a bit-field, a list returned, and a function value whose C parameter or result is a narrow integer type |
| `reject/windowsInt` | A typedef that is 64 bits on Linux and 32 on Windows, refused in the Windows build only |
| `reject/positions` | Handles where they may not stand, the wrong `const`, a capability returned, an outside handle made by a method that is not `mut`, a handle made both ways, and a constructor for a handle |
| `reject/variables` | Foreign variables of the wrong type, naming a missing, undefined, thread-local, `const` or differently typed global, and one outside the root |
| `reject/views` | A header declaring its own `zane_bytes` and `zane_span`, laid out otherwise than `<zane_ffi.h>`'s, for a string result and a list parameter |
| `reject/overwrite` | A settled handle without a setter overwritten directly, through a struct holding it, through `this`, and through seventeen nested generic structs, beside a reference to one rebound, which is no overwrite |
| `reject/absolute` | An absolute path in a row |
| `reject/badHeader` | A `c` table whose header is not `setting value target` |
| `reject/badSetting` | A setting that does not exist |
| `reject/cError` | A C source that does not compile, reported at its line |
| `reject/escapes` | Paths that leave the package's directory through `..`, each reported |
| `reject/headerError` | An interface header that does not compile, reported at its line |
| `reject/fixedMacro` | A `define` of a macro the fixed flags set |
| `reject/noMatch` | A `source` pattern that matches no file |
| `reject/sharedState` | An interface header whose private state, which a `static inline` function the glue calls reads, two sources including it define, so the glue's copy can be neither's |
| `reject/assembledState` | An interface header whose private state, which a `static inline` function the glue calls reads, a source holding assembly, assembled apart, defines too, refused: its copy is in the source's own object |
| `reject/archivedConstructor` | An interface header running a constructor of its own whose definitions an `archive` row's member compiles too, refused: the archive does not say which of the header's constructors it runs |
| `reject/archivedHeaderConstructor` | An interface header of declarations, an inline function and a static constructor, included by an `archive` row's member that defines the variable the constructor sets, which the member's copy of the constructor was folded into, refused |
| `reject/archivedLibraryConstructor` | An interface header whose static constructor reaches only the C library, included by an `archive` row's member that shares nothing with the glue but runs a constructor of its own, refused: it may be the header's |
| `reject/archivedExternalConstructor` | `reject/archivedConstructor` with the constructor external, refused the same way |
| `reject/assembledConstant` | An interface header whose private constant, whose address the program can see, a source holding assembly, assembled apart, defines too, refused: the glue's copy would be told apart from the object's |
| `reject/archivedConstant` | The same constant held by an `archive` row's member that includes the header, refused the same way |
| `reject/assembledFunction` | An interface header whose private function, whose address the program can see, a source holding assembly, assembled apart, defines too, refused as the constant is |
| `reject/archivedFunction` | The same function held by an `archive` row's member that includes the header, refused the same way |
| `reject/archivedState` | An interface header whose private state, which a `static inline` function the glue calls reads, an `archive` row's member holds a copy of, refused: the glue cannot share it |
| `reject/archivedSplitState` | `reject/archivedState` with the member optimized, its copy of a private struct split into `state.0` and `state.1`, refused the same way |
| `reject/archivedStrippedState` | `reject/archivedState` with the member's local symbols stripped, so no name shows its copy of the state; it defines the header's external function, so it compiled the header, and is refused the same way |
| `reject/archiveDirective` | An `archive` row's member, a Windows object, asking the link through an `-include:` linker directive for a function another member defines, which the package renames and renaming cannot reach in the directive, refused when the package is checked |
| `reject/archiveExport` | An `archive` row's member, a Windows object, exporting the function it defines with `__declspec(dllexport)`, whose linker directive renaming cannot reach, refused when the package is checked |
| `reject/archiveLabel` | An `archive` row's member, a Mach-O object, defining a global symbol an `__asm__` label names without the `_` a C name takes there, which renaming cannot reach, refused when the package is checked |
| `reject/archiveTarget` | An `archive` row's library built for another architecture than the build's target, refused when the package is checked |
| `reject/linkerSet` | C placing globals in sections named as C identifiers, linker sets, each refused, beside one in a section that is not |
| `reject/objectLinkerSet` | Linker sets placed through objects: an archive's member placing data in `plugins` and file-scope assembly placing data in `zane_hooks`, each refused, beside a section of each that is not one |
| `reject/headerAssembly` | An interface header holding assembly, which reaches the glue and is refused |
| `reject/systemMissing` | A `system` row naming a library the linker cannot find, refused at the link by its row |
| `reject/notCoda` | A `c.coda` that is not Coda, reported where the parser stopped |
