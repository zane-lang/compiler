# Concepts and primitives

Two intrinsic namespaces carry types no package declares
([`semantics.md`](semantics.md) §4). They sit on opposite sides of lowering.

## Concepts: what the source wrote

`@concepts$` names the types of things that have no storage of their own:

- the literals — `@concepts$Int`, `@concepts$Float`, `@concepts$String`,
  `@concepts$Array<T, n>`, `@concepts$Map<K, V>`;
- a block argument — `@concepts$Block`.

A concept is a type for checking only. A literal reaches a storage type
through an implicit constructor, which the TST writes down as a node of its
own ([`semantics.md`](semantics.md) D9), and a block never becomes a value at
all: the verb that takes it is expanded at its call site ([`lowering.md`](lowering.md) L11). So no concept
reaches the CGT.

## Primitives: what the machine stores

`@primitives$` names storage: `Int`, `I32`, `I64`, `Float`, `Bool`, `Unit`,
`String`, `Array<T, n>`, `List<T>`. `core` builds the fundamental types on
them — its `Int` is a struct around an `@primitives$Int` — and any package may
use them the same way.

Lowering gives each primitive its machine layout ([`lowering.md`](lowering.md)
L5): `@primitives$Int` is an `i64`, `Bool` an `i1`, `Float` a `double`, and
`String` and `List` are handles whose payload lives in the dynamic region.
A struct around one primitive has that primitive's layout, so `core`'s `Int`
costs what an `i64` costs.

## Why the line is there

Concepts let a literal or a block be checked before anything knows where it
will be stored: `20` is an `Integer` until a parameter or a field says which
integer type it becomes. Primitives are the opposite: they say exactly what
the machine holds, and nothing about how the source spelled it. Keeping them
apart means the front end reports errors in the terms the author wrote, and
codegen sees only types with a layout.
