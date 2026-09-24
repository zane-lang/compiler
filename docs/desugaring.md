# What the SST desugars

The **SST** — simplified syntax tree — is the stage between the CST and the
typed tree: still untyped, but fully desugared. This file is the inventory of
what "fully desugared" means, so the SST's node set can be justified one entry
at a time rather than argued about as a whole.

`lib/sst/` mirrors `lib/cst/`: `nodes.ml` is the tree, `to_tree_graph.ml`
renders it, `sst.ml` is the entry module, and `lower.ml` is the pass that
builds one from the other. This file is the argument for what is in them.

The compiler binary prints either tree — `--cst` for what the source says,
`--sst` for what it means.

Entries were checked against spec commit
[`034f11a`](https://github.com/zane-lang/spec/tree/034f11a), the same commit
[`spec-divergences.md`](spec-divergences.md) is pinned to, and against
`lib/cst/nodes.ml` as it stands. Links point at that commit so a later spec
edit cannot silently make a quotation here disagree with what it links to.

---

## The rule for what belongs here

A rewrite belongs in the SST when it needs **nothing but the syntax tree**. The
CST is a whole package's worth of source, so "nothing but the syntax" includes
looking at another declaration in the same file — but it stops at the file
boundary and it stops at types. A rewrite that has to know what a name refers
to, what package a member came from, or what type an expression has is not a
desugaring; it is name resolution or type checking wearing a desugaring's
clothes. Those are listed in §4 so they are refused deliberately rather than
attempted and abandoned.

Two rewrites sit right on that line — the instantiation shorthand of §2.7 and
the method-call rewrite of §2.11 — and both say so where they appear.

### Spans

Every node the SST synthesizes takes the span of the surface syntax it was
desugared from. `a - b` becomes `a + ~b`, and the `~` node that never existed
in the source takes the span of the `-` that produced it; the `+` takes the
same span the original `Op` node had. Nothing in this document needs
`Span.none`, and it should stay unused after the SST lands.

This is worth holding to, because it keeps the SST checkable by the same means
as the CST: `Sst.To_span_text` renders each node against the source its span
covers, exactly as `Cst.To_span_text` does for the parsed tree, and
`span_dump --sst` prints it. A synthesized node pointing nowhere
would read as a bug the moment it printed.

---

## 1. Already desugared, in the parser

One rewrite is done already. It is listed so the SST does not redo it, and
because it is a place where the parser reaches past what
[`stages.md`](stages.md) says it does.

| Form | Becomes | Where |
|---|---|---|
| `name ReturnType(params) { body }` (lambda-variable) | `Decl.Var { name; type_ = <the function type>; value = <the lambda> }` | `lib/cst/parser.mly`, via `Nodes.func_type_of_lambda` |

The lambda-variable expansion is the one
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.8 spells out in full, and `func_type_of_lambda` / `meth_type_of_lambda`
build the function type it calls for.

The loose operators used to be the second entry here. They are now §2.2
instead: the parser records the `'` prefix and the SST drops it, because a
parser that collapsed the two spellings was deciding something the CST's own
rule reserves for later.

---

## 2. The desugarings

All eleven are implemented in `lib/sst/lower.ml`, one function each, and
`test/parser/fixtures/desugar.zn` is the fixture that exercises them: every rewrite
below appears in it at least once. Two expectations in `test/parser/golden/`
carry it. `desugar.sst.spans` prints each node's variant against the source its
span covers, so a rewrite that stops happening is a diff and so is a span that
moves. `desugar.sst.tree` renders the same file as a named-field tree, and sits
beside `desugar.cst.tree` — reading the two together is the shortest statement
of what this section does.

Ordered roughly by how much each simplifies the tree. None depends on another
— every one is a local rewrite.

### 2.1 `=> expr` bodies

```
ReturnType name(params) => expr     ->  ReturnType name(params) { return expr; }
```

[`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md)
§3.4 is unusually direct about this: `=> expr` is "**purely a surface
shorthand**: it means exactly `{ return expr }` and adds no other behavior."
[`types.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/types.md) §3.2
says the same for a constructor's `=> init{...}`, and
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.2 adds that it returns `expr` "including when `expr` has type `Unit`", so
there is no case that needs different treatment.

**CST → SST.** `Body.t` loses its `Shorthand` arm and becomes a statement list.
That is the single biggest reduction on this list, because `Body.t` is reached
from nine places: functions, methods, operators, `~` declarations,
constructors, both lambda kinds, match arms, and abort handlers.

**Sites.** Every verb declaration (`Verb_decl.Func`, `.Meth`, `.Op`,
`.Constructor`, `.Flip`), both lambdas (`Func_lambda`, `Meth_lambda`), and
match arms (`Match_arm.body`).

### 2.2 Loose operators

```
a '* b    ->    a * b
```

[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§3.1: a loose operator "calls the same implementation as its unprefixed form
and differs only in where it groups". Where it groups is settled by the parser,
so by the time the node exists the `'` has already done its whole job.

**CST → SST.** `Operator.is_loose` goes.

That flag is the CST's half of this entry, and it is worth saying why it exists
at all, because the obvious thing is for the parser to drop the prefix on the
spot — which is what it used to do. Two reasons not to. The CST's stated job is
to represent what was parsed, and `a '* b` and `a * b` are two different pieces
of source; a tree that cannot tell them apart cannot be rendered back to say
which the file held, which is what `to_tree_graph` is for.
[`stages.md`](stages.md) is the other: desugaring belongs to the semantics
stage, and a parser that collapses the two spellings is doing semantics work in
the one stage that is supposed to be a transcription.

Neither reason is about diagnostics. The spec's one illegal loose form,
`a ''* b`, is rejected by the grammar before any `Operator.t` exists, so no
flag on the node could be what reports it.

The flag is always `false` on a declaration. §3.1 is explicit that the loose
forms "add no token to the operator vocabulary" of §5.1, so there is nothing
for a program to declare, and the declaration productions read the unprefixed
rules only.

This is the cheapest entry on the list — the SST reads one field and ignores it
— and it is the one that keeps the boundary in `stages.md` true.

### 2.3 Derived operators

[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.3 gives five fixed desugarings and says they are "**not** independently
implementable":

| Written | Becomes | Operands swapped? |
|---|---|---|
| `a - b` | `a + ~b` | no |
| `a ~= b` | `~(a == b)` | no |
| `a > b` | `b < a` | **yes** |
| `a <= b` | `~(b < a)` | **yes** |
| `a >= b` | `~(a < b)` | no |

This is not optional in the way most entries here are. The spec's promise is
that "if a type provides `<` for an operand pair, users automatically get `>`,
`<=`, and `>=` for that same pair" — a compiler that keeps `>` as its own node
has to either implement it separately, which the spec forbids, or do this
rewrite later anyway.

**CST → SST.** `Operator.t` drops from ten variants to five: `Add`, `Mul`,
`Div`, `Eq`, `Less`. `Sub`, `NotEq`, `More`, `LessEq` and `MoreEq` disappear.

**Two of the five swap their operands, and evaluation order survives it.**
Operands are evaluated left to right, in written order, whatever operator they
reach. The spec pinned above says nothing about operand order; spec
[#184](https://github.com/zane-lang/spec/issues/184) raised the gap, and spec
[#199](https://github.com/zane-lang/spec/pull/199) adds this rule to
`operators.md` §2.3. An operator is an ordinary verb and only `~` must be pure
(§4.1), so `f(log) > g(log)` can make two observable writes, and `f` has to make
its write first.

So a swapped call keeps its operands where they were written and says the
swap in a flag. `a > b` is an `Op` of `Less` with `left` `a`, `right` `b` and
`swapped` set: evaluate `a`, evaluate `b`, then call `<` with `b` as its first
argument. `a <= b` is the same call under a `Flip`. That costs one field on `Op`
and no nodes; the alternative, binding both operands to temporaries ahead of a
reordered call, needs an expression that binds, which the SST has no other use
for.

**This rewrite needed a guard first, and it is in place.** See §3.

### 2.4 `??` fallback handlers

```
expr ?? fallback    ->    expr ? { resolve fallback; }
```

[`error-handling.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/error-handling.md)
§3.3 states it as a desugaring in as many words: "`expr ?? fallback` desugars
to a `?` block that only resolves a default value."

**CST → SST.** `Abort_handle.t` loses its `Shorthand` arm and becomes a plain
record.

**No binder is synthesized.** An earlier draft of this file said one would be,
on the grounds that §3.1 requires a written binder even when the abort type is
`Unit`. That rule is about what a `?` handler must write, and `??` is the form
that writes neither the binder nor the block; inventing an identifier no source
could collide with, to bind a value the expanded body does not mention, would
have been a name that exists only to satisfy a reading of the rule that does
not apply to it. The field stays `Name.t option`, which is what the CST already
carries, and `??` leaves it `None`.

### 2.5 Match case groups

```
x [ident, qualifiedIdent] => body ;   ->   x ident => body ;
                                           x qualifiedIdent => body ;
```

[`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §5.1
calls a `[ ]` group "**shorthand for one arm per listed case**", each binding
the binder "at *its own* case's payload". That last clause is the reason to
expand rather than keep the group: the binder's type differs per arm, so the
expanded arms are exactly what a later pass needs to check independently.

**CST → SST.** `Match_pattern.cases : Name.t list` becomes a single
`Name.t`.

**With several scrutinees the expansion is a cross product, and the arms
share one body.** `[a, b], [c, d] => body` expands to four arms, one per
combination, and all four point at the same `body` node. So the expansion costs
one arm record per combination, and the body is never copied. The combinations
cannot be avoided:
[`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §5.6
requires every combination to be covered and has no wildcard, so an arm that
ignores a scrutinee names every one of its cases. Sharing the body does not let
it be checked once, though: each arm binds its binder at its own case's
payload type, so the type checker checks the body once per arm.

### 2.6 Implicit field names

```
init{ x; y; }        ->   init{ x = x; y = y; }
Vector{ x; y; }      ->   Vector{ x = x; y = y; }
```

Two spec sections, one rewrite:
[`types.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/types.md) §3.6
for `init{ }` and §3.5 for a field-constructor call site. Both are the same
`Field_arg.t` in the CST, so both fall out of one pass.

**CST → SST.** `Field_arg.value : Expr.t option` becomes non-optional.

The synthesized `NameExpr` takes the field name's span, which is the whole of
what was written.

### 2.7 Instantiation shorthand

```
e Expr.intLit("5")         ->   e Expr = Expr.intLit("5")
v Vector2.diagonal(x)      ->   v Vector2 = Vector2.diagonal(x)
```

[`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §3.2 says
of the two spellings that "the two lines declare the same thing", and
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§1.1 fixes the type the declared symbol gets: "the declared symbol holds
`Vector2` / `Expr`, never `Vector2.diagonal` or a per-case type."

**CST → SST.** `Decl.VarShorthand` disappears; `Decl.Var` is the only
declaration form left.

**This is the first of the two entries that sit on the line drawn at the top of
this file.** The
declared type comes from `Constructor_name.type_`, which is the syntax, so no
resolution is needed — but note what the rewrite does *not* settle: whether
`Expr.intLit(...)` is a variant case form or a named constructor call is
decided by what `Expr` turns out to be, and the SST does not know. It does not
have to. Both yield the base type, which is all this rewrite claims.

### 2.8 Parentheses

`Expr.Parenthized`, `Type_expr.Parenthesized` and `Ret_type.Parenthesized` all
go. Grouping is in the tree's shape once the tree exists;
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.7 says parentheses "group an inner expression explicitly" and nothing else.

The one thing lost is the span *including* the parens — the inner node keeps
its own span, which covers only what is inside them. Nothing on the roadmap
wants the wider one; a formatter or a "redundant parentheses" lint would, and
both would read the CST rather than the SST.

### 2.9 Trailing arguments

```
f() { body }    ->    f({ body })
```

[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.9: "The trailing and parenthesized forms are the same call. The `)` moves to
where the statement ends."

This one is already half-done: the CST puts the trailing argument in the
ordinary argument list and records only a `trailing : bool` beside it. The
comment on `Verb_call.t` in `lib/cst/nodes.ml` says outright that "nothing
downstream of the parser reads it" — it exists because the two spellings do not
*end* the same way, and `Statement_check` needs that to decide whether a `;`
belongs. That check has already run by the time the SST is built, so the SST
drops the flag.

**CST → SST.** Four `trailing : bool` fields go: `Verb_call.Func`, `.Meth`,
`.Constructor`, and `Decl.VarShorthand` (which §2.7 removes outright).

### 2.10 Statement defects

`Statement.defect` records how a statement disagreed with the termination
rules. `Cst.parse` runs `Statement_check.check` and returns `Error` when any
defect is set, so a package that reaches the SST has `None` everywhere.

**CST → SST.** `Statement.t` collapses into `Stat.t`; the wrapper has nothing
left to carry.

### 2.11 Method calls

```
subject:method(a)       ->   method(subject, a)        form Method, not mut
subject!method(a)       ->   method(subject, a)        form Method, mut
subject:Pkg$method(a)   ->   Pkg$method(subject, a)    form Method, not mut
```

[`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md)
§2.1 makes a method an ordinary verb whose first parameter is `this`, and §2.6
desugars `subject:method(arg)` to `ResolvedPkg$method(subject, arg)`. Moving the
subject into the argument list needs only the syntax, so it happens here;
finding `ResolvedPkg` does not.

**CST → SST.** `Verb_call.Func` and `Verb_call.Meth` become one `Call` node.
The subject is its first argument, and its `form` records how it was written:
`Function`, or `Method` with the marker's `is_mut`.

**This is the second of the two entries that sit on the line drawn at the top
of this file.** The rewrite stops at the callee's name. An unqualified method
lives in its subject's home package (`functions.md` §6.1), and finding that
package needs the subject's type, so `method` stays an unresolved name for
semantics to qualify. A qualified callee such as `Pkg$method` already names its
package. `form` stays on the call for two reasons:

- A method and a function resolve differently. A method is found through its
  subject's type, and a function by plain name and imports. The two calls
  have the same shape once the subject has moved.
- The `:` or `!` marker is checked against the declaration (`functions.md`
  §2.5), and that check needs `is_mut`.

---

## 3. The guard the desugar pass needed first — closed

**The grammar let a program declare four of the five derived operators, which
§2.3 would then have silently discarded.** As the parser stood:

```zane
Int  -(left Int, right Int) => left         // accepted
Bool >(left Int, right Int) => Bool(true)   // accepted
Bool <=(left Int, right Int) => Bool(true)  // accepted
Bool >=(left Int, right Int) => Bool(true)  // accepted
Bool ~=(left Int, right Int) => Bool(true)  // rejected
```

`~=` was already rejected, but `-`, `>`, `<=` and `>=` were all reachable from
the `operator` rule the declaration production reads.
[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.3 says all five "are **not** independently implementable", and §2.1 lists
the implementable set as exactly `~ * / + == <`.

Left alone, a user who wrote `Bool >(...)` would have got a declaration that
parses, type-checks, and is never called, because every `>` at a use site is
rewritten into a `<` before any call is resolved. That is the worst kind of
wrong: silent.

The declaration production now admits `==`, `<`, `+`, `*` and `/` only, with
`~` keeping its own production as the one unary operator. The use sites are
untouched — `a - b` and `a >= b` parse exactly as before, which is the point:
the restriction is on what may be *declared*, not on what may be written.
`test/parser/syntax_test.py` carries all eleven cases, and reverting the
grammar change fails it on exactly the four that were wrongly accepted.

## 4. Not the SST's job

Each of these looks like a desugaring and is not, because each needs something
the syntax does not carry. They are listed so the refusal is on the record.

| Construct | Why it is not a desugaring |
|---|---|
| `if`, `elif`, `else`, `guard`, `i!to(n)` | **Not sugar at all.** [`control-flow.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/control-flow.md) §1: "Zane has no `if` statement, no `loop` statement, and no exit keyword." They are `core` declarations called like any other verb, and they reach the SST as ordinary `Verb_call`s. Nothing to do — but a reader arriving from another language will expect an entry here, so this is it. |
| `subject:method(a)` → `Pkg$method(subject, a)` | [`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md) §2.6 titles this "Method desugaring", and the *qualified* form is indeed syntactic. The unqualified form rewrites to `ResolvedPkg$method`, and resolving that package is method lookup (§6.1), which needs the subject's type. §2.11 does the syntactic half. |
| Block-taking verbs expanded at the call site | [`control-flow.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/control-flow.md) §2.3 requires it, and it is what makes `guard` exit the right frame. It needs the callee's declaration, across packages. A lowering, after typing. |
| `implicit` constructor insertion at coercion sites | [`types.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/types.md) §4.2. Needs both types at the site. |
| `import pkg$` → an explicit member list | [`packages.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/packages.md) §3.3. Needs the other package's exported members. It is also name resolution rather than desugaring: "An import is a **spelling**, not a linkage." |
| `Constructor_args.Positional` vs `.Fields` | Unifying them needs the constructor's declared field order. Both arms stay. |
| `Expr.Ref` (`&x`) | A passing mode, not sugar. [`memory.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/memory.md) §2.4. |
| `:` vs `!` call markers | A check, not sugar: calling a `mut` method with `:` is illegal and vice versa ([`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md) §2.5). §2.11 keeps the flag on the call for that check. |

---

## 5. What the SST costs and buys

§2 in full:

| | CST | SST |
|---|---|---|
| `Body.t` | `Shorthand` \| `Longhand` | a statement list |
| `Abort_handle.t` | `Shorthand` \| `Longhand` | one record |
| `Operator.t` | 10 variants | 5 |
| `Operator.is_loose` | `bool` | gone |
| `Field_arg.value` | `Expr.t option` | `Expr.t` |
| `Match_pattern.cases` | `Name.t list` | `Name.t` |
| declaration forms | `Var` + `VarShorthand` | `Var` |
| parenthesis nodes | 3 | 0 |
| `trailing` flags | 4 | 0 |
| `Statement.t` wrapper | statement + defect | `Stat.t` |
| call shapes | `Func` \| `Meth` \| … | `Call` with a `form` \| … |

Two things stay that a reader might expect to go: control flow (§4 — it was
never sugar) and `Constructor_args`' two arms (§4 — needs the declaration).
