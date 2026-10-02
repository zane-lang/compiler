# Separate compilation: one object per package

> **Status: built through §5 step 4.** This page says how the compiler builds
> one package into an object file of its own, so a library can ship prebuilt
> objects ([`dependencies.md`](https://github.com/zane-lang/spec/blob/main/spec/dependencies.md)
> §3.1) and a program can link against them. Each decision is numbered
> (**C1**…). §5 lists the order they are built in, and §6 the questions still
> open. The rewriter reads ELF objects so far; Mach-O and COFF are step 5.

A dependency reaches a build in two forms. Its **source** is the verified
checkout in the package cache (`dependencies.md` §7), and its **objects** are
the ones its release archive carries, with every symbol it defines spelled
with the `!` placeholder that fetching rewrites (`dependencies.md` §6.1). The
compiler reads the first and links the second: it type-checks a package
against its dependencies' source, and generates code for that package alone.

---

## 1. What one compilation reads and writes

**C1. A compilation generates code for its root package and its unstamped
dependencies.** The first `--package` is the root, as it is today, and the
others are its dependencies, direct and transitive. Every package is loaded
and checked, since the root's types and calls name theirs. A dependency given
a stamp (C6) arrives as prebuilt objects, so lowering and codegen emit nothing
it declares: only what the root and the unstamped dependencies declare, plus
the generic instances they need (C4). With no stamps at all, that is the
whole program in one module, as every build is today.

**C2. A dependency is read from source.** The compiler type-checks against a
dependency's source, the same `.zn` files its objects were built from at the
pinned commit, rather than against an interface file. So nothing besides the
source and the objects needs publishing, and nothing new needs versioning
with the compiler. The cost is that every build parses and checks every
package in the graph; caching that is left to measurement (§6).

**C3. `--object OUT` writes the root package's object file.** It is the
library's counterpart to `--build`: no runtime and no link, only the object.
`--build OUT` keeps its meaning, a linked executable, and for a root with
dependencies it compiles the root's object and links it with theirs (C7).

---

## 2. What the symbols are

**C4. A generic instance is emitted where it is needed, and named by its home
package.** An instance belongs to the generic's home package and is named
there ([`generics.md`](generics.md)). A library's prebuilt objects cannot
hold the instances a consumer needs, since the library was built before the
consumer's types existed. So whichever object needs an instance emits it,
under the home package's name, with LLVM's `linkonce_odr` linkage: every
copy is the same code, and the linker keeps one. An instance the library
itself uses is in the library's objects, and a consumer that needs the same
one emits a copy that merges with it.

**C5. Every symbol a library defines carries the `!` placeholder.** That
covers its public verbs, its `_`-private ones, its lambdas, and the generic
instances it emits, whatever package their arguments come from. Private
verbs need it as much as public ones: a public generic verb's instance,
emitted in a consumer's object (C4), calls the library's private verbs, and
two versions of one library define the same private names. So the
placeholder marks what the library *defines*, and fetching rewrites all of
it to the version and identity hash (`dependencies.md` §6.1).

A type the library declares carries the placeholder too, wherever a symbol
names it: in a verb's parameters, and in a generic instance's arguments.
Two versions of one library lay out their types each in their own way, so an
instance of another package's generic at each version's type must have a
name of its own, or the linker would keep one copy for both (C4):

```text
!math$length(this !math$Vec)   →   v1.0.1%3f9a1c02b7e4d6a8%math$length(this v1.0.1%3f9a1c02b7e4d6a8%math$Vec)
```

Every placeholder in a symbol is rewritten, wherever it stands. No other `!`
can stand in a symbol: no operator is spelled with one
([`operators.md`](https://github.com/zane-lang/spec/blob/main/spec/operators.md)
§5.2), and a mutating call's `!` is call syntax, not part of the verb's name
([`functions.md`](https://github.com/zane-lang/spec/blob/main/spec/functions.md)
§2.5). So the rewriter replaces every `!` it finds (C9).

An application's root package defines no placeholder symbols: nothing links
against it.

**C6. A reference to a dependency's symbol is written already stamped.** When
a package calls into its dependency `math`, the compiler writes the stamped
name, `v1.0.1%3f9a1c02b7e4d6a8%math$length(...)`, which is what `math`'s
rewritten objects define. So the compiler takes each dependency's stamp from
the driver:

```text
--package math=DIR --stamp math=v1.0.1%3f9a1c02b7e4d6a8%
```

`zane` computes the stamp: the pinned tag, `%`, the identity hash of the
package's URL, and `%` (`dependencies.md` §6.1). A dependency given no
`--stamp` is compiled into the same module as the root (C1). Instances of a
dependency's generics (C4) carry that dependency's stamp too.

The root's own stamp is `!` when it is a library. Fetching rewrites the root
library's `!` placeholders and leaves the stamped names alone, which is what
`dependencies.md` §6.3 asks: a library's references to its own dependencies
are already versioned when it is built.

A root library given a `--stamp` of its own is named with that stamp instead
of the placeholder. That is a dependency compiled from source
(`dependencies.md` §12.1): it is built for one version already known, so its
object comes out the way a rewritten release's would, and no rewriting is
needed.

---

## 3. Rewriting and linking

**C7. A program links its root object, its dependencies' objects, and the
runtime.** `--build OUT` takes each dependency's rewritten objects with
`--link FILE`, and has `clang` link them with the root's object and the
runtime, as it links the runtime today. The program's entry stays
`zane_main` ([`lowering.md`](lowering.md) L16), so only the root may
declare it.

**C8. Layout tables stay private to each object.** A layout table is read
only by the runtime, through the pointer its object passes
([`symbols.md`](symbols.md)). Each object that needs a type's table makes its
own, and nothing compares two tables' addresses, so private copies cost a few
bytes and need no shared name.

**C9. `zanec --rewrite STAMP INPUT OUTPUT` turns a library's placeholder into
its stamp.** Fetching runs it on each object a release archive carries
(`dependencies.md` §6.1). It is the compiler's step rather than `zane`'s
because the symbol spelling is the compiler's: the `zanec` that the project
pins rewrites objects that same version built, so `zane` never has to know
how any version spells a symbol (§4).

The rewriter edits the object's symbol table and nothing else. A stamped name
is longer than the placeholder, so the new names cannot go where the old ones
are: the string table is copied to the end of the file with the new names
after it, and each renamed symbol points at its new name. The old table stays
behind, unread. Nothing else moves, since relocations and section groups
name a symbol by its index, not its name. The rewritten object defines
exactly what one built from source with `--stamp` does.

---

## 4. What a compilation must agree on

A consumer computes a dependency's layouts, its verbs' signatures and its
generic bodies from source, and links against objects built elsewhere. Those
agree because both are built by the same compiler, pinned by `zane-version`
(`dependencies.md` §14), from the same source, pinned by commit. A
dependency built by a different compiler pin is the one way they could
disagree; `zane` records the pin a cache entry was rewritten with
(`dependencies.md` §7), and refuses to reuse it under another.

---

## 5. The order it is built in

Each step is one PR, ends with programs that run, and keeps every earlier
test passing.

1. **This design.** [`generics.md`](generics.md) and
   [`lowering.md`](lowering.md) L15 point here.
2. **One object per package.** `--object`, codegen for the root package only,
   `!` on a library's symbols (C5), and generic instances as `linkonce_odr`
   (C4). A test builds a library's object and lists its symbols.
3. **Stamps and linking.** `--stamp` and `--link` (C6, C7). A test builds a
   library's object, renames its `!` symbols as fetching will, and links a
   program against it.
4. **The rewriter for ELF.** `--rewrite` (C9) for ELF objects. A test
   rewrites a library's object, compares its symbols with the same library
   built from source with its stamp, and links a program against it.
5. **The rewriter for Mach-O and COFF.** The same, for macOS and Windows
   objects. The tests list a rewritten object's symbols, since a Linux
   runner cannot link for those targets.

---

## 6. Open questions

- **Two versions of one package in a graph.** A package's imports name other
  packages by name, and one compilation holds each name once
  ([`assembly.ml`](../../lib/tst/passes/assembly.ml)). Two versions of
  `math` in one graph (`dependencies.md` §11) need each package to resolve
  its imports through its own manifest's keys instead, and the two `math`s
  to be told apart by their stamps. Until then a graph with two versions of
  one package is refused.
- **A key that differs from the package's name.** Source imports a dependency
  by its manifest key (`dependencies.md` §8), and the compiler resolves
  imports by package name. Until imports resolve through keys, a key must
  equal the library's `name`.
- **Package constants.** They are evaluated before `main` in dependency order
  ([`lowering.md`](lowering.md) L16), but only lambda-variables lower yet. A
  library's constants will need an initializer its consumer's program runs.
- **Checking every package on every build.** C2 parses and checks the whole
  graph each time. Caching a checked dependency is left to measurement.
