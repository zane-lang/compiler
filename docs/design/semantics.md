# Semantics: designing the TST

> **Status: built.** Stage 3 — the passes that turn the SST into the typed
> syntax tree — follows this design. Each decision is numbered (**D1**…). The
> questions the first draft left open are answered in §8. Where the spec is
> silent and the compiler had to choose, §9 says what it chose.

The **TST** is the SST with every name resolved and every expression typed
([`stages.md`](stages.md)). Where the SST answers "what was written, said one
way", the TST answers "what that means": which declaration each name is, which
overload each call picked, which implicit constructor each coercion site
inserted, and what type every expression has. No later stage should ever need
to repeat a lookup.

`lib/tst/` mirrors `lib/sst/` where it can: `model/nodes.ml` is the tree,
`render/to_tree_graph.ml` renders it, `render/to_span_text.ml` reads its spans
back out of the source, and `tst.ml` is the entry module. Unlike
`lib/sst/lower.ml`, the code that builds it is several passes (§3), because
each one needs the tables the previous one built. The subdirectories group the
modules by kind; module names stay flat, so `passes/collect.ml` is `Collect`:

| Module | Holds |
|---|---|
| `passes/assembly.ml` | The packages, read from their directories (§2) |
| `model/env.ml` | The declaration tables, each file's import map, and the diagnostics: one `Env.t` per check, passed to every pass |
| `passes/collect.ml` | Passes 1 and 2 |
| `passes/type_decls.ml` | Type-expression resolution, and pass 3 |
| `passes/verb_signatures.ml` | Pass 4 |
| `check/` | Pass 5, with overload resolution and instantiation |
| `model/ty.ml`, `model/signature.ml` | Types (§4), and what a call site needs to know about a verb |
| `model/intrinsics.ml` | The intrinsic namespaces (D3) |
| `analyses/` | The analyses over the finished tree (D1) |
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
caller needs — a parameter's resting place — the fact goes in a
side table keyed by declaration, not into the tree.

That splits the work like this:

| Built with the tree (milestone 1) | Analyses over the tree (later) |
|---|---|
| Package assembly and imports ([`packages.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/packages.md) §2–§3) | Moves, stores and lifetimes ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/lifetimes.md) §1) |
| Type declarations, aliases, value-downstream ([`memory.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/memory.md) §2.10) | Resting places published with a signature ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/lifetimes.md) §1.11) |
| Signatures, inline generic parameters ([`generics.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/generics.md) §3–§4) | Read-only references: a reference derived from a parameter stays read-only ([`effects.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/effects.md) §4.4) |
| Overload identity and resolution ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §4–§6) | `spawn` safety ([`concurrency.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/concurrency.md) §3–§4) |
| Implicit constructors at coercion sites ([`types.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/types.md) §4) | |
| `:`/`!` against `mut` ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §2.5) | |
| No write to a read-only binding: an assignment or a `!` call ([`effects.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/effects.md) §4.1) | |
| Abort handlers: required, and every path ends ([`error-handling.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/error-handling.md) §3) | |
| `match` exhaustiveness and one result type ([`adt.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/adt.md) §5) | |
| Every path of a block-bodied verb returns ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §3.5) | |
| A block never escapes: not returned, not stored, not a type argument of what a call builds ([`control-flow.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/control-flow.md) §2.2) | |

The left column is what the tree cannot be built without: a call cannot have a
callee until overloads are resolved, and cannot have a type until it has a
callee. The right column needs a resolved, typed tree and changes nothing in
it.

Block-taking verbs expanded at the call site (`control-flow.md` §2.3) are
neither. That is a lowering, and it belongs to the lowering stage, which builds the CGT.

Whether a call reads or writes capability-backed state
([`effects.md`](https://github.com/zane-lang/spec/blob/01da08e/spec/effects.md) §5.2) is not a semantic check either. No program is
rejected for it: it decides only what may be evaluated at compile time or
run in parallel, which is stage 5's to decide
([`optimization.md`](optimization.md) O3).

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
- `Int` is not built in. [`types.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/types.md) §2.6 makes it a declaration in `core`, "an
  ordinary package", and a file that writes it imports `core` like any other
  dependency. Without one, a program writes the storage primitives
  (`@primitives$Int`) directly or declares its own types over them.

**D2. Semantics takes a set of packages: the root plus its dependencies, each
given as a directory.** Fetching, versioning and the manifest
([`dependencies.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/dependencies.md))
stay out of scope: they are `zane`'s, which reads the manifest and hands the
compiler each package as `--package NAME=DIR`, repeatable, the first being the
root (`packages.md` §6.1). Each file parses and lowers exactly as today; stage
3 is the first stage that groups them. `lib/tst/passes/assembly.ml` does the
grouping: a package is the `.zn` files directly in its directory (§2.3), named
by the `NAME` its manifest gives it (§2.1), or for the directory when a bare
`--package DIR` gives none, which is how the test fixtures name theirs. Each
file must begin with a `package` line naming it (§2.2). A package given a
stamp is known by its stamped name, and no two packages may share that
identity; a package's imports name packages through the keys the driver
gives it, or by name when it gives none
([`separate-compilation.md`](separate-compilation.md) C10). `--check` runs semantics and prints nothing, and
`--kind application` makes a root without `main` an error (§6.2).

**D3. The compiler never names `core`.** `core` is an ordinary package
([`types.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/types.md) §2.6), so the compiler reads it as source and checks it by the
same rules as every other package, and names none of its members. Whether
`Int` is a distinct type over `@primitives$Int` or a struct wrapping one is
`core`'s own choice, and the compiler does not care which it makes, just as it
does not care how any other package writes its types.

The repository has no `core` yet. Each test fixture writes the storage
primitives directly, usually under aliases of its own
(`alias Int = @primitives$Int`), and declares what its test is about: a type
with implicit constructors from the literal concepts, or the control-flow
verbs of [`control-flow.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/control-flow.md) §3 over `@controlflow$`.

The intrinsic namespaces (`@primitives$`, `@concepts$`, `@controlflow$`,
`@runtime$`, `@program$`) are not packages. They are an OCaml table in
`lib/tst/model/intrinsics.ml`. Each intrinsic operation has exactly one signature
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
   (`types.md` §5.3); value-downstream (`memory.md` §2.10); `&` and `^` only
   on a reference type, and `^` only on a local, a parameter or a return type
   ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.1, §2.4, [`syntax.md`](https://github.com/zane-lang/spec/blob/911d749/spec/syntax.md)
   §2.3); a type argument of the wrong kind, reported where it is written
   ([`generics.md`](https://github.com/zane-lang/spec/blob/911d749/spec/generics.md) §3.6),
   including a `^` or a `List` element filled with an `&` type, and through
   a generic alias as through the type it names.
4. **Signatures.** Resolve every verb's parameter and return types, introducing
   inline generic parameters at their first marked occurrence (`generics.md`
   §3.2, §4.4). Check here:
   - overload identity, including no overloads that differ only by passing mode
     (`T`, `^T` or `&T`) or by the `mut` of a function-type parameter
     (`functions.md` §4.1);
   - a reference-typed result or abort type written `^T` or `&T`, never bare,
     and no marker on `this` ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.9);
   - the operator home-package rule ([`operators.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/operators.md) §2.2);
   - implicit-constructor source and destination kinds, and the orphan rule
     (`types.md` §4.4–§4.5);
   - enum-map exhaustiveness (`adt.md` §6).
5. **Bodies.** Type every verb body, constant, and enum-map entry against the
   signatures. Every signature is known before this pass starts, so bodies
   check in any order, which is what "order-independent" asks for (§2.3).

Then the analyses of D1's right-hand column run over the finished tree.

**Read-only references** (`lib/tst/analyses/read_only.ml`,
[`effects.md`](https://github.com/zane-lang/spec/blob/b0675d6/spec/effects.md) §4.4): a `!` call whose subject reaches a reference taken from
a read-only binding is an error. It follows each
reference through locals, fields, arguments and returns, and summarises every verb
by which parameters reach its result and which come to rest in its `this`, the
resting places of `lifetimes.md` §1.11 without their owners. A call substitutes
its arguments into the callee's summary; summaries are computed to a fixed
point first, because verbs may call each other in a cycle.

**States** (`lib/tst/analyses/states.ml`, [`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.1,
§2.8.1). The one function the three analyses below read to know what state
the place an expression denotes is in:
- **settled**: a bare reference-type local or a package constant, what a
  reference names, and a struct field or `ArrayRef` element of a settled root;
- **roaming**: a local or parameter declared `^T`, and a field or `ArrayRef`
  element of one;
- **borrowed**: a bare reference-type parameter, `this`, and what is reached
  from either;
- **contingent**: a list's element, a variant's payload, a case read, a
  `match` binder, and a member of a temporary — storage that is neither an
  owner a store may move from nor a place a reference may name;
- **fresh**: a verb's result, a case form, or any other value nothing owns.

A declared subscript is followed through its body to the projection it ends
at ([`functions.md`](https://github.com/zane-lang/spec/blob/911d749/spec/functions.md) §2.9), so it is settled exactly
when that projection is an `ArrayRef` element of a settled root. Every answer
comes from declared types along the path, so it is the same at every point of
the body.

**References** (`lib/tst/analyses/references.ml`) are the store rules that
need nothing but the store in hand:
- a new reference is minted only from a settled place ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md)
  §2.8); a value that is already a reference is copied, from anywhere;
- a store never goes through a reference, unless that reference is a
  parameter the path starts at ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.1).

A borrow needs no rule of its own: it is no place to mint from and no owner
to move from, so it is never stored or returned
([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.9).

**Moves** (`lib/tst/analyses/moves.ml`, [`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.2–§1.3, §1.6, §1.8). A
reference-type value stored where an owner goes — an owning local or field, a
`^T` parameter, a return, an element, a case payload — is moved:
- only a roaming symbol, a field of one, a verb's result or a case form is
  moved; a settled owner, a borrow, `this`, an element, a case payload, a
  package constant and a reference are not;
- a bare reference-type parameter is a borrow, so passing to one moves
  nothing;
- a roaming symbol is moved only in the block that declares it, and a
  parameter is declared at the top of the body;
- a moved symbol is spent: using it is an error until a store refills it, in
  that same block. A field moved out of a roaming symbol leaves that field
  spent and the symbol spent as a whole, until a store in the symbol's block
  refills the field ([`memory.md`](https://github.com/zane-lang/spec/blob/911d749/spec/memory.md) §2.8.1).

A symbol is spent or refilled only in its own block, and a nested block can do
neither, so one walk in source order sees every use against the right state.

**Scopes** (`lib/tst/analyses/scopes.ml`, [`lifetimes.md`](https://github.com/zane-lang/spec/blob/911d749/spec/lifetimes.md) §1.1, §1.4, §1.7, §1.10, §1.11). A
local's scope is its declaring block, a field's or element's is its root's,
and a `^T` parameter's is the body's top block; any other parameter and
`init{ }` stand for the call site, which outlives the body. A value names the
scopes of the owners it reaches through a reference, its own and those it
carries. A `let`, an assignment, a field of `init{ }` and a return are legal
only when every scope the value names outlives the destination's. A move
needs no check of its own (§1.4): a symbol moves only in its declaring block,
so the owner it moves into is declared there or above.

A store from one parameter into a place reached from another is where the first
comes to rest (§1.11), whether it is a reference or a `^T` parameter carrying
one. It goes in the verb's summary, as a pair of parameter
indices, and each call makes that store with its own arguments and compares
there. A call in a body can store one parameter into another in turn, so the
summaries are computed to a fixed point over every body before any reports.

**Exits** (`lib/tst/analyses/exits.ml`, [`docs/spec-divergences.md`](../spec-divergences.md)
§10). A verb exits when `@controlflow$exitFromCall` is in its own frame: its
body, or a block written there. A call to one ends the run of the block it is
written in, so it is an error in no block. A lambda's own frame holds no
`@controlflow$exitFromCall` at all
([`control-flow.md`](https://github.com/zane-lang/spec/blob/b1fcaba/spec/control-flow.md)
§4.2): it is called through a function value, whose type does not say that it
exits.
The root's `main` cannot exit either: the runtime calls it from no block
([`packages.md`](https://github.com/zane-lang/spec/blob/b1fcaba/spec/packages.md) §6.2).

**Expansions** (`lib/tst/analyses/expansions.ml`). A verb that takes a block
or a literal has no function of its own: each call to it is written out in
place of the call ([`lowering.md`](lowering.md) L11). So such a verb is an
error when its body reaches a call to itself, directly or through other such
verbs. A call written in a lambda does not count, since a lambda is a
function of its own.

**Literal ranges** (`lib/tst/analyses/literal_ranges.ml`,
[`types.md`](https://github.com/zane-lang/spec/blob/b1fcaba/spec/types.md) §2.7).
A storage primitive's constructor embeds its literal, which must fit it:
`@primitives$Int` and `I64` a 64-bit integer, `I32` a 32-bit one, and `Float`
a finite double. A literal handed to a verb's literal parameter reaches its
constructor only where the verb is written out, so lowering checks that one.

**Spawns** (`lib/tst/analyses/spawns.ml`, [`concurrency.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/concurrency.md) §4.2–§4.3). A
spawned `mut` call writes its subject, so a subject of a reference type, or a
reference to one, is an error. A spawn written as a statement or bound by a `let`
borrows its subject's place until the block it is written in drains, since
the drain waits for it; one read where it is written is waited for at once and
borrows nothing past itself. While a borrow lasts, a second spawn borrowing
an overlapping place is an error, and so is any read or write of one in that
block or a block inside it. Two places overlap when one's path of fields and
cases is a prefix of the other's, and any two elements of one list overlap.
A place reached through a reference is the place the reference names, followed
as below for a lent owner; where the checker cannot follow it, two places may
overlap when either's type may hold the other's. A spawned subject's index,
or its case read's handler, is read at the spawn like any other read.
In a block that runs more than once, a spawn takes its subject from a local
declared in that block or in a block inside it. A block runs more than once
when it is `@controlflow$repeat`'s body, a block argument to a function
value, or a block argument at a position its verb runs more than once: one
it passes on to such a position or to a function value, or passes anywhere
from inside a block that runs more than once, computed to a fixed
point over every body (`lib/tst/analyses/repeats.ml`, which the read-only
analysis reads too).

The same spawn is lent every owner passed to it, directly or through a reference,
until the same drain, and the block may not write one meanwhile
([`spec-divergences.md`](../spec-divergences.md) §13): not by assignment, not as
a `!` call's subject, not by moving it out. A spawned `mut` call on part of it
is allowed, since it writes back (docs/design/lowering.md §9). Where a write goes
through a reference, the checker follows the reference to the place it was
minted from, through other references, as long as the reference has not been
bound again in a block inside its own. A reference whose place it cannot
follow may name any owner of its type, so a write through it clashes with a
lent owner that could be, or contain, or be inside, what it writes; so does a
write to a known place when the lent owner came through such a reference.

**D4. Diagnostics accumulate.** The parser stops at the first error, which suits
a parser. A type checker that stops at the first error fails the author once per
mistake. Each pass collects diagnostics and keeps going. An expression that
failed to type gets the type `Ty.Error`, which every check accepts silently. One
mistake then gives one error, not a cascade. The driver prints them all and
exits non-zero if there is any.

---

## 4. Types

```ocaml
(* lib/tst/model/ty.ml *)
type t =
  | Named of { id : Type_id.t; args : arg list }  (* a declared type, applied *)
  | Reference of t                                (* &T *)
  | Roaming of t                                  (* ^T *)
  | Primitive of Primitive.t                      (* @primitives$Int, ... *)
  | Concept of concept                            (* literals, blocks *)
  | Verb of verb                                  (* a function type *)
  | Param of Param_id.t                           (* inside a generic declaration *)
  | Error                                         (* see D4 *)

and arg = Type of t | Number of number
and number = Known of int | Param_num of Param_id.t

and concept =
  | Integer_lit | Decimal_lit | Text_lit           (* @concepts$Int, Float, String *)
  | Array_lit of t * number                        (* @concepts$Array<T, n> *)
  | Map_lit of t * t                               (* @concepts$Map<K, V> *)
  | Block                                          (* @concepts$Block *)
  | Type_concept                                  (* Type *)
```

**D5. An `alias` is expanded when it is resolved, and a `type` gets an identity
of its own.** An alias is "an interchangeable alternate name"
(`types.md` §5.2), so after pass 3 it has no identity left to carry. A `type`
is "structurally equal to its right-hand side but not interchangeable with it"
(§5.1). So it gets a fresh `Type_id`, and its right-hand side is stored in the
type table as its definition. Type equality is then plain structural equality on
`Ty.t`, with no alias-chasing.

`Type_id` is the defining package's identity
([`separate-compilation.md`](separate-compilation.md) C10) plus the name. That is also how a symbol will
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

- A literal's type is a concept type. `20` is `@concepts$Int` and `2.5`
  is `@concepts$Float`, not `Int` or `Float` (`syntax.md` §2.8,
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
| Block argument | Typed `@concepts$Block`: a block yields nothing ([`spec-divergences.md`](../spec-divergences.md) §11). |
| Collection literal | `@concepts$Array<T, n>` when every element has the same concrete type `T`; with a bare literal element it fixes no `T` and cannot drive inference (`generics.md` §5.4). |

---

## 6. The tree

`lib/tst/model/nodes.ml` follows the SST rule: it is the SST's tree with the
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
therefore a `Coerce` of that type's implicit constructor from `@concepts$Int`
around an `Integer_lit`. No later stage re-derives a coercion, and a diagnostic about one
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
(D12), which the tree lists after the packages. A field constructor's
defaults (`types.md` §3.3) are typed where it is declared, and the tree lists
them last, per entry slot: a declaration's, and each instance's of a generic
one, so a call that leaves an entry out passes the default its instance
typed.

**D11. Facts for later analyses live beside the tree, not in it.** Resting
places per parameter and the list of generic instances are side tables keyed
by `Decl_id`. The tree stays one shape for every consumer.

---

## 7. How it was built, and how to look at it

Each step of the plan ended with `dune runtest` green and a golden file for
what it added, the way the SST landed:

1. `--package DIR` in the driver, and assembly: files grouped by package, a
   package-line mismatch reported.
2. The intrinsic table.
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
The goldens in `tests/semantics/golden/` are those views: `typing.accept.decls` and
`typing.accept.tst` for a build of `app` and `shapes` that checks, and
`typing.reject.err` for a build that fails every way the passes can report, one
fixture file per area.

`typing.accept.tst.spans` checks the spans of the same build, the way
`tests/parser/golden/` checks the CST's and SST's: `span_dump --tst` takes the
same `--package` flags and prints every node of the typed tree, generic
instances included, with the source text its span covers. The TST is built
from many files, so each line reads its text out of the file its own span
names. A node the checker built -- a `Coerce`, a parameter's local -- shows
there what it points at.

## 8. Answered questions

The first draft left four questions open. These are the answers.

**D12. A generic verb's body is checked once per instantiation, as a C++
template is.** A parameter's only bound is `Type` or `@concepts$Int`
(`generics.md` §3.3). So a body that writes `a + b` on a `T` has nothing to
resolve `+` against until `T` is known. The signature is checked once. The body
is checked once per distinct set of arguments, memoized by `(Decl_id, args)`,
and the TST holds one body per instance. An error in a generic body is reported
at the instantiation that exposed it, and names the call site that asked for
it.

A generic verb nothing instantiates is checked once more, where it is
declared, so an unused one is not an unchecked one. Its type parameters stand
for the type of an expression that failed to type, which every check accepts
(D4): what depends on `T` waits for an instance, and what does not -- a name
that resolves nowhere, `Int(1) + String("a")` -- is reported, since it is
wrong in every instance. Its number parameters stay symbolic. That check asks
for no instances, and nothing from it enters the tree. This fits the
home-package instantiation plan in
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
A package's implicit constructor from `@primitives$Bool` is what makes them
its own boolean type at a coercion site.

**The intrinsic table.** Beyond what the spec names, `intrinsics.ml` holds
what a `core` needs to be written at all: the machine arithmetic and comparisons
on `@primitives$Int`, `I32`, `I64` and `Float`, the Boolean operators on
`@primitives$Bool`, concatenation and equality on the opaque
`@primitives$String`, the constructors, none of them implicit
(`types.md` §2.7), that build an `@primitives$Int`, `I32` or `I64` from an
`@concepts$Int`, an `@primitives$Float` from an `@concepts$Float` -- the
split `types.md` §2.6 makes for `core`'s `Int` and `Float` -- and an
`@primitives$String` from an `@concepts$String`, element access on `@primitives$Array` and
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

**An `@concepts$Int` value parameter is a number parameter only when the
verb uses it as one.** The spec spells an explicit number parameter,
`Array<T, n>(T Type, n @concepts$Int)`, the same way as a parameter that
takes an integer literal, `implicit Int(value @concepts$Int)`
(`generics.md` §5.3, §5.4). This compiler decides from the uses rather than
the concept: a parameter is generic when the verb puts its name where a number
goes. That is either a type the verb writes -- in its signature, or in its
body's local declarations and lambdas -- or an argument to another verb's
number parameter. `Array<T, n>` writes `n` in the type it returns, so `n` is
generic; `relayed(values Array<Int, 3>, n @concepts$Int) =>
measured(values, n)` hands `n` to `measured`'s number parameter, so it is
generic too; nothing in `Int`'s constructor depends on `value`, so `value` is
an ordinary parameter. A generic and an ordinary `@concepts$Int` parameter
are compile-time integers either way (`syntax.md` §2.8). The distinction is
what keeps D12 affordable: were every such parameter generic, each distinct
literal a program writes would be a new instance of `Int`'s constructor, and a
program with more distinct literals than the instance limit could not be
built.

Whether a callee's parameter is a number parameter can itself turn on the
callee's body, so pass 4 settles this for the whole build before it builds a
signature: it starts from what the types say and promotes a parameter
whenever a call hands it, by name, to a number parameter of some candidate
with the right arity, until nothing changes. Chains resolve, and a cycle of
calls that never reaches a number parameter stays ordinary. The candidates are
matched by name, ahead of overload resolution, so a call that resolves to an
overload the promotion did not anticipate leaves a parameter generic that did
not need to be; that costs instances, never correctness.

An explicit number and one inferred from another argument must agree, so
`measured(values Array<Int, n>, n @concepts$Int)` called with a
three-element array and `4` matches nothing.

**Borrows** (`lib/tst/analyses/borrows.ml`, [`memory.md`](https://github.com/zane-lang/spec/blob/2a02e33/spec/memory.md) §2.9.1,
[`adt.md`](https://github.com/zane-lang/spec/blob/2a02e33/spec/adt.md) §5.1). A call's borrows are its subject and each argument
passed to a bare parameter, or to a `^T` filled with a value type; an `&T`
argument is not one. A call is an error when a borrow overlaps a place
written by its `mut` subject (for a borrow argument), by a block argument, or
by an argument written after it. A part writes a place it assigns, makes the
subject of a `!` call, or moves an owner out of; a lambda in it writes
nothing. A `!` call also writes what its subject reaches through a
reference it holds, in a field or an element, and passing on a block
parameter writes whatever the caller's block does. Places overlap as for spawns. A reference local stands for every place
any of its bindings names, its declaration and every repointing anywhere in
the body, since a loop body or block argument may repoint it before the
next run of earlier statements. An `&T` parameter is a root of its own,
apart from the subject and the block parameters; where the body relies on
that, the verb's summary records the pair, and each call checks it against
the arguments it passes, or records it in turn when it passes its own `&T`
parameter along. Summaries are computed to a fixed point, as for scopes. A
call through a function value, which carries no summary, keeps every `&T`
argument apart from its `mut` subject and its block arguments. Any other
path through a reference, an `&` field or a call's result, is unknown and
judged by type; a place the body owns, the subject and a borrowed parameter
are never inside one, since the caller keeps them apart. Constant, enum-map
and subscript bodies are walked like verb bodies. This holds for value-type arguments too: a value
parameter is a borrow, so `if(dirty) { dirty = false; }` is an error. While a
`match` binder names its scrutinee's payload, the arm writes the scrutinee
only through the binder.

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

**What the read-only analysis assumes where it cannot see.** Each choice can
only reject more, never let a write through.
- An intrinsic, or a call through a function value, has no body to summarise.
  It is taken to hand every argument back in its result and, when it writes its
  subject, to store every argument there — each only where the parameter's type
  can hold a reference.
- A path into a value is cut at four steps, since a recursive type would let
  one grow without end. A cut path names the place that contains the real one.
- A block argument that runs more than once (as for spawns, above) leaves a
  local holding what any run stored. It is walked again, each run joined into
  the last, until a run adds nothing, and then once more to report, so every
  run is checked against what the runs before it stored. A block that runs at
  most once is walked once.
- A generic verb's summary is the union over its instances.

**What the scope analysis assumes.** Each choice can only reject more.
- A local names everything ever stored in it, at any path: the body is walked
  until that stops growing, then once more to report.
- A call's result names what each argument names as its parameter takes it,
  a reference parameter adding the scope of the place it is minted from: a
  verb may return a reference rooted in any `&T` parameter (`lifetimes.md`
  §1.7).
- A resting place (§1.11) is kept as the pair of parameters, not the path
  between them. Every step of a path takes its root's scope, so the call
  compares the scope of the argument's place, or, for an argument that is a
  reference, the scopes it names.
- A value read through a reference parameter, `other.port`, names that
  parameter's owner. A reference the owner carries outlives the owner (§1.1),
  so the owner is the shorter of the two.
- `push` keeps its value in `this`; no other intrinsic keeps anything. A
  function type carries no summary, so a call through a function value that
  writes its subject is taken to keep every argument there
  ([`lifetimes.md`](https://github.com/zane-lang/spec/blob/2a02e33/spec/lifetimes.md) §1.11).

**What moves, where the spec leaves it to the table.**
- A subscript's body is a place (`functions.md` §2.9), so it moves nothing
  out; reading `list[i]` into an owner is what the move rule then rejects.
- A case read and what its handler resolves are a place too: the store the
  whole expression feeds decides whether it moves.
- An intrinsic operator or constructor reads its operands, and `push` takes
  its value as `^T`.
- `^T` describes a place, not a value, so no expression's type carries it: a
  `^T` local read, and a call returning `^T`, are values of type `T`. What a
  place holds is read from the local's or the signature's declared type.

**Where a reference source is decided.**
- A `match` binder is its case's payload, so no reference is minted from it.
- A method's subject is a borrow the call lends, not storage, so a call never
  mints one for it: `list[i]:inspect()` is a read.

**Where a wrong-kind type argument is reported** (`generics.md` §3.6). An
explicit argument, in a type written anywhere, is reported where it is
written. An inferred one is reported at the value argument it was read from,
when the instance's own signature puts it in a value mould's field; that
instance is then not made, so nothing inside a forwarding verb reports it
again. A mistake that only a generic body's own code makes, and that its
signature does not show, is reported inside the instance, which names the
instance and the call that required it, from any analysis.

**Where `^` is written, beyond what the spec shows.**
- A function type's `^T` result over a type parameter is filled by a value
  type's result written bare: `ArrayRef.fill`'s lambda is `^T[Int]`, and an
  `Int(n Int)` lambda fills it with `T` = `Int`.

**`main`** is not required, since a library built on its own is also a root.
When the root declares one, it takes no parameters, and it may return any
type, whose value is discarded (`packages.md` §6.2).
