# Symbols

What a program's types, verbs and variables are called in the LLVM IR and in
the binary. The rule is the same for all of them: a thing is called by its
declaration as written, fully qualified. That name is already unique across
the program, so nothing is encoded, and the name a reader sees in the source is
the name in the IR, in a stack trace and in `nm`, with `%` for the `@` of an
intrinsic namespace (see [Types](#types)). Generic instances follow the
same rule; [`generics.md`](generics.md) covers them.

`lib/cgt/symbol.ml` defines the spelling. A symbol is an ABI, so it has one
definition of its own, and the TST's printers stay free to change how a
diagnostic reads.

## Types

A type is called by its package or intrinsic namespace, its name, and its
arguments, each qualified the same way:

```text
geometry$Point
geometry$List<%primitives$Int>
%primitives$Int
```

Arguments are separated by `, `. A guest is written `&` before its type.

An intrinsic namespace is written with `%` where the source writes `@`:
`%primitives$Int` is `@primitives$Int`. A linker reads `@` in an exported
symbol as the start of a symbol version (`name@VERSION`), so a name holding
one could not be exported from a shared library. `%` has no meaning to a
linker, and no package name starts with it.

## Verbs

A verb is called by its package, its name, and its parameter types. A
method's subject comes first, after `this`:

```text
pkg$swapWeapon(this pkg$Player, pkg$Weapon)
pkg$distance(geometry$Point, geometry$Point)
pkg$+(pkg$Vec, pkg$Vec)
geometry$Point(%primitives$Int, %primitives$Int)
```

- The package is the one that declares the verb, which is not necessarily
  the one that declares its subject's type.
- An operator is named by its token, and a subscript by `[]`.
- A constructor is named by the type it builds, followed by `.member` for a
  named constructor.
- A generic verb's instance writes its arguments after its name, as a type
  does, and its parameter types with those arguments in place:
  `pkg$first<%primitives$Int>(this pkg$List<%primitives$Int>)`. An explicit
  `T Type` or number parameter writes its kind (`Type`, `%concepts$Int`),
  since the argument it takes is already among the instance's.
- The return type, parameter names and `mut` are left out. Overloads cannot
  differ by them ([functions.md §4.1](https://github.com/zane-lang/spec/blob/b0675d6/spec/functions.md)),
  so the parameter types are enough to tell every overload of a name apart.

## Variables and lambdas

A package variable is called by its package and its name, with no signature:

```text
pkg$requestHandler
```

A lambda stored in a package variable is called by that variable's name
([`lowering.md`](lowering.md) L14 lifts it to a function of its own).

Every other lambda, whether held by a local or written where a value goes, is
called by the verb it is written in and its place among that verb's lambdas,
counted from 1 in source order, nested ones included:

```text
pkg$serve(pkg$Request)$lambda1
pkg$serve(pkg$Request)$lambda2
```

A generic verb's lambdas are counted within each instance, under the
instance's name.

A lambda in an enum map's entries is counted the same way under the map,
which is called by its enum and its property:

```text
pkg$Op.apply$lambda1
```

## Layout tables

The table the runtime reads to find a type's hosts and blocks
([`lowering.md`](lowering.md) L9) is called by the type's name. An outcome's
table is called `outcome of T`, with ` ? A` added when the verb can abort
with `A`.

## Names that stay C identifiers

The runtime is C, and it finds what it calls by a C name. These keep one:

- the program's entry, `zane_main`, whatever its `main` is called
  ([`lowering.md`](lowering.md) L16);
- the runtime's own functions, all `zane_*`. No symbol above can clash with
  them, since every one contains a `$`.

What the compiler makes for itself, with no declaration behind it, is named
under `zane.`: the function each spawned call runs through (`zane.spawn.N`)
and each string literal's bytes (`zane.text`).

## What the compiler does today

- Verbs, types and layout tables are named as above, by `Symbol.verb` and
  `Symbol.ty`.
- Lambdas are named as above. A lambda that expands into more than one
  place keeps its one name, and is lifted once.
- Package constants other than lambda-variables are not lowered yet, so no
  other variable has a symbol yet.
- A program builds into one module ([`lowering.md`](lowering.md) L15), so
  every verb but `zane_main` is local to it: its symbol is in the binary, for
  a debugger or a profiler, but no other object links against it. A layout
  table is private and has no symbol in the binary at all.
- A library built into an object of its own carries the `!` placeholder
  before its package's name, in its verbs' names and in its types' names
  wherever a symbol names one: `!geometry$sum(this !geometry$Point)`. Its
  verbs are exported, the instances of its generics are shared, and what it
  reaches in other packages is local
  ([`separate-compilation.md`](separate-compilation.md) C4, C5).
- A dependency given a stamp is named with it, and arrives as objects of its
  own: its verbs are declared, not defined, and an instance of its generics
  is made under its stamp and shared (C1, C6).
- `zanec --rewrite` turns a library object's placeholders into its stamp,
  as fetching does, for ELF objects so far (C9).
- LLVM's struct types are unnamed: a CGT type is structural, and carries no
  name for a struct to take.
