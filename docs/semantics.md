# Designing the TST

> **Status: built.** Stage 3 — the passes that turn the SST into the typed
> syntax tree — follows this design. Each decision is numbered (**D1**…). The
> questions the first draft left open are answered in §8. Where the spec is
> silent and the compiler had to choose, §9 says what it chose. §10 lists what
> stage 3 does not do yet.

The **TST** is the SST with every name resolved and every expression typed
([`stages.md`](stages.md)). Where the SST answers "what was written, said one
way", the TST answers "what that means": which declaration each name is, which
overload each call picked, which implicit constructor each coercion site
inserted, and what type every expression has. No later stage should ever need
to repeat a lookup.

`lib/tst/` mirrors `lib/sst/` where it can: `nodes.ml` is the tree,
`to_tree_graph.ml` renders it, `to_span_text.ml` reads its spans back out of
the source, and `tst.ml` is the entry module. Unlike
`lib/sst/lower.ml`, the code that builds it is several passes (§3), because
each one needs the tables the previous one built:

| Module | Holds |
|---|---|
| `assembly.ml` | The packages, read from their directories (§2) |
| `env.ml` | The declaration tables, each file's import map, and the diagnostics |
| `collect.ml` | Passes 1 and 2 |
| `types.ml` | Type-expression resolution, and pass 3 |
| `signatures.ml` | Pass 4 |
| `check.ml` | Pass 5, with overload resolution and instantiation |
| `ty.ml`, `signature.ml` | Types (§4), and what a call site needs to know about a verb |
| `intrinsics.ml` | The intrinsic namespaces (D3) |
| `semantics.ml` | The passes, run in order |

Rules are cited against spec commit
[`e0b4249`](https://github.com/zane-lang/spec/tree/e0b4249), the current
`main`, which already carries the operand-order rule of spec#199. That is newer
than the `034f11a` pin in [`desugaring.md`](desugaring.md); nothing cited here
changed between the two.

---

## 1. What the TST holds, and what runs over it later

Stage 3 is "semantics" — name resolution, type checking, and every other check
the spec states. Those are not all the same kind of work, and not all of them
belong in the pass that builds the tree.

**D1. The TST is the output of name resolution and type checking. Every other
semantic check is an analysis *over* the finished TST.** An analysis reads the
tree and reports diagnostics; it adds no nodes. Where it produces a fact a
caller needs — an effect level, a parameter's resting place — the fact goes in a
side table keyed by declaration, not into the tree.

That splits the work like this:

| Built with the tree (milestone 1) | Analyses over the tree (later) |
|---|---|
| Package assembly and imports ([`packages.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/packages.md) §2–§3) | Moves, stores and lifetimes ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/lifetimes.md) §1) |
| Type declarations, aliases, value-downstream ([`memory.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/memory.md) §2.10) | Resting places published with a signature ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/lifetimes.md) §1.11) |
| Signatures, inline generic parameters ([`generics.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/generics.md) §3–§4) | Effect-level inference ([`effects.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/effects.md) §3–§5) |
| Overload identity and resolution ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §4–§6) | `spawn` safety ([`concurrency.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/concurrency.md) §3–§4) |
| Implicit constructors at coercion sites ([`types.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/types.md) §4) | Block escape ([`control-flow.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/control-flow.md) §2.2) |
| `:`/`!` against `mut` ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §2.5) | |
| Abort handlers: required, and every path ends ([`error-handling.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/error-handling.md) §3) | |
| `match` exhaustiveness and one result type ([`adt.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/adt.md) §5) | |
| Every path of a block-bodied verb returns ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §3.5) | |

The left column is what the tree cannot be built without: a call cannot have a
callee until overloads are resolved, and cannot have a type until it has a
callee. The right column needs a resolved, typed tree and changes nothing in
it.

Block-taking verbs expanded at the call site (`control-flow.md` §2.3) are
neither. That is a lowering, and it belongs to the lowering stage, which builds the CGT.

---

## 2. The input is a set of packages, not a file

Today `Cst.parse` takes one file and the binary prints one tree. That is enough
for stages 1 and 2, which never look past the file. It is not enough for stage
3:

- A package is "one order-independent compilation unit" made of every file in
  its directory (`packages.md` §2.3). A name in one file resolves to a
  declaration in another.
- Imports are per file (§3.1), so resolution needs to know which file a
  declaration came from, not only its package.
- `Int` is not built in. It is a declaration in `core`, "an ordinary package"
  (`types.md` §2.6), and a file that writes `Int` imports `core` like any other
  dependency. **No program that writes a literal can be type-checked without a
  `core` package to check it against.**

**D2. Semantics takes a set of packages: the root plus its dependencies, each
given as a directory.** Fetching, versioning and the manifest
([`dependencies.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/dependencies.md))
stay out of scope. The driver takes a `--package DIR` flag, repeatable, and the
first directory given is the root (`packages.md` §6.1). Each file parses and
lowers exactly as today; stage 3 is the first stage that groups them.
`lib/tst/assembly.ml` does the grouping: a package is the `.zn` files directly
in its directory (§2.3), named for the directory (§2.1). Each file must begin
with a `package` line naming it (§2.2), and no two directories may share a
name.

**D3. A minimal `core` is checked in as a test fixture** — `test/core/`, holding
`Int`, `Float`, `Bool`, `Unit`, `String`, `Array` and `List` over
`@primitives$`, their operators, the implicit constructors from
`@concepts$Integer`, `@concepts$Decimal` and `@concepts$Text` that carry
literals into them (`types.md` §2.6), the control-flow verbs of `control-flow.md` §3, and a
`Console` over `@runtime$Console`. It is the first real multi-file,
multi-package test input. It is also the first code in the repository that has
to type-check.

Nothing in stage 3 depends on what the fixture declares, or how. `core` is an
ordinary package (`types.md` §2.6), so the compiler reads it as source and
checks it by the same rules as every other package. It never names `core` or
any of its members. Whether `Int` is a distinct type over `@primitives$Int` or a
struct wrapping one is `core`'s own choice, and the compiler does not care which
it makes, just as it does not care how any other package writes its types.

The intrinsic namespaces (`@primitives$`, `@concepts$`, `@controlflow$`,
`@runtime$`, `@program$`) are not packages. They are an OCaml table in
`lib/tst/intrinsics.ml`. Each intrinsic operation has exactly one signature
([`syntax.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/syntax.md)
§2.7), so the table is a plain map, with no overload sets. Operators and
methods are the exception §2.7 itself makes: they are found by their operands'
or subject's home, which for an intrinsic type is the namespace that holds it
(`functions.md` §6.1). What the table holds beyond what the spec names is in
§9.

---

## 3. The passes

Each pass reads the SST and the tables of the passes before it, and nothing
else.

1. **Collect.** Walk every declaration of every package. Give each one a
   `Decl_id` and file it under its package:
   - functions, types and constants under their name;
   - constructors under their type;
   - methods under their name, in a table that plain-name lookup never reads —
     methods are reached only by method lookup (`packages.md` §3.6);
   - operators under their token.

   Check here: the `package` line matches the directory (§2.2); a non-verb name
   is not declared twice; `_` privacy (§4.1).
2. **Imports.** For each file, build the map from what the file may write to
   what it means (§3.3). Check here: two spellings of one entity (§3.4); alias
   casing (§3.7); collisions reported at the import (§3.8); no method or
   operator import (§3.6).
3. **Types.** Resolve every `type` and `alias` right-hand side to a `Ty.t`
   (§4). Check here: alias cycles; moulds only on a right-hand side
   (`types.md` §5.3); value-downstream (`memory.md` §2.10); `&` only on a
   reference type (`memory.md` §2.4).
4. **Signatures.** Resolve every verb's parameter and return types, introducing
   inline generic parameters at their first marked occurrence (`generics.md`
   §3.2, §4.4). Check here:
   - overload identity, including no overloads that differ only by passing mode
     (`functions.md` §4.1);
   - the operator home-package rule ([`operators.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/operators.md) §2.2);
   - implicit-constructor source and destination kinds, and the orphan rule
     (`types.md` §4.4–§4.5);
   - enum-map exhaustiveness (`adt.md` §6).
5. **Bodies.** Type every verb body, constant, and enum-map entry against the
   signatures. Every signature is known before this pass starts, so bodies
   check in any order, which is what "order-independent" asks for (§2.3).

**D4. Diagnostics accumulate.** The parser stops at the first error, which suits
a parser. A type checker that stops at the first error fails the author once per
mistake. Each pass collects diagnostics and keeps going. An expression that
failed to type gets the type `Ty.Error`, which every check accepts silently. One
mistake then gives one error, not a cascade. The driver prints them all and
exits non-zero if there is any.

---

## 4. Types

```ocaml
(* lib/tst/ty.ml *)
type t =
  | Named of { id : Type_id.t; args : arg list }  (* a declared type, applied *)
  | Guest of t                                    (* &T *)
  | Primitive of Primitive.t                      (* @primitives$Int, ... *)
  | Concept of concept                            (* literals, blocks *)
  | Verb of verb                                  (* a function type *)
  | Param of Param_id.t                           (* inside a generic declaration *)
  | Error                                         (* see D4 *)

and arg = Type of t | Number of number
and number = Known of int | Param_num of Param_id.t

and concept =
  | Integer_lit | Decimal_lit | Text_lit           (* @concepts$Integer, Decimal, Text *)
  | Array_lit of t * number                        (* @concepts$Array<T, n> *)
  | Map_lit of t * t                               (* @concepts$Map<K, V> *)
  | Block of t option                              (* @concepts$Block, Block<T> *)
  | Type_concept                                  (* Type *)
```

**D5. An `alias` is expanded when it is resolved, and a `type` gets an identity
of its own.** An alias is "an interchangeable alternate name"
(`types.md` §5.2), so after pass 3 it has no identity left to carry. A `type`
is "structurally equal to its right-hand side but not interchangeable with it"
(§5.1). So it gets a fresh `Type_id`, and its right-hand side is stored in the
type table as its definition. Type equality is then plain structural equality on
`Ty.t`, with no alias-chasing.

`Type_id` is the defining package plus the name. That is also how a symbol will
be named in the binary, because "the package name a compiled symbol carries is
always the defining package's own name" (`packages.md` §3.3). The type table
keeps, for each `Type_id`:

- its header parameters;
- value or reference (`types.md` §2.1);
- its definition: struct fields, variant cases, enum members, or a distinct
  type's right-hand side.

---

## 5. Typing is bottom-up

**D6. Every expression's type is computed from its parts alone; no expected type
flows down.** The spec supports this directly:

- A literal's type is a concept type. `20` is `@concepts$Integer` and `2.5`
  is `@concepts$Decimal`, not `Int` or `Float` (`syntax.md` §2.8,
  `lexical.md` §7).
- A concept type becomes a storage type only through an implicit constructor at
  a coercion site (`types.md` §2.6, §4.2).
- The coercion sites are exactly the positional arguments of calls and
  constructors, field-constructor entries, and enum-map entries. Declarations,
  assignments and `return` are not coercion sites. `x Int = 20` is therefore a
  type error, not a coercion (§4.2).
- Generic parameters are inferred from argument types. A bare literal
  "**MUST NOT** drive inference" (`generics.md` §5.4).

So the only place a destination type matters is a coercion site, and there the
destination comes from the candidate being tried, not from context. A call
types its arguments first and then runs overload resolution. That is the three
phases of `functions.md` §5 (direct, generic, implicit), each tried only if the
one before found nothing.

Where the typing rules need care:

| Construct | Rule |
|---|---|
| Name | Looked up in local scopes, then the file's import map and own package (§2–§3 of `packages.md`). A lambda body sees no enclosing locals: "Lambdas do not capture" (`functions.md` §7.4). A block argument does (`control-flow.md` §2.2). |
| Method call | Candidates from the subject type's home package, then the current package (`functions.md` §6.1); a qualified callee names its package. The subject is never coerced (`types.md` §4.6). `:` must call a non-`mut` method and `!` a `mut` one (§2.5). |
| Operator | Candidates from the operand types' home packages only; imports add none (`operators.md` §2.2). A swapped `Op` is resolved as the primitive with operands in passed order (see D8). |
| Abort handler | Required on every abortable call and on every member read of a variant, rejected on a total member read (D13); the handler's `resolve` values must have the handled operation's success type; every path ends in `resolve`, `return` or `abort` (`error-handling.md` §3.1–§3.2). |
| `match` | Every case covered by exactly one arm; every arm yields the same type — no arm is a coercion site, so "the same" is exact (`adt.md` §5). |
| Block argument | Typed `@concepts$Block<T>` from its `resolve` statements, or `@concepts$Block` if it has none (`control-flow.md` §2.4). |
| Collection literal | `@concepts$Array<T, n>` when every element has the same concrete type `T`; with a bare literal element it fixes no `T` and cannot drive inference (`generics.md` §5.4). |

---

## 6. The tree

`lib/tst/nodes.ml` follows the SST rule: it is the SST's tree with the
differences commented where they occur. Every `Expr.t` gains `ty : Ty.t`. The
differences that matter:

**D7. Names become references.** `NameExpr` becomes `Var of Name_ref.t`:

```ocaml
type Name_ref.t =
  | Local of Local_id.t        (* a symbol or parameter of this verb *)
  | Global of Decl_id.t        (* a package constant or lambda-variable *)
  | Number_param of Param_id.t (* a number parameter read as a value, generics.md §3.5 *)
  | Intrinsic of Intrinsic.t   (* @program$console, ... *)
```

**D8. Calls name their callee, and `Call_form` goes.**

- `Call` holds `callee : Verb_ref.t`, the resolved declaration plus the
  generic arguments it was instantiated at.
- Calling a lambda-variable is a separate `Call_value` node, since there is no
  declaration to name.
- The SST kept `Call_form` because a method and a function resolve differently
  ([`desugaring.md`](desugaring.md) §2.11). After resolution, the callee's
  declaration says whether it is a method and whether it is `mut`, so the form
  has nothing left to say. The `:`/`!` check runs while resolving, against that
  declaration.

`Op` and `Flip` stay separate nodes. Each gains `impl : Verb_ref.t`, and `Op`
keeps `swapped`, whose meaning is unchanged: operands in written order,
evaluated in written order, passed the other way round
([`operators.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/operators.md) §2.3).
Folding `Op` into `Call` would force `Call` to carry `swapped` too, on a node
where it is otherwise always false.

**D9. Every inserted implicit constructor is a node.**
`Coerce { ctor : Verb_ref.t; value : Expr.t }` wraps the argument it converted
and takes that argument's span. A literal passed to an `Int` parameter is
therefore a `Coerce` of core's implicit `Int` constructor around a
`Integer_lit`. No later stage re-derives a coercion, and a diagnostic about one
can point at the argument that caused it.

**D10. Constructor calls resolve to what they are.** The SST's `Constructor`
covers three different things, which only types can tell apart:

- `Construct { ctor; args }`: a positional, named or field constructor.
  Field-constructor entries **keep their written order**, each tagged with the
  field slot it fills. Reordering them into declared order would reorder their
  evaluation.
- `Case { variant; case; payload }`: a variant case form. This is "not a
  constructor verb" (`adt.md` §3.2), so it has no `ctor`.
- `Enum_member { enum; member }`: a payloadless member (`adt.md` §2).

The SST's `TypeMember`, `TypeValue` and `DotAccess` resolve the same way:

| SST node | Becomes one of |
|---|---|
| `DotAccess` | field read (a slot index); variant member read (abortable, D13); enum-map read |
| `TypeMember` | enum member; variant case; named constructor |
| `TypeValue` | a `Type` argument passed to an explicit `Type` parameter (`generics.md` §5.3) |

An expression that failed to type is an `Invalid` node of type `Ty.Error`
(D4). A declaration carries what passes 3 and 4 resolved about it, and a verb
its typed body — or, for a generic verb, none: its bodies are the instances
(D12), which the tree lists after the packages.

**D11. Facts for later analyses live beside the tree, not in it.** Effect level
per verb, resting places per parameter, and the list of generic instances are
side tables keyed by `Decl_id`. The tree stays one shape for every consumer.

---

## 7. How it was built, and how to look at it

Each step of the plan ended with `dune runtest` green and a golden file for
what it added, the way the SST landed:

1. `--package DIR` in the driver, and assembly: files grouped by package, a
   package-line mismatch reported.
2. The `core` fixture (D3) and the intrinsic table.
3. Passes 1–2: declaration table and import maps.
4. Pass 3 and `Ty`: type declarations.
5. Pass 4: signatures and overload-set checks.
6. Pass 5: expressions, calls and overload resolution, coercion, abort
   handlers, `match`.
7. Generic instantiation (D12).

The driver prints three views of a package build:

| Flag | Prints |
|---|---|
| none | The packages assembled from the directories |
| `--decls` | Every declaration with what passes 1–4 resolved: definitions, alias targets, signatures |
| `--tst` | The whole typed tree: every body, with a type on every expression, and every generic instance |

Either of the last two prints every diagnostic and no tree when there is one.
The goldens in `test/semantics/golden/` are those views: `typed.decls` and
`typed.tst` for a build of `app`, `shapes` and `core` that checks, and
`typing.err` for a build that fails every way the passes can report, one
fixture file per area.

`typed.tst.spans` checks the spans of the same build, the way
`test/parser/golden/` checks the CST's and SST's: `span_dump --tst` takes the
same `--package` flags and prints every node of the typed tree, generic
instances included, with the source text its span covers. The TST is built
from many files, so each line reads its text out of the file its own span
names. A node the checker built -- a `Coerce`, a parameter's local -- shows
there what it points at.

## 8. Answered questions

The first draft left four questions open. These are the answers.

**D12. A generic verb's body is checked once per instantiation, as a C++
template is.** A parameter's only bound is `Type` or `@concepts$Integer`
(`generics.md` §3.3). So a body that writes `a + b` on a `T` has nothing to
resolve `+` against until `T` is known. The signature is checked once. The body
is checked once per distinct set of arguments, memoized by `(Decl_id, args)`,
and the TST holds one body per instance. An error in a generic body is reported
at the instantiation that exposed it, and names the call site that asked for
it. This fits the home-package instantiation plan in
[`generics.md`](generics.md). When a body is checked is a property of this
compiler, not of the language, so it stays out of the spec.

**D13. A member read takes an abort handler.** `adt.md` §3 makes a variant
member read "an **abortable** access (`?` / `??`)". Whether a read is of a
variant is a question about the target's type, so the grammar accepts a handler
on any member read: `DotAccess` carries an optional abort handle in the CST and
the SST, attached by `attach_abort_handle` in `lib/cst/parser_actions.ml` as a
call's is. Typing then requires one on a variant read and rejects one on a
total read, the same rule it applies to calls.

**D14. A local may not shadow a name already in scope.** The spec says nothing
about locals, but it forbids an import from shadowing (`packages.md` §3.8). A
local declared with a name already bound — an enclosing local, a parameter, or
a package-scope name the file can write — is an error, reported at the new
declaration. Like D12, this is the compiler's rule and stays out of the spec
for now.

The fourth question, what `core` declares, turned out not to be one. `core` is
an ordinary package, so the compiler has no more need to know its declarations
than any other package's. D3 says so.

---

## 9. Where the spec is silent

These are this compiler's choices, not the language's, so like D12 and D14
they stay out of the spec.

**Literals.** `true` and `false` have the type `@primitives$Bool`; the spec
names concept types only for numeric and text literals (`syntax.md` §2.8).
`core`'s implicit `Bool` constructor is what makes them a `Bool` at a coercion
site.

**The intrinsic table.** Beyond what the spec names, `intrinsics.ml` holds
what `core` needs to be written at all: the machine arithmetic and comparisons
on `@primitives$Int`, `I32`, `I64` and `Float`, the Boolean operators on
`@primitives$Bool`, concatenation and equality on the opaque
`@primitives$String`, the implicit constructors that carry an
`@concepts$Integer` into `@primitives$Int`, `I32` and `I64`, an
`@concepts$Decimal` into `@primitives$Float` -- the split `types.md` §2.6
makes for `core`'s `Int` and `Float` -- and a `@concepts$Text` into
`@primitives$String`, element access on `@primitives$Array` and
`@primitives$List`, and `push` and `size` on `@primitives$List`.

**A `match` arm is where its `return` goes.** `=> expr` is `{ return expr }`
(`adt.md` §5.1), so a `return` in an arm gives the arm's value, not the verb's.
An `abort` in an arm, and an unhandled abortable call in an arm's `return`, are
the arm aborting: that is what makes the `match` abortable (§5.4), and the
`match` then needs a handler like any abortable expression. Aborting arms must
agree on one abort type.

**A failed case read aborts with `@primitives$Unit`.** `adt.md` §3 makes a
variant's member read abortable without giving it an abort type, and a handler
may bind one.

**Subscript arguments are coercion sites.** They are positional arguments to
a declaration with parameters, and `types.md` §3.9 indexes a `List` with a
literal, `weapons[1]`, which only a coercion site allows.

**An `@concepts$Integer` value parameter is a number parameter only when the
signature uses it as one.** The spec spells an explicit number parameter,
`Array<T, n>(T Type, n @concepts$Integer)`, the same way as a parameter that
takes an integer literal, `implicit Int(value @concepts$Integer)`
(`generics.md` §5.3, §5.4). This compiler makes the first a generic parameter
because the signature writes `n` where a number goes -- here, in the type it
returns -- and the second an ordinary parameter, since nothing in its
signature depends on the value. Both are compile-time integers either way
(`syntax.md` §2.8). The distinction is what keeps D12 affordable: were every
such parameter generic, each distinct literal a program writes would be a new
instance of `Int`'s constructor, and a program with more distinct literals
than the instance limit could not be built. An explicit number and one
inferred from another argument must agree, so `measured(values Array<Int, n>,
n @concepts$Integer)` called with a three-element array and `4` matches
nothing.

**Where constructors and enum maps are found.** A type's constructors are the
ones declared in its home package and in the current package, the order
`functions.md` §6.1 gives methods; an enum map is found the same way. An
import brings a type's constructors with it (`packages.md` §3.5) because they
live in its home.

**A field constructor and a positional one are separate overload sets.** They
are called with different brackets, so no call could confuse the two, and
`types.md` §3.3 gives a type both.

**A generic type named bare in a local declaration** takes its arguments from
the value: `p Pair(Int(1), Int(2))` declares `p` as `Pair`, since the shorthand
writes the constructor's name and a call carries no `< >` (`generics.md`
§5.1).

**`main`** is not required, since a library built on its own is also a root.
When the root declares one, it takes no parameters (`packages.md` §6.2).

---

## 10. Not done yet

- The analyses of D1's right-hand column: moves, stores and lifetimes, resting
  places, effect levels, `spawn` safety beyond the block-parameter rule, and
  block escape beyond a `return` of one. The passing mode (`T` or `&T`) is
  never compared when typing; that is the lifetime analysis's question.
- A generic verb that is never called has no instance, so its body is not
  checked (D12).
