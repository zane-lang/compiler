# Designing the TST

> **Status: draft.** Nothing here is built yet. This is the plan for stage 3 —
> the passes that turn the SST into the typed syntax tree — written down so the
> decisions can be argued with one at a time before any of it is code. Each
> decision is numbered (**D1**…) and each unsettled point is an open question
> (**Q1**…) in §8.

The **TST** is the SST with every name resolved and every expression typed
([`stages.md`](stages.md)). Where the SST answers "what was written, said one
way", the TST answers "what that means": which declaration each name is, which
overload each call picked, which implicit constructor each coercion site
inserted, and what type every expression has. No later stage should ever need
to repeat a lookup.

`lib/tst/` will mirror `lib/sst/`: `nodes.ml` is the tree, `to_tree_graph.ml`
and `to_span_text.ml` render it, `tst.ml` is the entry module. Unlike
`lib/sst/lower.ml`, the pass that builds it is several passes (§3), because
each one needs the tables the previous one built.

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
| Type declarations, aliases, value-downstream ([`memory.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/memory.md) §2.10) | Resting places published with a signature (`lifetimes.md` §1.11) |
| Signatures, inline generic parameters ([`generics.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/generics.md) §3–§4) | Effect-level inference ([`effects.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/effects.md) §3–§5) |
| Overload identity and resolution ([`functions.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/functions.md) §4–§6) | `spawn` safety ([`concurrency.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/concurrency.md) §3–§4) |
| Implicit constructors at coercion sites ([`types.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/types.md) §4) | Block escape ([`control-flow.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/control-flow.md) §2.2) |
| `:`/`!` against `mut` (`functions.md` §2.5) | |
| Abort handlers: required, and every path ends ([`error-handling.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/error-handling.md) §3) | |
| `match` exhaustiveness and one result type ([`adt.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/adt.md) §5) | |
| Every path of a block-bodied verb returns (`functions.md` §3.5) | |

The left column is what the tree cannot be built without: a call cannot have a
callee until overloads are resolved, and cannot have a type until it has a
callee. The right column needs a resolved, typed tree and changes nothing in
it.

Block-taking verbs expanded at the call site (`control-flow.md` §2.3) are
neither. That is a lowering, and it belongs to the OST.

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
stay out of scope. The driver gets a `--package DIR` flag, repeatable. Each file
parses and lowers exactly as today; stage 3 is the first stage that groups
them.

**D3. A minimal `core` is checked in as a test fixture** — `test/core/`, holding
`Int`, `Bool`, `Unit` and `String` over `@primitives$`, their operators, and the
implicit constructors from `@concepts$Number` and `@concepts$Text` that carry
literals into them (`types.md` §2.6). It is the first real multi-file,
multi-package test input. It is also the first code in the repository that has
to type-check. Its exact declarations are not in the spec (**Q4**).

The intrinsic namespaces (`@primitives$`, `@concepts$`, `@controlflow$`,
`@runtime$`, `@program$`) are not packages. They are an OCaml table in
`lib/tst/intrinsics.ml`. Each intrinsic operation has exactly one signature
([`syntax.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/syntax.md)
§2.7), so the table is a plain map, with no overload sets.

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
  | Number_lit | Text_lit                          (* @concepts$Number, @concepts$Text *)
  | Array_lit of t * number                        (* @concepts$Array<T, n> *)
  | Map_lit of t * t                               (* @concepts$Map<K, V> *)
  | Block of t option                              (* @concepts$Block, Block<T> *)
  | Type_concept | Number_concept                  (* Type, Number *)
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

- A literal's type is a concept type. `20` is `@concepts$Number`, not `Int`
  (`syntax.md` §2.8).
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
| Abort handler | Required on every abortable call; the handler's `resolve` values must have the call's success type; every path ends in `resolve`, `return` or `abort` (`error-handling.md` §3.1–§3.2). |
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
`Number_lit`. No later stage re-derives a coercion, and a diagnostic about one
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
| `DotAccess` | field read (a slot index); variant member read (abortable, see **Q2**); enum-map read |
| `TypeMember` | enum member; variant case; named constructor |
| `TypeValue` | a `Type` argument passed to an explicit `Type` parameter (`generics.md` §5.3) |

**D11. Facts for later analyses live beside the tree, not in it.** Effect level
per verb, resting places per parameter, and the list of generic instances are
side tables keyed by `Decl_id`. The tree stays one shape for every consumer.

---

## 7. How to build it

Each step is one PR that ends with `dune runtest` green and a golden file for
what it added, the way the SST landed:

1. `--package DIR` in the driver, and assembly: files grouped by package, a
   package-line mismatch reported. Golden output: the package list.
2. The `core` fixture (D3) and the intrinsic table. At this point the fixture
   only has to parse.
3. Passes 1–2: declaration table and import maps, with a `--decls` dump as the
   golden output.
4. Pass 3 and `Ty`: type declarations, with a `--types` dump.
5. Pass 4: signatures and overload-set checks.
6. Pass 5 for expressions without calls (literals, locals, fields), then calls
   and overload resolution, then coercion, abort handlers, `match`.
   `--tst` renders the tree with a type on every node; `to_span_text` keeps the
   span check the SST has.
7. Generic instantiation (**Q1**).

Reject fixtures grow alongside: one `.zn` per diagnostic, as in
`test/parser/fixtures/reject/`.

---

## 8. Open questions

**Q1. Is a generic verb's body checked once, or once per instantiation?**
The only bounds a parameter can have are `Type` and `Number`
(`generics.md` §3.3). So a body that writes `a + b` on a `T` has nothing to
resolve `+` against until `T` is known. The spec calls types "templated
functions" that are "executed" in an earlier stage ([`foundations.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/foundations.md) §3). That reads as template semantics, but the spec never says when a generic
body is checked. **Recommendation:** check each signature once. Check bodies
once per distinct instantiation, and memoize them by `(Decl_id, args)`. An error
in a generic body is reported at the instantiation that exposed it, and it names
the call site too. This also fits the home-package instantiation plan in
[`generics.md`](generics.md). It needs a spec sentence either way.

**Q2. A variant member read is abortable, but the grammar cannot handle one.**
`adt.md` §3 says a member read of a variant "is therefore an **abortable**
access (`?` / `??`)". The parser only attaches a handler to a call, an operator,
a flip or a `match` (`lib/cst/parser_actions.ml`, `attach_abort_handle`). So
`e.a ?? fallback` is rejected with "an abort handler must follow an abortable
operation". Either the grammar grows a handler on field access, or the spec
narrows variant reads to `match`. That is a spec or grammar decision, and it
blocks typing `DotAccess` on a variant.

**Q3. Can a local shadow another local?** The spec forbids an import from
shadowing (`packages.md` §3.8). It says nothing about a local declared in a
nested block with a name already in scope. **Recommendation:** reject, matching
the import rule's "never shadowing", until the spec says otherwise.

**Q4. What exactly does `core` declare?** `types.md` §2.6 says `core` defines the
fundamental types "over storage primitives" and declares the implicit
constructors from the literal concepts. It does not show the declarations. For
example, is `Int` written `type Int = @primitives$Int` or a struct wrapping
one? The fixture of D3 has to pick one. Whichever it picks is a de facto
proposal for the real `core`, and should be written down as one.
