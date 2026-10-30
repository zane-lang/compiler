# The C interface: building, calling and folding C

> **Status: being built, in the order of §7.** Built: compiling a
> package's C (F1, F2, F3, F5) and reading its interface headers (F6), in
> `lib/foreign/` and `lib/c_interface/`; foreign verbs, handles and
> foreign variables in the grammar and semantics (F7); and calls of
> foreign verbs whose types are scalars, `Bool`, `Unit`, strings, arrays,
> lists, C-compatible value types and handles, through the glue (F8), with
> each package's C renamed (F9), linked into an optimized build (F13, the
> program's own packages) and compiled apart in an unoptimized or tiered
> one (F14); handles and foreign variables at run time (F12); function
> values as C functions (F11); and `c.coda`'s `archive` and `system`
> rows, with an archive's members and each source holding assembly
> renamed as objects (F4, F9), both reaching a program built against a
> release (F15); and release archives' hashes of their C modules, with
> a dependency's C retained for an optimized build to inline where they
> agree (F13, F15). The rest is
> designed and not yet built. This page says how the compiler implements the spec's C
> interface
> ([`ffi.md`](https://github.com/zane-lang/spec/blob/8ee0f38/spec/ffi.md)):
> compiling a package's C code, checking foreign verbs against it, calling
> it, and evaluating it at compile time. Each decision is numbered
> (**F1**…), and §7 lists the order they are built in.

The two documents divide the C interface between them. The spec states
everything a Zane program or a package's C code can rely on: what is
accepted, what a call does, which errors a build reports, and when a call is
evaluated at compile time. This page holds only how the compiler meets
that: mechanisms a user cannot observe, such as the clang it links, the
glue it generates, how it renames symbols and caches modules, and how it
evaluates C. A rule a user can observe belongs in the spec and is cited
here, never restated; a mechanism belongs here and nowhere in the spec.

Each mechanism below cites the spec section whose rule it implements, and
the rule itself is read there. Three of those sections shape the whole
design together: compiling C for the build's target (`ffi.md` §2.2),
checking foreign verbs as that target sees their declarations (§3.7), and
folding calls into C (§5.4), which means running C inside the compiler with
the target's meaning, not the host's. A fourth constraint is the compiler's
own: it implements no target's C calling convention by hand.

Every decision below follows from one choice: the compiler holds the C code
as LLVM IR, made by a clang of its own LLVM, in the same `LLVMContext` as the
Zane code it builds. Codegen links that IR into the package's module,
LLVM's pipeline optimizes the two languages together, and stage 5 reads the
same IR to evaluate it.

---

## 1. Compiling C

**F1. The C front end is a clang linked into `zanec`, of the compiler's own
LLVM.** The compiler already links LLD into itself
([`lowering.md`](lowering.md) §7, `lib/codegen/lld_stubs.cpp`) so that a
build never starts a second LLVM. It links clang's front end the same way,
in `lib/foreign/clang_stubs.cpp`, and runs a compilation in process: the
linked clang's own driver (`clang::driver::Driver`) turns a command line
for the target into a `clang::CompilerInvocation`, an `EmitLLVMOnlyAction`
runs it, and the `llvm::Module` it makes is written as bitcode, the form
the cache keeps it in (F3), which codegen reads into its own context.
Every front-end option is therefore one the linked clang made itself, so
all of them are ones it knows. The clang is `llvmPackages_19.libclang`, from
the nixpkgs revision `llvm_19` resolves to, so it links the same
`libLLVM`.

The clang has to be the compiler's own because LLVM IR crosses no LLVM
release. The released toolchain's `zig cc` is built on a newer LLVM than the
compiler's (19, `lowering.md` L2), and its bitcode would not load. So
the C compiler is asked only for what it knows that the linked clang does
not: where the target's C library headers are. The first build for a C
compiler and a target runs it once on an empty source with `-E -v` for the
build's target, so a cross build probes the target's headers, not the
host's. A clang or `zig cc`, which `--version` names, is given `--target=`.
A GCC builds for the one target it was configured for and takes no such
option, so it is run as it is and its `-dumpmachine` must name the build's
target, the host's when none is named, since the C is compiled for that
target either way. The two triples are normalized as LLVM normalizes one and
compared by architecture, operating system and environment, leaving out
the vendor, which normalizing keeps (`pc` stays, a missing one becomes
`unknown`) and which names no ABI on these targets, so `x86_64-linux-gnu`
and `x86_64-pc-linux-gnu` agree; one that names another is an error saying to set `ZANE_CC` to a GCC
for that target. The probe reads
the list after `#include <...> search starts here:`, which GCC, clang and
`zig cc` all print in that form; the list is kept in the cache, keyed by
the C compiler's command, the file it runs (a bare `gcc` names whichever
one `PATH` finds first), its `--version` output, the target, and the values
of the environment variables that change a C compiler's search
(`CPATH`, `C_INCLUDE_PATH` and `SDKROOT`), so changing any of them probes
again. Every
compilation passes it to the linked driver as `-nostdlibinc` followed by
one `-isystem` per directory, in order. An entry the list marks
`(framework directory)`, as clang prints the SDK's framework paths on
macOS, is passed as `-iframework` instead, so `<Foundation/Foundation.h>`
is found as the C compiler would find it. The C compiler's own builtin
headers are dropped from the list: the directory it names for
`-print-file-name=include`, which GCC and clang answer, and, for GCC, the
`include-fixed` beside it. `zig cc` answers that with a bare `include`, so
a directory holding clang's own `__stddef_max_align_t.h`, which no C library
ships, is taken for a builtin one too. Those hold its intrinsics and
`<stddef.h>`, written for its own builtins, so the linked clang reads its
own instead: they are embedded in the compiler, written once into the
cache directory, and named with `-resource-dir`, which `-nostdlibinc`
leaves searched. Nothing else the C compiler would do is replayed, so a GCC's `cc1` options or a newer clang's never reach the
linked one. `ZANE_CC` keeps its meaning: it names the C compiler that is
asked for the headers.

MSVC's `cl.exe`, and `clang-cl` in its mode, take no `-E -v` and print no
such list: they search the directories of the `INCLUDE` environment
variable, which a Visual Studio developer shell sets. A `ZANE_CC` whose
`--version` or `/?` names either is therefore not run for the list. Its
directories are read from `INCLUDE` in each build, never cached, split on
`;`, and passed the same
way, and a build that finds `INCLUDE` unset fails with an error saying to
run from a developer shell. The default `ZANE_CC`, `zig cc`, needs neither,
since it carries its own headers for every target.

**F2. Every C source is compiled with fixed flags first, then the package's
settings.** The fixed flags are `-std=c17`, `-ffp-contract=off`,
`-fno-fast-math`, `-fno-finite-math-only`, `-fno-associative-math` and
`-fno-rounding-math` (`ffi.md` §2.2), the target triple (the host's when the
build names none), `-isystem` for the directory holding `zane_ffi.h`, and
`-O2 -Xclang -disable-llvm-passes`, so the
module comes out of the front end unoptimized but optimizable: `-O0` would
mark every function `noinline`, which no later pipeline undoes, and F13's
inlining across the two languages would never happen. The package's
`include` and `define` rows come after, in the order its `c.coda` writes them
(`ffi.md` §2.3). A setting that names one of the fixed flags is an error
naming the row: a `define` of a macro those flags set, `__FAST_MATH__`,
`__FINITE_MATH_ONLY__`, `__ROUNDING_MATH__`, `__NO_MATH_ERRNO__`,
`__STDC__`, `__STDC_VERSION__` or `__STDC_HOSTED__`.

`zane_ffi.h` is embedded in the compiler like the runtime's headers
([`lowering.md`](lowering.md) §7) and written once into the cache directory.

**F3. One package's C is one module, cached by what it was made from.** Each
C source compiles to a module of its own, and the package's modules, with its
glue (F8), are linked into one with LLVM's linker. A source's module is kept
in the cache directory as bitcode of the compiler's own LLVM, under a hash of
the source's preprocessed text, with its line markers, the front-end
command, and the linked clang's full version, which is what makes the
module from them. The preprocessed text is what the
compilation reads, and its line markers name the file each line came from,
so the key changes with any header's contents, with which file an include
resolves to, and with what `__FILE__` expands to. Each build preprocesses
every source again, which costs a small part of compiling it, and a later
build whose source preprocesses to the same text loads the bitcode
instead. With no cache directory, every build compiles every source.

Two directories differ between machines without changing the code: the
package's own, wherever its checkout lies, and the cache directory, which
holds `zane_ffi.h` and the builtin headers (F1, F2). Each is mapped to a
fixed name, `/zane/pkg` and `/zane/cache`: `-ffile-prefix-map` makes
`__FILE__` and debug information spell them so, and the hash applies the
same mapping to the line markers and the front-end command. So the hash is the same for the same code wherever it
is built, which F13's comparison of a publisher's hash with a consumer's
relies on, and a path elsewhere, such as a system header's, still changes
it.

**F4. Archives and system libraries go to the link.** An `archive` row's
static library is read member by member with LLVM's archive reader
(`lib/foreign/object_stubs.cpp`) when the package's C is compiled, so a
check reports what a build would: a member for another architecture than
the build's target is refused there, naming the member, rather than at
the link. Each member is renamed (F9) and
written back as a static library by LLVM's archive writer
(`lib/codegen/archive_stubs.cpp`), in the kind the target's linker reads:
GNU's for ELF, Darwin's for Apple's targets and COFF's for Windows, with
a symbol table. The renamed libraries are passed to the link after every
object, the program's and its dependencies', so each member an object
uses is taken. A stamped dependency's archives reach the link of a
program built against its release this way too: they are read from its
source checkout and renamed with its stamped prefix (F15), so the members
match the C names its rewritten object defines and uses. A `system` row becomes a `-l` on the link command, in the
order the rows are written, after the program's objects and archives and
before the runtime and its libraries. A system library the target's C compiler cannot find is
an error naming the package and the row: the linker's own words for it,
`unable to find library -lX` from LLD, `library not found for -lX` from
`ld64` and `cannot find -lX` from GNU `ld`, are read from what the link
writes, and the error names the row of the `c.coda` that asks for the
library in their place.

**F5. `zanec` reads a package's `c.coda` itself.** The settings live in the
package's directory (`ffi.md` §2.3), beside the `.c` and `.h` files the
compiler already reads from each `--package` directory, so they need no flags
and nothing from the `zane` CLI. The compiler parses the file, keeps the rows
whose `target` pattern matches the build's target, expands `source` patterns
to the `.c` files they match (a `.h` or any other file a pattern matches is
not a C source and is skipped; a `*` matches within one directory name, as
`vendor/*.c` and `vendor/*/*.c` do), and checks that every path stays inside the
package's directory (`ffi.md` §2.3), which is the `--package` directory the
compiler was given. A path that leaves it, or a
`source` pattern that matches nothing, is an error naming the file and the
row.

---

## 2. Checking foreign verbs

**F6. Interface declarations are read from clang's AST, not parsed by the
compiler.** Each package's interface headers are compiled once more, with the
package's flags, each as a translation unit of its own that includes only
it, since two headers that are each valid need not be valid together (each
may define its own `static inline` helper, say), and `clang_stubs.cpp` walks
the ASTs. What it hands back is a table, by name, of
every function, variable, `struct` and `typedef` whose expansion location
is in an interface header (so a declaration a macro from an included header
writes, invoked in an interface header, is the interface header's): each variable's canonical type, whether it has
external linkage, whether it is thread-local, and whether it is `const`; each function's canonical parameter and result types,
`const` qualification of pointees, whether it is variadic, and whether it
has a prototype at all; each `struct`'s fields with their canonical types,
offsets, and bit widths where a field is a bit-field, and the record's size
and alignment from clang's `ASTRecordLayout`. A declaration that only an
included header makes is not in the table, which is how `ffi.md` §2.1's
"seen by the C compiler and by nothing else" holds.

The table travels from C++ as text, words with names written as their
length and bytes (`lib/foreign/interface.ml` reads it), so the stubs build
no OCaml values beyond a string. An integer type also carries the first of
`<stdint.h>`'s and `<stddef.h>`'s typedefs its sugar passes (`int64_t`,
`size_t`, …), since §3.3 names those as well as the builtin types, and on a
64-bit Linux target `int64_t` is canonically a `long`.

Stage 3 checks each foreign verb against that table by the rules of
`ffi.md` §3.3 and §3.7. A C type is matched by its canonical form, so a
`typedef` such as zlib's `uLong` is checked as the `unsigned long` it names,
unless it was written through one of those standard typedefs, which is
matched by that name.
An integer type's size is checked against its width in clang's target
information, which counts value bits, so a type with padding bits, whose
width is less than its size, matches no primitive, full-width or narrow
(`ffi.md` §3.3).
A type §3.3 refuses is reported with what it is on the target and a pointer
to the converting C function §3.3 asks for. A C-compatible value type is compared field by field against the
`struct`'s offsets and sizes, laid out as lowering lays the Zane type out
([`platforms.md`](platforms.md), "64-bit targets only"), and the two must
have the same size and alignment: a `struct` aligned more strictly than its
fields, as `_Alignas` makes one, is passed differently by C and would sit
in an under-aligned slot. Two forms are
refused outright, whatever their sizes say. A function declared without a
prototype, such as `int f();`, gives no parameter types to check, so a
foreign verb naming one is an error; the header has to write `int f(void);`
or the parameters. A `struct` with a bit-field can match a Zane field's
offset and size while holding fewer bits, so no `struct` with one
corresponds to a C-compatible value type (`ffi.md` §3.3's full-width fields
exclude it). A `zane_bytes` or `zane_span` is the one `<zane_ffi.h>`
declares (§3.4) only when its layout is: a `const` pointer to `uint8_t`, or
to `void`, at offset 0 and a `size_t` after it, and nothing else. The
toolchain puts `<zane_ffi.h>`'s directory on the include path but includes
nothing itself, so a header may declare a struct of the tag of its own,
and one laid out otherwise is refused. The check runs in
every build, so `zane check` reports what a build would.

**F7. The TST knows foreign verbs, handles and foreign variables.** The
grammar adds two keywords, `foreign` and `handle`. A foreign verb is a
function or method whose SST declaration carries its C symbol in a
`foreign` field, with an empty body over the `foreign` clause, so every
pass that handles a function or a method handles it, and pass 5 checks no
body. Its TST body is `Foreign { symbol; package; access; c_function }`:
the C function's type is its entry in the table (F6), and its capability
facts (`effects.md` §5.2) are not derived from a body but given by its
signature, as `ffi.md` §5.2's table states, in `access` (`Pure`, `Reads`
or `Writes`), which later stages read as they read a verb's derived ones.

A foreign handle is a type declaration whose definition is
`Handle { c_type; set; free }`, a reference type with no fields: it is
settled or roaming, moved and referenced, and destroyed, exactly like a
`#struct`. Its kind is `Capability` when it has no `free`. Otherwise it
waits until every package's signatures are known, then is read from the
foreign verbs that return the type, by `ffi.md` §4.2. Each check of §4.4
and §5.3 is then a test of the kind against the verb's signature, so none
of them needs to look past the declaration. All of this is
`lib/tst/passes/foreign_decls.ml`, the last step of pass 4, which reads
each package's table through `Env.interfaces` and writes the kinds and the
foreign verbs into pass 4's tables. The one rule that needs a place's
state, that a settled handle without a setter is never overwritten
(`ffi.md` §4.3), is in `references.ml` beside the other store rules.

A foreign variable desugars to a symbol declaration whose value is an SST
`Foreign_global` (desugaring.md §2.11), so a local or a package constant
carries it unchanged; pass 5 types that value as the declared type, a TST
`Foreign_global { symbol; package }` naming the package that declares the
capability's type, whose table gives the variable's linkage, thread-local
storage, `const` qualification and C type for the checks of `ffi.md` §5.1:
a `const` global is another C type than the capability's, whose `mut`
methods C receives a writable pointer for. Whether the package's
C code defines it is read from its compiled sources: F3's modules list the
variables they define with external linkage, which the table carries as
`defined`.

---

## 3. Calling C

**F8. Generated C does every call, so the compiler implements no C ABI.**
How a `struct` is passed by value differs between SysV x86-64, Windows x64
and AArch64, and LLVM leaves that classification to the front end. Rather
than reimplement clang's for each target, the compiler writes, for each
package, the glue: one C file per interface header, which includes that
header and is compiled with the package's settings, so clang does the
classification it already knows. The header comes first, so a feature-test
macro it defines, such as `_GNU_SOURCE`, selects what the system headers
declare as it does in a source including it first; `<stdint.h>` follows,
for the fixed-width types the thunks read slots as. After the includes, the file `#undef`s the
name of every C function its entries call, so a macro the header defines
with that name, such as `#define f(x) ((x) + 1)` after `int f(int);`,
never stands in for the function the foreign verb names. Each entry goes in the file of the header
that declares its C function. The glue holds:

- one **thunk** per foreign verb, with a pointer ABI codegen can call
  trivially:

  ```c
  void thunk(void *const *__zane_args, void *__zane_result) {
      *(int64_t *)__zane_result = zane_crc32(*(const int64_t *)__zane_args[0], *(const zane_bytes *)__zane_args[1]);
  }
  ```

  Every identifier the glue declares begins `__zane_`, a name C reserves
  to the implementation, so none hides a function the header declares,
  as a parameter `result` would hide a C function `result`. Each
  `__zane_args[i]` points to an argument already laid out as C lays out its
  type. The thunk does the conversions of `ffi.md` §3.3 as C casts: an
  `@primitives$I32` passed to a `uint8_t` keeps its low bits, a returned
  `int16_t` widens by its sign.
- one **free thunk** per foreign handle type with a free function, and one
  **set thunk** per type with a setter: thunks of the same pointer ABI,
  whose arguments are the objects' pointers, which call the free function
  with the one and the setter with the two. A library's object defines
  them for each of its handle types, since another object's ends and
  overwrites call them.
- for function values, the entries of F11.

A thunk's name is the foreign verb's symbol ([`symbols.md`](symbols.md))
with `.ffi` after it, a free or set thunk's is the handle type's symbol with
`.free` or `.set`, and F11's entries are named the same way from the lambda's
symbol, or by the object's package when other objects lift the lambda too,
given in C with an `__asm__` label, since a verb's
symbol is not a C identifier. Clang names a labelled function in IR `\01`
followed by the label, which LLVM emits as written, with no global prefix,
so the label is the symbol after the target's global prefix (`_` on macOS,
read from the target's data layout), and lowering declares each glue entry
under that same IR name, `@"\01_pkg.ffi"` on macOS, so a call and the
glue's definition are one function once the modules are linked. An optimized build links the glue into the
package's module (F13), where LLVM inlines each thunk into its caller, so an
optimized call into C is a direct call with the target's own convention.

**F9. A package's C globals are renamed before its module is linked.** Once a
package's C modules and glue are linked into one, every global value it
defines with external linkage, except the glue's thunks, is renamed
to the package's
symbol with `%c$` and its C name after it: `!zlib$%c$deflate` in a
library, `viewer$%c$deflate` in a program. Renaming a global in its module
renames its uses with it. The global values are the functions and
variables, and also the aliases and indirect functions that
`__attribute__((alias))` and `__attribute__((ifunc))` define, which
LLVM keeps as global values of their own: an alias exported under its
C name would meet the same alias from another version of the package.
An `available_externally` definition, such as the inline copy of `atoi`
glibc's `<stdlib.h>` can give, is not one the package defines: it stands
for the C library's symbol, keeps its name, and is never a definition that
leaves the glue's copy a declaration.
An alias's target and an indirect function's resolver are renamed by the
same rule when they are external, and keep their names when internal, as
any internal global does. The fetch-time rewrite then stamps the
placeholder like any other (`separate-compilation.md` C9). A name holding
`%c$` cannot be a Zane symbol, since no package name starts with `%`.
The glue's entries (F8, F11) keep their names, which lowering's calls
already use: they are derived from Zane symbols, so they carry the
package's placeholder and cannot meet another package's. They are found
by their labels, not as whatever the glue defines: a function an interface
header defines is compiled into the glue too, and is renamed as the
sources' functions are. A source that includes that header compiles the
same definition, so each glue module is linked after the sources with
every definition the modules before it already hold, a function's, a
variable's, an alias's or an indirect function's, made a declaration
(`zane_drop_defined`), and the package keeps one copy. Every object a
build emits, its C's included, places an ELF target's constructors and
destructors in `.init_array` and `.fini_array`, as clang does, since the
C library runs no `.ctors` (`zane_use_init_array`). A constructor or
destructor with external linkage is one of those definitions, and the
glue's list leaves it out when a module before the glue lists it itself,
so it runs once. A constructor or
destructor that header defines `static` is local to each copy, so the glue's is
left out of its list when a source that includes the header runs one of
the same name whose instructions use the same constants and globals. A
source's preprocessed text, read every build for its key (F3), names in
its line markers every file it includes, compared by real path, and the
source can hold only one local function of that name, the header's: the
constructor runs once, as it would for the C alone. One of a header no
source includes runs from the glue, even beside a source's own of the
same name.
The header's private objects, variables local to its translation unit
whose address the program can see, are one object each in the C alone,
which the header's functions share: state an external setter writes and a
`static inline` getter a thunk calls reads, or a constant whose address
both take. The glue's copy of each is the source's: before the link, each
private variable the glue defines that the one source including the
header defines too, by name and type, and for a constant with the same
value, is the source's. A constant's value may point at other objects of
the header's: it is the same when each pointed at is the other module's
copy, a private object by name and value, a string literal by content,
anything else by name; a struct type matches the other module's copy of
it field by field, as each module read names its own. A private function
whose address the glue takes, as comparing it with a pointer of the
header's does, is shared the same way, so the address the glue sees is
the one the source's pointers hold; one the glue only calls stays its own.
A constructor or destructor whose address is taken is shared so too, and
the glue's list no longer runs it, since the source's does, unless it sets
up private state the glue keeps a copy of. Such a variable or function
is the source's,
renamed `zane.shared.N.NAME` (`N` the source's place in the package)
and made visible to the link, with the glue's made a declaration of it
(`zane_share_state`); once the package's modules are linked it is local
again under its own name (`zane_localize_shared`). Within one
translation unit a variable at file scope, or a function's own `static`,
is one variable per name, so the source's of that name is the header's.
A string literal, or any other variable whose address LLVM may merge, is
none of these. A header whose writable private state the glue defines and
that two or more of the sources including it define too is refused, naming
them: C gives each of them a copy of its own, so none is the header's. A
constant several sources define has one value, so the glue keeps a copy of
its own, as C gives each source one. A header whose writable private
state a source assembled apart (below) defines is refused too, since that
copy is in an object of its own, which the glue's cannot share, and so is
one an archive's member holds a variable of its own of the same name as,
read from the member's local symbols: that member includes the header.
Each is compared by its C name, so a variable an `__asm__` label names is
compared by its label, as the header's external definitions are. A
local symbol named after it with a `.` suffix counts too, since an
optimized member's copy may be split or specialized into such pieces, as
`state.0` and `state.1` for the fields of a struct `state`. And a member
defining the header's external definitions, whose copies the glue drops
for its, compiled the header, so it is refused whatever its local symbols
say, as when an archive is stripped of the names no relocation needs.
Each holds for a private constant or function whose address the program
can see, a copy of which is told apart from it, as it does for writable
state; a function only called, or run from the constructor list, is not
one.
A constructor that sets up private state the glue keeps a copy of, which
a function the glue keeps reads, stays, itself, through a function of the
glue it calls or through a private variable's initializer, such as a
pointer to the state, since the source's copy sets up only the source's
state; so does one that calls through a pointer, or calls a function
something else calls too.
A source assembled apart, or an archive built from sources, that includes
the header defines the same copies outside the module: the glue's
definitions of every name the package's objects define are made
declarations too (`zane_drop_defined_apart`), a labelled one's matched by
its label, as an object names it, and an assembled source's
constructors are read from its module, as a linked source's are, so the
glue leaves out the ones its object runs; one with external linkage the
glue's copy of is a declaration so is left out of the glue's list too.
An archive says neither which of a header's constructors its members run
nor whether a member is linked, nor which headers a member includes. So
a header whose glue runs a constructor or destructor, local or external,
is refused when an archive could have compiled it too: when the archive
defines what the glue defines or uses, a labelled definition again read
by its label, or when a member runs constructors or destructors of its
own, from `.init_array`, `.ctors`, `__mod_init_func` or `.CRT$XC` and
their destructor sections. A header of declarations, inline functions and
a static constructor shares no definition with a member including it, and
the member's copy of the constructor may be folded into the initial
value of a variable it sets, which the glue's copy uses. With no source in the module,
the glue is linked into an empty module, so each glue module is still
linked after one.

An `archive` row's members are renamed through the object rewriter that
stamps placeholders (C9). The set of symbols the package's archives define
is read first, before the package's module is renamed, and joins the map:
each member is rewritten with it, and so is every declaration in the
package's module of a symbol an archive defines, such as a thunk's call of
a function an archive provides. So the module's references and the
archive's definitions carry the same new name, and neither can bind to a
symbol of that C name elsewhere. Undefined references, to the C library or
a `system` library, keep their names.

A C source whose module holds assembly takes the archive's route. Clang
keeps file-scope `__asm__` as the module's `module asm` text and a
function's `__asm__` statement as an inline-assembly string, and either
can define or name a symbol (`.globl foo`, `jmp foo`) that no global
value in the module stands for, so renaming the module's globals would
leave the assembly on the old name. Such a module is never linked into
the package's module. It is optimized with `-O2` and emitted as an object of its own
for the build's target and processor, as F14 emits C, when the package's
C is compiled, so a check holds its sections to the test below, and the
object is kept in the cache under how it is emitted, the module's key
(F3), the target and the processor. Once assembled, its definitions and references are
symbols like any object's: the symbols it defines join the map with the
archives' before the package's module is renamed, and the object is
rewritten with the map. Its functions are then called and never inlined
or folded, since no module that F13 or F16 reads holds their bodies.
Assembly that reaches the glue through an interface header has no such
route, since the glue is linked into the package's module, and is
refused with an error saying to move it into a C source.

The map holds every C name the package defines with external linkage:
those its module renames, which `zane_rename_c_globals` hands back, and
those its archives' members and assembled objects define, which renamed
the module's declarations of them first. Each maps from the name the
object spells, after the target's global prefix, to the one the module's
global takes, the prefix and the package's symbol and `%c$` before the C
name, so an object's definitions and references both move, and the
module's calls into an object and an object's into the module meet. The
rewriter renames each object's symbols in place
([`separate-compilation.md`](separate-compilation.md) C9), so the
objects' sections, relocations and code are the ones the archive or the
assembler made.

Section names are not renamed, so a linker set is refused (`ffi.md` §2.5).
Two versions that both place entries in a section named `plugins` would
share one `__start_plugins`/`__stop_plugins` range, and the boundary
symbols are undefined references, which keep their names. After F3 compiles
a module, any global it places in an explicit section whose name is a C
identifier, the only kind the linker makes `__start_`/`__stop_` symbols
for, is an error naming the package, the section and the global. The same
test is applied to the sections of an archive's members and of an object
assembled from a module holding assembly, as LLVM's object reader names
them, a Mach-O one as `SEGMENT,section`: an error naming the archive and
its member, or the source, and the section. A section whose name
is not a C identifier, such as `.text.hot` or `__DATA,__const`, is allowed.
A COFF object's linker directives, its `.drectve` section, are not
renamed either: one naming a symbol the package renames, whichever of
its sources, glue, archive members or assembled objects defines it, such
as the `/EXPORT:` that `__declspec(dllexport)` writes, or an `/INCLUDE:`
or `/ALTERNATENAME:`, would ask the link for the old name, so it is an
error naming the archive and its member, or the source, and the symbol.
So is a Mach-O global symbol without the `_` every C name takes there,
which an `__asm__` label or assembly can define: it has no C name to
rename it by, so two versions of the package would both define it.

**F10. A foreign call is one CGT node, with its arguments laid out for C.**
Lowering gives each foreign verb a Zane function whose body is one
`Foreign_call { thunk; args }`, and the program's list of thunks records
how each argument and the result cross: as a scalar, a `Bool`, a view, an
address, or a value. A call of the verb is a call of that function, which
an optimized build inlines. Codegen lowers each argument to a slot holding
its C layout, and the node passes the slots' addresses:

| Zane argument | Slot holds |
|---|---|
| scalar primitive | the scalar |
| `@primitives$Bool` | an `i8`, 0 or 1 |
| `@primitives$String` | a `zane_bytes`: the string's byte address and length, from its handle |
| `@primitives$Array<T, n>` | the address of the array, which already lays out as `T[n]` |
| `@primitives$List<T>` | a `zane_span`: the list's block address and count |
| C-compatible value type | the value, already in C's layout, with its padding bytes zeroed |
| a handle | its pointer |

A string, array or list is passed where it is, never copied going in:
`ffi.md` §3.4 and `memory.md` §2.9.1 together mean nothing writes it during
the call.

The result arrives in a slot of its C layout, and lowering makes the Zane
value from it. A `zane_bytes` result is copied into a new string in the
call's destination region through the runtime's string constructor, before
any other foreign call can run on this thread. A handle result is checked for
null (`ffi.md` §3.5): the abort lowers as any `Unit` abort does
([`lowering.md`](lowering.md) L12), and the stop prints "a foreign function
returned no object".

**F11. A function value of a C-compatible type is the address of a C
function.** C can call a function pointer and nothing else, and a C function
pointer carries no context, so a value that only Zane can call cannot be
handed to C. So every lambda whose type is C-compatible (`ffi.md` §3.6) is
lifted with three functions: its Zane function (L14); an **adapter**, a
Zane function of a thunk's pointer ABI that reads the arguments from their
slots, calls the Zane function and stores its result, named by the
lambda's symbol with `.adapter` after it; and a **C entry** in the glue,
named with `.c`, which takes the arguments with the C convention, hands
the adapter their addresses, a `Bool` as a byte, and returns what it
stores in a result slot whose padding bytes are zeroed, as F10's are. The
C types the entry takes and gives are read from the lambda's Zane type when
it is lowered, not from its CGT type: a value type of one field has its
field's CGT type, and C passes a struct of one `float` and a `float`
differently. The object that defines the lambda defines all three, after
lowering (`lib/cgt/callbacks.ml`), and the object's C entries
are a glue module of their own, compiled and linked as a package's glue is
(F9, F13, F14). A lambda several objects lift, as each that makes a
generic instance holding it does, has an entry of each object's own, named
by its package with `$entry` and the lambda's symbol after it, and an
adapter shared as the instance is, so that the linker keeps one.

A function value of a C-compatible type is its Zane function's address, as
any function value is, so a Zane call through it is a call through a
pointer to the Zane function and costs what any call through a function
value costs. C takes the C entry instead: the Zane function carries it in
its **prefix data**, the 32 bits LLVM places just before the function's
code, which hold the offset from the code of a constant of the same object
holding the entry's address, named by the entry's symbol with `.address`
after it. A call into C that passes a function value reads the offset, then
the constant, once per pass (`Emit.foreign_call`). An offset, not an
address, needs no relocation of the code where the program is
position-independent, and an offset to a variable the object defines,
rather than to the entry another object defines, is one every object format
can write: ELF, COFF and Mach-O, x86-64 Mach-O's included. Each object that
defines a lambda gives its definition the prefix, so the copy of a lambda
several objects define that the linker keeps points at an entry of its own
object. Tier 0's value of a function is the entry that calls through its
slot (`tiers.md` T4), which takes the prefix data with the function's
other uses; tier 1 defines no C entry, so its value of such a lambda is
tier 0's, read from its import table under the lambda's symbol with
`.tier.value` after it, and tier 1 calls its own copy only directly.

C may call a function value on a thread it started itself, which has no
context of the runtime's. The adapter reads the runtime's context of the
thread, `zane_self`, and when there is none has the runtime make one with
one scope for the call (`zane_callback_attach`) and give it back once the
call returns (`zane_callback_detach`): the result C takes is a
C-compatible value and holds no block. The runtime's alternate signal
stack, which its fault handler runs on, stands in for the thread's own for
the call, and the thread has its own back after. Both are cold, so an optimized C
entry is its lambda's body behind one load and one branch. A call on a
thread of the program runs in that thread's context, as any call does.
Stage 5 never folds the read: the value of a variable another object
defines is unknown to it.

The representation is fixed by the type alone, so it needs no analysis of
where a function value flows, and the two agree in every object
([`lowering.md`](lowering.md), "Fixed while compiling").

**F12. A handle is a pointer whose end calls its free thunk.** A handle's
CGT type is a pair of words: the C object's pointer and the 64-bit stamp
below, so the stamp travels with the handle wherever it is stored, in a
local, a field or a list element, and needs no slot of its own. C
receives only the pointer (F10). A handle type with a free function is a
position of its layout, as a string's handle is
([`lowering.md`](lowering.md) §9), naming its free and set thunks. Its end
calls the runtime's `zane_handle_end`, which calls the free thunk when the
pointer is not null and nulls it, so `ffi.md` §4.2's free runs exactly
once; a vacated place holds a null pointer, so a handle moved on is ended
only where it lands. Its copy and move do nothing: a handle is a
reference type and is never copied, and a C object never moves, so its
two words move with the value that holds them. A capability is no
position, since nothing frees a C global, and a foreign variable lowers
to the address of its global under the name F9 gives it, with a stamp of
0 that nothing reads.

An assignment to a settled or lent place whose value holds a handle that
is no variant's payload and no list's element is an `Overwrite` marked
`setters`, which calls the runtime's `zane_overwrite_settled`. That runs
the type's fifth walk, a settled overwrite, which is the overwrite except
at such a handle: there `zane_handle_set` takes the place's pointer and
the replacement's, and writes the place's pointer and stamp over the
replacement's before the replacement's bytes are copied in, so the place
keeps its stamp (below): handles made from the old object since hold the
same address, so they still end first. The replacement is dropped
without its `.end`, since the set thunk consumes it. A handle in a
payload or a list is ended and replaced, as a roaming owner's is.

A drain ends a scope's values with no order among them
([`lowering.md`](lowering.md) §9), but `ffi.md` §4.2 orders free functions.
So each handle a call makes is stamped as it is made with a number from
one process-wide counter, a 64-bit atomic fetch-and-add. Handles made by
spawned calls on different pool threads still get distinct, comparable
stamps, and a handle made from another is made after it in the program's
happens-before order, so its stamp is larger. A move keeps the stamp,
since the handle is the same one. A null pointer is stamped 0, which
lowering tests for the abort or stop of `ffi.md` §3.5.

A slot whose value may hold a handle is listed among its scope's held
slots whether or not drains are checked, and a scope holding one drains
through the runtime. The drain ends those slots, collecting each free
thunk with its handle's stamp, and once every slot has ended runs them by
descending stamp. An overwrite of a type that may hold a handle calls
`zane_overwrite_handles`, or `zane_overwrite_settled` when it is marked
`setters`, and either collects the thunks of the handles it ends or sets
the same way, so the set thunks of `ffi.md` §4.3 run by descending stamp
of the places, the order a drain frees them in, and a handle's old object
is released before the old object it was made from. Every other
overwrite calls `zane_overwrite`, which collects nothing.

---

## 4. Optimized and unoptimized builds

**F13. An optimized build links the C into the Zane module.** The package's
C module is linked into the module codegen makes for the package before
LLVM's `-O2` pipeline runs, so the pipeline inlines across the two
languages: a one-line Zane wrapper over a thunk over a small C function
becomes the C function's body at the call site. A dependency's C is
retained the way its Zane is (`separate-compilation.md` C12, and
[`optimization.md`](optimization.md) O10): compiled from the checkout to a
module (F3), linked with `available_externally` linkage so LLVM may inline it
and emits nothing for it, and defined in the dependency's own object. The
retained copy drops the module's `llvm.global_ctors`,
`llvm.global_dtors`, `llvm.used` and `llvm.compiler.used`: a C constructor
or destructor runs once, from the dependency's object, and an object marked
`used` or `retain` is emitted there, so linking any of those records in again
would run or emit it twice.

Two conditions keep a retained body the same code the dependency's object
runs:

- **It is the code the object was built from.** A release archive records,
  for each C source and for the package's glue (F8), the hash F3 keys its
  module by: the preprocessed text, the front-end command and the
  compiler's version (F15). The glue's files include every interface header between them, so
  its hash covers what the thunks were made from even for a package whose
  C is all in an archive or a system library, which has no C source to
  hash. The consumer
  computes the same hash for the module it rebuilds from the checkout, and
  retains that module only when the two agree. Where they differ, because
  the consumer's system headers, include directories or compiler differ from
  the publisher's, the dependency's C is called and never inlined or folded
(`ffi.md` §2.6).
  A `source` or path dependency is built by the consumer, so its modules
  always agree.

  The glue the consumer compares is the publisher's own: it is written
  for every foreign verb of the package and the free and set thunks of
  each of its handle types, as the package's library build lowers them,
  whichever of them the program reaches, and each file of it holds its
  thunks in the order of their labels, under the labels the hash file
  names, the publisher's `!` placeholder where its build had one. Once
  compiled, its thunks take the dependency's stamped names. Each source
  module and each glue module is retained on its own hash, and one whose
  hash differs is called.
- **It shares no state the object owns.** A retained function that reaches
  a C variable with internal linkage that is not `const`, or is `volatile`
  (a file-scope `static` counter, or a `static const volatile` status
  word), is not retained: a copy of the variable in the
  consumer would be a second variable, and the function's inlined and
  called forms would each see their own. Such a function, and everything
  that reaches it, is called. A `static const` table and a `static`
  function are copied only where nothing can tell the copy from the
  original, so never one placed in an explicit section, which the linker
  may gather into a table that would then hold both: their contents are read and the function is called, and their
  address is never returned, stored, compared, converted to an integer or
  passed on. A function that lets such an address out would give one
  address inlined and another called, so it is called, like one that
  reaches mutable state. A string literal's address, which LLVM may
  merge with another's, is copied freely.

A retained variable is a declaration, and so is a constant that holds a
`static` object's address, a weak definition another object may
override, an alias and an indirect function: only bodies nothing can
tell from the object's are copied. An optimized build links the retained
modules into the program's module after the program's own C, since LLVM's
linker takes an `available_externally` body only into a module that
already uses it. A build that compiles the C apart (F14) retains none.

**F14. An unoptimized build compiles the C apart.** `zane run` builds
unoptimized and answers to the time from the command to the result
([`optimization.md`](optimization.md) O12). C written to be compiled with
optimization is many times slower without it, and its module is cached
(F3), so an unoptimized build optimizes the package's C module on its own
with `-O2` and emits it as an object of its own, kept in the cache beside
the module, with the package's renamed archives and assembled objects
(F9) and a list naming them all, written last, so a later build takes
the whole set or compiles it again; the Zane module stays unoptimized and calls its thunks. A
tiered build's tier 0 links the C the same way, and tier 1 takes none of
it: tier 1 calls tier 0's thunks through its imports
([`tiers.md`](tiers.md) T5), so the program has one copy of its C's
state, as it has one of the runtime's, whichever tier is running.

**F15. A release archive holds a package build's object, C included, and
the objects of its sources holding assembly.** `--object OUT` writes the
package's object with its C linked in (F13 or F14), and beside it
`STEM.c.hashes`, `STEM` being `OUT` without its extension: for each of
the packages' C sources and glue modules, the hash F3 keys its module
by, which F13's first condition reads (`lib/foreign/hashes.ml`). It is a
Coda table, `c-hashes`, of the package as the object's symbols name it,
the package as its glue's labels name it, whether the module is a
`source` or `glue`, the source or interface header it was compiled from,
and the hash. `--rewrite` stamps the first column as it stamps the
objects, and leaves the labels as they are; a consumer names the
rewritten file with `--c-hashes`. An object holding no C module has no
such file, and one an earlier build wrote there is removed. Each
source holding assembly is an object of its own (F9), renamed with the
`!` placeholder as the package's object is, and `--object` writes these
beside `OUT` too, as `STEM.c.0.o`, `STEM.c.1.o` and so on, `STEM` being
`OUT` without its extension; one an earlier build wrote there under that
name is removed first. LLVM's linkers cannot join objects into one for
Apple's targets or Windows, so they stay apart: the release archive's
`build/` directory holds them all (`dependencies.md` §3.1), fetching
rewrites each (C9 of [`separate-compilation.md`](separate-compilation.md)),
and the consumer's link takes each with `--link`. An `archive` row's
library is part of the source checkout and is renamed at the consumer's
link (F4, F9). There they are renamed after the C names the
dependency's objects, the `--link` files, define with its stamped prefix:
exactly the names its own build renamed, its glue's among them, which its
archive's members use to reach the package's own C. Only the archives and
its `system` libraries reach the link.

---

## 5. Folding through C

**F16. Stage 5 evaluates C by interpreting its LLVM IR.** `lib/optimize/c_eval.ml`
runs a function of a package's C module, before LLVM has optimized it, with
the target's data layout. It is a second evaluator beside `eval.ml`, for a
second language: `eval.ml` models what a Zane program means and never where
its bytes are (O5), and C can tell where its bytes are, so `c_eval.ml`
models memory as bytes.

- **Memory** is a set of allocations, each a byte array with a size, an
  alignment and a record of which bytes have been written: one per
  `alloca`, one per global the module defines, made from its initializer,
  and one per `malloc`, `calloc` or `realloc`. A pointer is an allocation
  and an offset into it, and arithmetic on it keeps the allocation, so a
  pointer is never confused with an integer that happens to equal it. A
  `ptrtoint` gives an **address-derived integer**: it keeps the allocation
  and offset it came from, and arithmetic on it keeps them too. One
  narrower than a pointer, from a `ptrtoint` to a smaller integer or a
  `trunc`, stops the fold, since the bits it drops are the running
  address's and the evaluator has none to drop. An
  `inttoptr` of one gives the pointer back, and two derived from one
  allocation compare and subtract as their offsets do. Anything else that
  would let the address's number matter stops the fold: returning one,
  storing it where the Zane side reads it, comparing ones from two
  allocations, or branching, hashing or dividing on one. Where a program's
  allocations land is a fact of the running process, so no folded value
  may depend on it.
- **Instructions** are evaluated with LLVM's own meaning, and with the
  target's sizes: integer arithmetic at its width, with `nsw` and `nuw`
  overflow giving poison; IEEE float arithmetic as `eval.ml` does it, except
  for a NaN's bits. `eval.ml` makes every NaN one canonical NaN, which no
  Zane program can tell apart (O5), but C can read a float's bytes. So a NaN
  that C arithmetic makes is a NaN of unknown bits: computing with it
  folds, and reading its representation, by a `bitcast`, by loading its
  bytes as an integer, or by copying them where they are read so, stops the
  fold, since its sign and payload are the target machine's. A NaN written
  as bits, as a constant or by storing an integer, keeps the bits it was
  written with. A float instruction carrying any fast-math flag
  (`contract`, `reassoc`, `nnan`, `ninf`, `nsz`, `arcp`, `afn`) stops the
  fold: a `#pragma` in the source can set one despite F2's flags, and the
  optimized module may then fuse or reorder what the fold computed step by
  step; `getelementptr`
  with the target's offsets; `load` and `store`, except a `volatile` or
  atomic one, which stops the fold, as a `volatile` `memcpy`, `memmove` or
  `memset`, an `atomicrmw`, a `cmpxchg` and a `fence` do: a volatile access
  is one the program makes at run time, and an atomic one exists to be seen
  by another thread, which the fold cannot see;
  `phi`, `select`, `br`, `switch`; vectors elementwise; and the intrinsics clang emits with its LLVM passes disabled
  (`memcpy`, `memmove`, `memset`, the overflow, bit-count, funnel-shift,
  `abs`, `smin`/`smax` families, the exact float functions, `lifetime`,
  which does nothing, and `assume`, whose condition is evaluated: a false or
  poison one is undefined behavior and stops the fold, as the next item
  says, since the optimized module may treat that path as unreachable).
- **Calls** to a function the module defines are evaluated. A call to a
  function it only declares is evaluated when it is one of the C library's
  functions whose meaning is exact, which `c_eval.ml` models: `memcpy`,
  `memmove`, `memset`, `memcmp`, `memchr`, `strlen`, `strcmp`, `strncmp`,
  `malloc`, `calloc`, `realloc`, `free`, `abs`, `labs`, `llabs`. Any other is
  unknown, so the fold stops there, which is what keeps `sin` and its kin to
  the run time, as the Zane approximate functions are kept (O3).

  Two of these give less than an exact value, and are modelled as what C
  promises. `memcmp`, `strcmp` and `strncmp` promise only the sign of their
  result, so the evaluator's result is a **sign-only** integer: comparing it
  with zero folds, and anything else that would read its value (returning
  it, storing it where Zane reads it, arithmetic on it) stops the fold.
  `malloc`, `calloc` and `realloc` of a size of zero may or may not give a
  null pointer, so a fold that makes one stops. An allocation of any other
  size succeeds at compile time while it fits the budget (F19). A run that
  runs out of memory there is a run the program could have had and did not,
  as a spawned call's order is one of the orders it could have had (O8):
  the folded program computes what a run with the memory it needed
  computes, and a Zane program out of memory stops anyway
  ([`lowering.md`](lowering.md) §9). A `malloc` allocation's bytes start
  unwritten, so reading one before it is written stops the fold (next
  item); a `calloc` allocation's start written as zero, as C requires; and
  `realloc` keeps the written state of the bytes it carries over and leaves
  any it adds unwritten. A `calloc` whose count times size overflows
  `size_t` gives null, as every C library does for it, and the fold goes on
  with that null.
- **Undefined behavior stops the fold.** A read of a byte never written, an
  access outside an allocation or through a freed one, poison reaching a
  branch, a store or a call, a misaligned access, and a division by zero
  each stop evaluation and leave the call to run time, as an index out of
  range does in `eval.ml` (O6). C code with undefined behavior has no
  meaning the spec defines, so leaving it to run is never wrong, and folding
  it might be.

The IR evaluated is the IR the program runs, before the pipeline has
optimized it. Code without undefined behavior means the same before and
after optimization, and F2's fixed flags take away the two freedoms that
would let a float result differ between them: contraction into a fused
operation and reassociation. So a folded call gives what the run would
(`ffi.md` §5.4).

**F17. A foreign call is classed by its signature.** The table of
[`optimization.md`](optimization.md) O3 gains a row:

| Foreign call | Class |
|---|---|
| touching no capability, its C body in the build | computed, by `c_eval.ml` |
| touching no capability, its C in an archive or a system library | input |
| reading a capability | input |
| writing a capability | input, and left in place |

A write through a capability is not replayed the way a `print` is (O4): the
evaluator cannot know what C would have written, so the call stays where it
is, and nothing after it that depends on its result folds.

**F18. Values cross between the evaluators in the target's C layout.** When
a Zane fold reaches a `Foreign_call`, its arguments are known values of
`eval.ml`; `c_eval.ml` writes each into an allocation of its own laid out as
F10's slots are, padding bytes zero as there, runs the thunk, and reads the result back into an `eval.ml`
value. A view into a string, array or list is a read-only allocation
holding a copy of its bytes, and a store into it stops the fold. `eval.ml`
knows a value and not where it is stored (O5), so whether two views share
storage at run time is unknown: two arguments from one variable do, two
equal strings from different variables do not. A view's allocation is
therefore marked as standing for storage of unknown identity, and comparing
or subtracting a pointer into it with one into another allocation stops the
fold (`ffi.md` §5.4's first exclusion). So does comparing the pointer of an
empty view with null, since an empty string or list may hold a null block
or a block it once used. Pointers into two allocations that
C made compare unequal, as C gives them, except where either allocation is a
global marked `unnamed_addr` or `local_unnamed_addr`, such as a string
literal, which the optimizer or the linker may merge with an equal one, or
where either points one past its allocation's end, which C lets equal the
start of the object laid out next. Such a comparison stops the fold.

A data handle made during a fold is an allocation of `c_eval.ml`'s,
which the handle's `eval.ml` value names. A fold that ends with such a
handle alive in a known local does not fold, as one that gives a lent
address does not (O6): a C allocation has no CGT form, so it cannot be
written back as code (O7). Released within the fold, by the evaluator's model of the handle's
`.end`, it folds.

A C call to a function value's C entry (F11) is evaluated by `eval.ml`, with
the arguments read from C memory, so a C sort with a Zane comparison folds.

**F19. C evaluation spends the fold's budget.** Each instruction is a step,
and work that grows with a size, a `memcpy` or a `memset`, costs a step for
each 64 bytes, as O6 counts it. The limits of O6 hold across both
evaluators, so a fold that calls C cannot run longer than one that does not.

---

## 6. How it is tested

- `tests/ffi/` holds packages with C code, built for every target the
  codegen fixtures run on, plain and optimized, each held to one golden
  output: a pure C function called with a literal and with an argument, a
  data handle made, written, replaced through its setter and released (its
  releases counted by the C code), a struct holding a data handle and one
  made from it overwritten as a whole (the C code logging the order its
  setters run in), a capability read and write, a file
  opened, written and closed through a capability, a string returned from C, a list and
  an array lent to C, a C sort calling a Zane comparison, and a C library
  vendored by two versions of one package in one program, which defines
  a function, an alias of it and, on ELF targets, an indirect function,
  as an `archive` row's library built by the test rules for the target,
  beside a `system` row and a function in file-scope assembly that C calls
  and that jumps to a C function of another of its sources. The same
  program is linked against releases of its two packages too (F15): each
  built by `--object`, its objects and its file of hashes rewritten with a
  stamp as fetching rewrites them, and the program built against them,
  its archives renamed from the checkout at its link.
- A release's C retained (F13): a dependency's C linked as a release
  prints what it prints compiled in, and the optimized build still calls
  only what reaches a `static` counter or lets out a `static const`'s
  address, besides what is in its archives and assembled objects, a
  source holding assembly among them, while
  every thunk, a pure function, one reading a `static const` table and
  one reading what a constructor with external linkage counted, which
  runs once, are inlined. With hashes none of which agree, every thunk is
  called. `tests/unit/` checks the retained copy rule by rule, the hash
  file read, written and rewritten, and the glue's thunk order.
- `golden/NAME.optimized.cgt` shows what folded: the literal checksum as a
  constant, the handle's whole life gone, the capability calls in place, the
  call reaching `sin` left as a call.
- A fixture holds the hazard of `ffi.md` §5.5 as this compiler shows it. A
  call that reaches the C library's own outside state, such as `getenv`,
  never folds, since the C library has no body here (F16); what does fold
  is C state of the package's own. So the fixture declares with no
  capability a C function that returns the next value of a file-scope
  counter, and calls it three times with its result printed and once with
  its result unused. The test asserts what an optimized build prints (each
  call folded from the counter's first value) against what a plain build
  prints (1, 2, 3), so a change that stops folding such calls, or starts
  warning about them, is a decision, not an accident.
- `tests/unit/` checks `c_eval.ml` instruction by instruction against the
  same IR compiled and run, its undefined-behavior, `volatile` and atomic stops, the view-identity stop, the modelled C
  library functions, and the budget.
- The interface check's errors each have a fixture: a missing symbol, a
  wrong count, a type of another size on one target only (`long` built for
  `x86_64-windows-gnu`), a `const` handle passed as a `mut` subject or returned, a
  `struct` laid out differently, a fixed flag a `define` tries to change, an
  overwrite of a settled handle without a setter, an outside handle passed
  to a verb that is no method on a capability, a foreign variable
  outside the root package, naming a missing global, or naming a
  `_Thread_local` one, a package whose C places a global in a section
  named `plugins`, one whose archive member or file-scope assembly places
  data in a linker set, an archive member exporting a function it defines
  through a linker directive, one naming in a directive a function another
  member defines, one defining a Mach-O symbol no C name
  renames, and a `system` row naming a library the
  linker cannot find.

---

## 7. The order it is built in

1. Reading `c.coda` and filtering its rows by target (F5), then the clang
   front end in process, with the C compiler's include directories kept in
   the cache, compiling a C file with the package's `include` and `define`
   rows to a module of the compiler's context (F1, F2, F3).
2. The interface table from the AST (F6).
3. Foreign verbs, handle types and foreign variables in the TST, with the
   interface check and the signature-given capability facts (F7).
4. The glue and its thunks, `Foreign_call` lowering and codegen, renaming and
   linking the package's C module, for scalar, string, array, list and value
   type arguments and results (F8, F9, F10, F13, F14).
5. Handles: free and set thunks, walks, null results (F12).
6. Function values as C functions, with their C entries in prefix data (F11).
7. `c.coda`'s `archive` and `system` rows (F4).
8. Release archives and dependencies' C, retained for inlining (F13, F15).
9. `c_eval.ml`, its classes in stage 5, and the crossing between the two
   evaluators (F16–F19).
10. The fixtures of §6 for each step as it lands, and an entry in
    [`optimizations.md`](../optimizations.md) for the cross-language
    inlining (F13) and the folding through C (F16).
