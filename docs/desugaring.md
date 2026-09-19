# What the SST desugars

The **SST** — simplified syntax tree — is the stage between the CST and the
typed tree: still untyped, but fully desugared. This file is the inventory of
what "fully desugared" means, so the SST's node set can be justified one entry
at a time rather than argued about as a whole.

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

Two rewrites in §2 sit right on that line, and both are called out where they
appear.

### Spans

Every node the SST synthesizes takes the span of the surface syntax it was
desugared from. `a - b` becomes `a + ~b`, and the `~` node that never existed
in the source takes the span of the `-` that produced it; the `+` takes the
same span the original `Op` node had. Nothing in this document needs
`Span.none`, and it should stay unused after the SST lands.

This is worth holding to, because it keeps the SST checkable by the same means
as the CST: `tools/span_dump.ml` renders each node against the source its span
covers, and a desugared tree whose spans still land on real source can be
checked by pointing the same tool at it. A synthesized node pointing nowhere
would read as a bug the moment it printed.

---

## 1. Already desugared, in the parser

These are done. They are listed so the SST does not redo them, and because
both are places where the parser reaches past what
[`stages.md`](stages.md) says it does.

| Form | Becomes | Where |
|---|---|---|
| `'*`, `'+`, `'<`, … (loose operators) | the same `Operator.t` as the unprefixed form | `lib/cst/parser.mly`, `loose_multiplicative_op` and friends |
| `name ReturnType(params) { body }` (lambda-variable) | `Decl.Var { name; type_ = <the function type>; value = <the lambda> }` | `lib/cst/parser.mly`, via `Nodes.func_type_of_lambda` |

The loose forms collapse because
[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§3.1 says a loose operator "calls the same implementation as its unprefixed
form and differs only in where it groups" — and where it groups is already
settled by the time the node exists. The `Operator.t` still carries the span of
the written `'*`, so a diagnostic about it points at what the author typed.

The lambda-variable expansion is the one
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.8 spells out in full, and `func_type_of_lambda` / `meth_type_of_lambda`
build the function type it calls for.

---

## 2. Desugarings to do

Ordered roughly by how much they simplify the tree. None of them depends on
another — every one is a local rewrite — so they can land in any order, or
one per commit.

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

### 2.2 Derived operators

[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.3 gives five fixed desugarings and says they are "**not** independently
implementable":

| Written | Becomes | Reorders operands? |
|---|---|---|
| `a - b` | `a + ~b` | no |
| `a ~= b` | `~(a == b)` | no |
| `a > b` | `b < a` | **yes** |
| `a <= b` | `~(b < a)` | **yes** |
| `a >= b` | `~(a < b)` | no |

This is not optional in the way most entries here are. The spec's promise is
that "if a type provides `<` for an operand pair, users automatically get `>`,
`<=`, and `>=` for that same pair" — a compiler that keeps `>` as its own node
has to either implement it separately, which §2.3 forbids, or do this rewrite
later anyway.

**CST → SST.** `Operator.t` drops from ten variants to five: `Add`, `Mul`,
`Div`, `Eq`, `Less`. `Sub`, `NotEq`, `More`, `LessEq` and `MoreEq` disappear.

**Two of the five reorder their operands, and the spec does not say whether
that is observable.** See §5.1 — this is the one entry on the list with a
question attached.

**This rewrite needs a guard first.** See §3.

### 2.3 `??` fallback handlers

```
expr ?? fallback    ->    expr ? <binder> { resolve fallback; }
```

[`error-handling.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/error-handling.md)
§3.3 states it as a desugaring in as many words: "`expr ?? fallback` desugars
to a `?` block that only resolves a default value."

**CST → SST.** `Abort_handle.t` loses its `Shorthand` arm and becomes a plain
record.

The binder has to be synthesized, since `??` writes none. The spec requires a
written binder even when the abort type is `Unit` (§3.1), so the SST supplies
one that no expanded body reads. A name no source can produce keeps it from
colliding with anything the author wrote — the
[`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
§4 identifier rules are what decide which names those are.

### 2.4 Match case groups

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

**The cost is body duplication, and with several scrutinees it is a cross
product.** `[a, b], [c, d] => body` expands to four arms carrying four copies
of `body`. §5.2 has the options.

### 2.5 Implicit field names

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

### 2.6 Instantiation shorthand

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

**This is the first of the two entries that sit on the line in §0.** The
declared type comes from `Constructor_name.type_`, which is the syntax, so no
resolution is needed — but note what the rewrite does *not* settle: whether
`Expr.intLit(...)` is a variant case form or a named constructor call is
decided by what `Expr` turns out to be, and the SST does not know. It does not
have to. Both yield the base type, which is all this rewrite claims.

### 2.7 Parentheses

`Expr.Parenthized`, `Type_expr.Parenthesized` and `Ret_type.Parenthesized` all
go. Grouping is in the tree's shape once the tree exists;
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.7 says parentheses "group an inner expression explicitly" and nothing else.

The one thing lost is the span *including* the parens — the inner node keeps
its own span, which covers only what is inside them. Nothing on the roadmap
wants the wider one; a formatter or a "redundant parentheses" lint would, and
both would read the CST rather than the SST.

### 2.8 Trailing arguments

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
`.Constructor`, and `Decl.VarShorthand` (which §2.6 removes outright).

### 2.9 Statement defects

`Statement.defect` records how a statement disagreed with the termination
rules. `Cst.parse` runs `Statement_check.check` and returns `Error` when any
defect is set, so a package that reaches the SST has `None` everywhere.

**CST → SST.** `Statement.t` collapses into `Stat.t`; the wrapper has nothing
left to carry.

---

## 3. A guard the desugar pass needs first

**The grammar lets a program declare three of the five derived operators, and
§2.2 would silently discard those declarations.**

Verified against the current parser:

```zane
Int -(left Int, right Int) => left          // accepted
Bool >(left Int, right Int) => Bool(true)   // accepted
Bool <=(left Int, right Int) => Bool(true)  // accepted
Bool >=(left Int, right Int) => Bool(true)  // accepted
Bool ~=(left Int, right Int) => Bool(true)  // rejected
```

`~=` is correctly rejected — `comparison_decl_op` omits it — but `-`, `>`, `<=`
and `>=` are all reachable from the `operator` rule the declaration production
uses. [`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.3 says all five "are **not** independently implementable", and §2.1 lists
the implementable set as exactly `~ * / + == <`.

Left as is, a user who writes `Bool >(...)` gets a declaration that parses,
type-checks, and is never called, because every `>` at a use site was rewritten
into a `<`. That is the worst kind of wrong: silent.

The fix is small — a `primitive_decl_op` rule for the declaration position,
leaving `comparison_op` alone for use sites — and it is a grammar change, so it
wants its own change and its own acceptance test. It is listed here rather than
in [`spec-divergences.md`](spec-divergences.md) because it is not a deliberate
divergence; it is a gap.

---

## 4. Not the SST's job

Each of these looks like a desugaring and is not, because each needs something
the syntax does not carry. They are listed so the refusal is on the record.

| Construct | Why it is not a desugaring |
|---|---|
| `if`, `elif`, `else`, `guard`, `i!to(n)` | **Not sugar at all.** [`control-flow.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/control-flow.md) §1: "Zane has no `if` statement, no `loop` statement, and no exit keyword." They are `core` declarations called like any other verb, and they reach the SST as ordinary `Verb_call`s. Nothing to do — but a reader arriving from another language will expect an entry here, so this is it. |
| `subject:method(a)` → `Pkg$method(subject, a)` | [`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md) §2.6 titles this "Method desugaring", and the *qualified* form is indeed syntactic. The unqualified form rewrites to `ResolvedPkg$method`, and resolving that package is method lookup (§6.1), which needs the subject's type. See §5.3. |
| Block-taking verbs expanded at the call site | [`control-flow.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/control-flow.md) §2.3 requires it, and it is what makes `guard` exit the right frame. It needs the callee's declaration, across packages. A lowering, after typing. |
| `implicit` constructor insertion at coercion sites | [`types.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/types.md) §4.2. Needs both types at the site. |
| `import pkg$` → an explicit member list | [`packages.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/packages.md) §3.3. Needs the other package's exported members. It is also name resolution rather than desugaring: "An import is a **spelling**, not a linkage." |
| `Constructor_args.Positional` vs `.Fields` | Unifying them needs the constructor's declared field order. Both arms stay. |
| `Expr.Ref` (`&x`) | A passing mode, not sugar. [`memory.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/memory.md) §2.4. |
| `:` vs `!` call markers | A check, not sugar: calling a `mut` method with `:` is illegal and vice versa ([`functions.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/functions.md) §2.5). Whatever §5.3 decides about the subject, the flag survives. |

---

## 5. Open questions

### 5.1 Two derived operators reorder their operands

`a > b` becomes `b < a` and `a <= b` becomes `~(b < a)`. Both evaluate the
written right operand first.

The spec does not settle whether that is observable.
[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.4 says "Both operands are evaluated" but never fixes an order, and nothing
elsewhere does either — the two places the spec *does* fix an order are map
literal entries ([`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§2.8) and `Unit` erasure ([`types.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/types.md)
§2.6), both stated explicitly, which suggests the silence here is a gap rather
than an omission meaning "unspecified".

It is not hypothetical. An operator is an ordinary verb
([`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.2) and only `~` is required to be pure (§4.1), so `f(log) > g(log)` can have
two observable writes whose order the rewrite reverses.

Four ways out:

1. **Swap, and close the gap in the spec** — state that operand evaluation
   order is unspecified, or that it follows the desugared call. Cheapest, and
   it makes the other three rewrites uniform with these two.
2. **Swap, and state left-to-right** — then the SST must bind both operands to
   temporaries before the swapped call, which adds nodes to every `>` and `<=`.
3. **Carry a `swapped` flag** on the call and let codegen order the evaluation.
   Keeps the SST small at the cost of a field that means "undo me later".
4. **Desugar only the three that do not reorder**, and leave `>` and `<=` to a
   later stage. Splits one spec rule across two stages, which is the thing
   §2.2 exists to avoid.

**Recommendation: (1).** The spec already treats these five as one rule, and
three of them are unaffected; a compiler decision is the wrong place to record
an answer the spec should be giving.

### 5.2 Match groups duplicate their bodies

Expanding `[a, b], [c, d] => body` gives four arms and four copies of `body`.
For the arm shapes in the spec's own examples that is nothing, but the
exhaustiveness rule pushes the other way:
[`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §5.6
requires every *combination* to be covered with no wildcard, so a
"regardless of `state`" arm names every state in a group — exactly the shape
that multiplies.

Three options:

1. **Expand eagerly.** Matches the spec's wording, gives each arm its own
   binder type, and makes every later pass simpler. Bodies are duplicated.
2. **Expand the selector, share the body.** Arms point at one body node.
   Halfway: the binder still needs a per-arm type, so the shared body cannot be
   checked once.
3. **Keep a tag set on the arm** and expand in codegen. Smallest tree,
   but it leaves a piece of surface syntax in an allegedly desugared tree.

**Recommendation: (1),** on the grounds that the spec's reason for the
expansion is the binder's per-case type, and that reason survives every attempt
to share. If duplication ever measures as a problem, it is a codegen concern —
identical arm bodies converging on one tag jump is a standard thing to do
there.

### 5.3 How far to take the method-call rewrite

`subject:method(a)` has two halves. Moving the subject into the argument list
is syntactic. Resolving which package `method` came from is not.

1. **Do nothing.** `Verb_call.Meth` survives into the SST with its `this`,
   `is_mut` and callee. Honest, and leaves the tree with two call shapes.
2. **Normalize the shape only** — subject becomes the first argument, callee
   stays an unresolved name, `is_mut` moves onto the call. One call node; the
   `:`/`!` check still has what it needs; the package is filled in later.
3. **Full rewrite.** Needs types. Not available here.

**Recommendation: (2),** with the qualified form (`subject:Pkg$method(a)`)
producing a callee that is already qualified and the unqualified form producing
one that is not — which is the same distinction `Name_expr.Ident` and
`.Qualified` already draw.

This is the second of the two entries on the §0 line, and it is the one I am
least sure of. (1) is a perfectly defensible answer if the extra call shape
costs less than a callee that is sometimes resolved and sometimes not.

### 5.4 What `|` means

`callableExpr|expr` is a strong desugaring candidate — if it means
`callableExpr(expr)`, it is a call and the `Pipe` and `MethodTarget` nodes both
disappear.

But the spec only fixes its **grouping**, never its meaning.
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.4 gives precedence and three examples of where the brackets fall;
[`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§3 places it at level 2 and says twice that it is not part of the operator set.
No section says what it does. `Vec2(2)|100` grouping "as `Vec2(2)|100`" hints
that the left side may already be a call, which a plain
`callee|arg -> callee(arg)` reading would not explain.

**No recommendation — this needs a spec answer before it can be a desugaring.**
Until then `Expr.Pipe` passes through untouched, and `Expr.MethodTarget` with
it, since the CST comment says it is "only ever a `Pipe`'s callee".

---

## 6. What the SST costs and buys

Doing §2 in full, and taking the recommendations in §5:

| | CST | SST |
|---|---|---|
| `Body.t` | `Shorthand` \| `Longhand` | a statement list |
| `Abort_handle.t` | `Shorthand` \| `Longhand` | one record |
| `Operator.t` | 10 variants | 5 |
| `Field_arg.value` | `Expr.t option` | `Expr.t` |
| `Match_pattern.cases` | `Name.t list` | `Name.t` |
| declaration forms | `Var` + `VarShorthand` | `Var` |
| parenthesis nodes | 3 | 0 |
| `trailing` flags | 4 | 0 |
| `Statement.t` wrapper | statement + defect | `Stat.t` |
| call shapes | `Func` \| `Meth` \| … | `Func` \| … (§5.3) |

Three things stay that a reader might expect to go: control flow (§4 — it was
never sugar), `Pipe` (§5.4 — undecided), and `Constructor_args`' two arms (§4 —
needs the declaration).
