# The C interface: building, calling and folding C

> **Status: designed, not built.** This page says how the compiler implements
> the spec's C interface
> ([`ffi.md`](https://github.com/zane-lang/spec/blob/4a7c195/spec/ffi.md)):
> compiling a package's C code, checking foreign verbs against it, calling
> it, and evaluating it at compile time. Each decision is numbered
> (**F1**…), and §7 lists the order they are built in.

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
runs it, and the `llvm::Module` it makes is handed to OCaml as an
`Llvm.llmodule` of the compiler's own context. Every front-end option is
therefore one the linked clang made itself, so all of them are ones it
knows.

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
target, compared as LLVM normalizes a triple, so `x86_64-linux-gnu` and
`x86_64-pc-linux-gnu` agree; one that names another is an error saying to set `ZANE_CC` to a GCC
for that target. The probe reads
the list after `#include <...> search starts here:`, which GCC, clang and
`zig cc` all print in that form; the list is kept in the cache, keyed by
the C compiler's path and `--version` output, the target, and the values
of the environment variables that change a C compiler's search
(`CPATH`, `C_INCLUDE_PATH` and `SDKROOT`), so changing any of them probes
again. Every
compilation passes it to the linked driver as `-nostdlibinc` followed by
one `-isystem` per directory, in order. An entry the list marks
`(framework directory)`, as clang prints the SDK's framework paths on
macOS, is passed as `-iframework` instead, so `<Foundation/Foundation.h>`
is found as the C compiler would find it. The C compiler's own builtin
headers are dropped from the list: the directory it names for
`-print-file-name=include`, which GCC, clang and `zig cc` all answer, and,
for GCC, the `include-fixed` beside it. Those hold its intrinsics and
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
`-fno-rounding-math` (`ffi.md` §2.2), the target triple, `-isystem` for the
directory holding `zane_ffi.h`, and `-O2 -Xclang -disable-llvm-passes`, so the
module comes out of the front end unoptimized but optimizable: `-O0` would
mark every function `noinline`, which no later pipeline undoes, and F13's
inlining across the two languages would never happen. The package's
`include` and `define` rows come after, in the order its `c.coda` writes them
(`ffi.md` §2.3). A setting that names one of the fixed flags, such as a
`define` of `__FAST_MATH__`, is an error naming the row.

`zane_ffi.h` is embedded in the compiler like the runtime's headers
([`lowering.md`](lowering.md) §7) and written once into the cache directory.

**F3. One package's C is one module, cached by what it was made from.** Each
C source compiles to a module of its own, and the package's modules, with its
glue (F8), are linked into one with LLVM's linker. A source's module is kept
in the cache directory as bitcode of the compiler's own LLVM, under a hash of
the source's preprocessed text, with its line markers, the front-end
command, and the compiler's version. The preprocessed text is what the
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
static library is read member by member at the link, after its symbols are
renamed (F9). A `system` row becomes a `-l` on the link command, in the
order the rows are written, after the program's objects and before the
runtime's libraries. A system library the target's C compiler cannot find is
an error naming the package and the row.

**F5. `zanec` reads a package's `c.coda` itself.** The settings live in the
package's directory (`ffi.md` §2.3), beside the `.c` and `.h` files the
compiler already reads from each `--package` directory, so they need no flags
and nothing from the `zane` CLI. The compiler parses the file, keeps the rows
whose `target` pattern matches the build's target, expands `source` patterns
to the `.c` files they match (a `.h` or any other file a pattern matches is
not a C source and is skipped), and checks that every path stays inside the
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
writes, invoked in an interface header, is the interface header's): each variable's canonical type and whether it has
external linkage; each function's canonical parameter and result types,
`const` qualification of pointees, whether it is variadic, and whether it
has a prototype at all; each `struct`'s fields with their canonical types,
offsets, and bit widths where a field is a bit-field, and the record's size
and alignment from clang's `ASTRecordLayout`. A declaration that only an
included header makes is not in the table, which is how `ffi.md` §2.1's
"seen by the C compiler and by nothing else" holds.

Stage 3 checks each foreign verb against that table by the rules of
`ffi.md` §3.3 and §3.7. A C type is matched by its canonical form, so a
`typedef` such as zlib's `uLong` is checked as the `unsigned long` it names.
A type §3.3 refuses is reported with what it is on the target and a pointer
to the converting C function §3.3 asks for. A C-compatible value type is compared field by field against the
`struct`'s offsets and sizes, laid out as lowering lays the Zane type out
([`platforms.md`](platforms.md), "64-bit targets only"). Two forms are
refused outright, whatever their sizes say. A function declared without a
prototype, such as `int f();`, gives no parameter types to check, so a
foreign verb naming one is an error; the header has to write `int f(void);`
or the parameters. A `struct` with a bit-field can match a Zane field's
offset and size while holding fewer bits, so no `struct` with one
corresponds to a C-compatible value type (`ffi.md` §3.3's full-width fields
exclude it). The check runs in
every build, so `zane check` reports what a build would.

**F7. The TST knows foreign verbs, handles and foreign variables.** A
foreign verb is a verb whose body is `Foreign { symbol; decl }`, with `decl`
its entry in the table. Its capability facts (`effects.md` §5.2) are not
derived from a body: `lib/tst/analyses/` gives a foreign verb the facts
`ffi.md` §5.2's table gives its signature, and every other analysis reads
them as it reads a verb's derived ones.

A foreign handle is `Ty.Handle { c_type; set; free; kind }`, a reference
type with no fields: it is settled or roaming, moved and referenced, and
destroyed, exactly like a `#struct`. `kind` is `Capability` when the type
has no `free`. Otherwise it waits until every package's declarations are
known, then is read from the foreign verbs that return the type, by
`ffi.md` §4.2. Each check of §4.4 and §5.3 is then a test of `kind` against
the verb's signature, so none of them needs to look past the declaration.

A foreign variable is a declaration statement
`Foreign_var { name; ty; symbol; decl }`, where `decl` is the variable's
entry in the table of `ty`'s package, not the declaring one's. The checks of
`ffi.md` §5.1 read the linkage and C type F6 records for it.

---

## 3. Calling C

**F8. Generated C does every call, so the compiler implements no C ABI.**
How a `struct` is passed by value differs between SysV x86-64, Windows x64
and AArch64, and LLVM leaves that classification to the front end. Rather
than reimplement clang's for each target, the compiler writes, for each
package, the glue: one C file per interface header, which includes that
header alone and is compiled with the package's settings, so clang does the
classification it already knows. Each entry goes in the file of the header
that declares its C function. The glue holds:

- one **thunk** per foreign verb, with a pointer ABI codegen can call
  trivially:

  ```c
  void thunk(void *const *args, void *result) {
      *(int64_t *)result = zane_crc32(*(const int64_t *)args[0], *(const zane_bytes *)args[1]);
  }
  ```

  Each `args[i]` points to an argument already laid out as C lays out its
  type. The thunk does the conversions of `ffi.md` §3.3 as C casts: an
  `@primitives$I32` passed to a `uint8_t` keeps its low bits, a returned
  `int16_t` widens by its sign.
- one **free thunk** per foreign handle type with a free function,
  `void free_(void *object)`, which calls it with the pointer, and one
  **set thunk** per type with a setter, `void set(void *dst, void *src)`.
- for function values, the entries of F11.

A thunk's name is the foreign verb's symbol ([`symbols.md`](symbols.md))
with `.ffi` after it, a free or set thunk's is the handle type's symbol with
`.free` or `.set`, and F11's entries are named the same way from the lambda's
symbol, given in C with an `__asm__` label, since a verb's
symbol is not a C identifier. An optimized build links the glue into the
package's module (F13), where LLVM inlines each thunk into its caller, so an
optimized call into C is a direct call with the target's own convention.

**F9. A package's C globals are renamed before its module is linked.** Once a
package's C modules and glue are linked into one, every function and
variable it defines with external linkage, except the glue's own entries,
is renamed to the package's
symbol with `%c$` and its C name after it: `!zlib$%c$deflate` in a
library, `viewer$%c$deflate` in a program. Renaming a global in its module
renames its uses with it. The fetch-time rewrite then stamps the
placeholder like any other (`separate-compilation.md` C9). A name holding
`%c$` cannot be a Zane symbol, since no package name starts with `%`.
The glue's entries (F8, F11) keep their names, which lowering's calls
already use: they are derived from Zane symbols, so they carry the
package's placeholder and cannot meet another package's.

An `archive` row's members are renamed through the object rewriter that
stamps placeholders (C9). The set of symbols the package's archives define
is read first, before the package's module is renamed, and joins the map:
each member is rewritten with it, and so is every declaration in the
package's module of a symbol an archive defines, such as a thunk's call of
a function an archive provides. So the module's references and the
archive's definitions carry the same new name, and neither can bind to a
symbol of that C name elsewhere. Undefined references, to the C library or
a `system` library, keep their names.

**F10. A foreign call is one CGT node, with its arguments laid out for C.**
Lowering makes a call to a foreign verb a `Foreign_call { thunk; args; result;
kind }`. Each argument is lowered to a slot holding its C layout, and the
node passes the slots' addresses:

| Zane argument | Slot holds |
|---|---|
| scalar primitive | the scalar |
| `@primitives$Bool` | an `i8`, 0 or 1 |
| `@primitives$String` | a `zane_bytes`: the string's byte address and length, from its handle |
| `@primitives$Array<T, n>` | the address of the array, which already lays out as `T[n]` |
| `@primitives$List<T>` | a `zane_span`: the list's block address and count |
| C-compatible value type | the value, already in C's layout |
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
lifted with two entries: its Zane function (L14), and a C function in the
glue that lays its arguments out and calls a pointer-ABI adapter of the Zane
function, as a thunk does in the other direction. A function value of a
C-compatible type is the address of its C entry, everywhere in the program,
and a Zane call through such a value goes through a generated **invoker**,
`void invoke(void (*f)(void), void *const *args, void *result)`, one per
C-compatible type, which calls `f` with the C convention. Inlined, an invoker
is an indirect call, so a call through such a function value costs what a
call through a C function pointer costs.

The representation is fixed by the type alone, so it needs no analysis of
where a function value flows, and the two agree in every object
([`lowering.md`](lowering.md), "Fixed while compiling").

**F12. A handle is a pointer whose end calls its free thunk.** A handle's
CGT type is a pair of words: the C object's pointer and the 64-bit stamp
below, so the stamp travels with the handle wherever it is stored, in a
local, a field or a list element, and needs no slot of its own. C
receives only the pointer (F10). Its walk table ([`lowering.md`](lowering.md) §9)
has an `.end` that calls the free thunk when the pointer is not null and
a `.move` that copies both words and nulls the place moved from, as `ffi.md` §4.2's
move rule needs. It has no
`.copy`: a handle is a reference type and is never copied. A capability's
walk table has no `.end`, since nothing frees a C global, and a foreign
variable lowers to the address of its global under the name F9 gives it.

An assignment to a settled place that holds a handle lowers, for each
handle the overwrite reaches (`memory.md` §2.2), to a call of the set thunk
with the place's pointer and the replacement's, and the replacement is
dropped without its `.end`. The place keeps its stamp (below): handles made
from the old object since hold the same address, so they still end
first.

A drain ends a scope's values with no order among them
([`lowering.md`](lowering.md) §9), but `ffi.md` §4.2 orders free functions.
So each handle a call makes is stamped as it is made with a number from
one process-wide counter, a 64-bit atomic fetch-and-add. Handles made by
spawned calls on different pool threads still get distinct, comparable
stamps, and a handle made from another is made after it in the program's
happens-before order, so its stamp is larger. A drain that ends more than
one handle collects their pointers and runs the free thunks by
descending stamp, after the scope's other ends. A move keeps the stamp, since the handle is the same
one. A drain that ends one handle or none does nothing more than it does
now.

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
  the publisher's, the dependency's C is called and never inlined or folded.
  A `source` or path dependency is built by the consumer, so its modules
  always agree.
- **It shares no state the object owns.** A retained function that reaches
  a C variable with internal linkage that is not `const`, or is `volatile`
  (a file-scope `static` counter, or a `static const volatile` status
  word), is not retained: a copy of the variable in the
  consumer would be a second variable, and the function's inlined and
  called forms would each see their own. Such a function, and everything
  that reaches it, is called. A `static const` table and a `static`
  function are copied only where nothing can tell the copy from the
  original: their contents are read and the function is called, and their
  address is never returned, stored, compared, converted to an integer or
  passed on. A function that lets such an address out would give one
  address inlined and another called, so it is called, like one that
  reaches mutable state.

**F14. An unoptimized build compiles the C apart.** `zane run` builds
unoptimized and answers to the time from the command to the result
([`optimization.md`](optimization.md) O12). C written to be compiled with
optimization is many times slower without it, and its module is cached
(F3), so an unoptimized build optimizes the package's C module on its own
with `-O2` and emits it as an object of its own, kept in the cache beside
the module; the Zane module stays unoptimized and calls its thunks.

**F15. A release archive holds one object per package build, C included.**
`--object` writes the package's object with its C linked in (F13 or F14),
and beside it a small file listing, for each of the package's C sources
and for its glue, the hash F3 keys its module by, which F13's first condition reads. The
archive's layout is otherwise unchanged (`dependencies.md` §3.1); an `archive` row's library is part of the source
checkout and is renamed at the consumer's link (F9).

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
  and offset it came from, and arithmetic on it keeps them too. An
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
  written with; `getelementptr`
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
F10's slots are, runs the thunk, and reads the result back into an `eval.ml`
value. A view into a string, array or list is a read-only allocation
holding a copy of its bytes, and a store into it stops the fold. `eval.ml`
knows a value and not where it is stored (O5), so whether two views share
storage at run time is unknown: two arguments from one variable do, two
equal strings from different variables do not. A view's allocation is
therefore marked as standing for storage of unknown identity, and comparing
or subtracting a pointer into it with one into another allocation stops the
fold (`ffi.md` §5.4's first exclusion). Pointers into two allocations that
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
  releases counted by the C code), a capability read and write, a file
  opened, written and closed through a capability, a string returned from C, a list and
  an array lent to C, a C sort calling a Zane comparison, and a C library
  vendored by two versions of one package in one program.
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
  to a verb that is no method on a capability, and a foreign variable
  outside the root package or naming a missing global.

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
6. Function values as C functions, with invokers (F11).
7. `c.coda`'s `archive` and `system` rows (F4).
8. Release archives and dependencies' C, retained for inlining (F13, F15).
9. `c_eval.ml`, its classes in stage 5, and the crossing between the two
   evaluators (F16–F19).
10. The fixtures of §6 for each step as it lands, and an entry in
    [`optimizations.md`](../optimizations.md) for the cross-language
    inlining (F13) and the folding through C (F16).
