# Where the compiler differs from the spec

The [spec](https://github.com/zane-lang/spec) is authoritative for anything not
listed here. This file records the places the parser deliberately accepts
something else, so a contributor reading a spec section and then the grammar
knows which of the two is currently ahead.

The syntax is still experimental, so divergences are expected to appear and
close. The intent is to reconcile in the spec's direction once the surface
settles, in one pass rather than section by section. Until then:

- **When a change here creates or closes a divergence, update this file in the
  same pull request.** An entry that survives the behaviour it describes is
  worse than no entry, because it is read as current.
- Each entry cites the spec section it departs from and states both rules, so
  the claim can be rechecked rather than taken on trust.

Entries below were checked against spec commit `034f11a`, and the links
point at that commit so a later spec edit cannot silently make a quotation
here disagree with what it links to. Re-pin them when the entries are
rechecked. Where a claim is
about what the parser accepts, it was measured with
`ambiguity search --check-tokens`, which reports how many parses a token
sequence has: `0` is a syntax error, `1` is accepted.

Three entries closed at this re-pin, when the spec moved to `;`-terminated
statements and a brace that ends one. What was the widest divergence — the
spec separating statements by newline where the compiler terminated them — is
gone, and with it the same-line rule for a trailing block and the disagreement
over what may follow one. The **Closed** section at the end records them, since
an entry that simply vanishes reads as an oversight.

---

## 1. A match arm's terminator follows its body

**Spec** — [`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md)
§5.1 and [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.8: the scrutinee is followed by "a `{ }` block of `;`-terminated arms", with
the arm given as `[binder] selector => body ;`.
[`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
§6.3 now says so in as many words: an entry of a `{ }` body "carries its `;`
unconditionally [...] including an entry whose value ends in a `}` — that
uniformity is what makes newlines insignificant inside a body, and it does not
bend for the last entry or for any particular value shape."

**Compiler** — an arm whose body is `=> expr` is terminated by `;`; an arm whose
body is a `{ }` block is not, because the block already closes it.

```zane
red { return "Red"; }     // accepted; `red { ... };` is rejected
green => "Green";         // accepted; `green => "Green"` is rejected
```

This is the compiler's brace rule applied to an arm as though it were a
statement. The spec draws the line elsewhere: the brace ends a *statement*, and
an arm is an entry, which carries its terminator whatever its body looks like.
Both rules are uniform; they differ over which uniformity an arm belongs to.

The compiler follows the spec on the `=> expr` arm whose *value* ends in a
brace, which keeps its `;` like any other entry:

```zane
wanted name => env:lookup(wanted) ? missing {
    abort missing;
};                        // accepted, and the `;` is required
```

## 2. `and` and `or` are still keywords here

**Spec** — [`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§2.4 has no `and` or `or` at all. `Bool` draws from the same fixed operator set
as every other type: `*` is conjunction, `+` is disjunction, `~` is complement,
and both operands are evaluated. A deferred right operand is an overload taking
one, "visible at the call site rather than implied by the token".

**Compiler** — `and` and `or` are keywords producing a `Logic` node, with `or`
binding loosest, then `and`, then the comparison level, all left-associative.
So `a and b or c` groups as `(a and b) or c`.

The grouping was the compiler's own decision, taken while the spec still spelled
these as short-circuiting keywords without placing them. The spec has since
removed them, so what is left to reconcile is the whole construct rather than
its precedence.

## 3. A constructor call carries its blocks in the argument list

**Spec** — [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.9: "A call's **last** argument may instead **trail** [...] Only a `{ }`
argument may trail", said of calls in general.

**Compiler** — a function or method call may trail one; a constructor call may
not, and writes every block in its argument list.

```zane
Foo({ run(); })      // a constructor call taking a block argument
Foo() { run(); }     // a constructor declaration, here and in a body alike
```

The second line is a positional constructor declaration with a block body
([`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.3), which it already was before block arguments existed. Letting a
constructor call trail a block would give those tokens a second reading, so it
may not; a function or method call is not spelled that way and can. Measured
with `--check-tokens`, `UIDENT LPAREN RPAREN LCURLY RCURLY EOF` has 1 parse.

## 4. A declaration inside a body is terminated like the statement it is

**Spec** — [`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
§6.3: "A **package-scope declaration** is not a statement and takes no
terminator of its own; it ends where its own body or bracket ends." The forms
in [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§1 are written bare throughout — `name VarType = expr`, `import packageName`,
`type Name = TypeExpr`, `name ReturnType(param ParamType, ...) => expr`.

**Compiler** — agrees at package scope, and applies the statement rule
unchanged inside a body. A declaration written in a function body is a
statement there, so it takes `;` unless it ends in a `}`:

```zane
type Meters = Int            // package scope: no terminator

Unit use() {
    answer Int = Int(42);    // in a body: terminated, like any statement
    ran Bool = if(ready) {
        start();
    }                        // in a body: the brace ends it, so no `;`
}
```

The spec's sentence covers the package-scope half and says nothing about the
same declaration written inside a body, where §6.3's own rule — every statement
is terminated, unless it ends in a `}` — is the only rule that applies. The
compiler reads a declaration in a body as a statement and terminates it on that
basis. The divergence is therefore narrow and may not be one at all: it is
recorded because moving a declaration between the two levels changes how it is
spelled, which is a real cost and worth stating out loud rather than
discovering.

A raw `type`/`alias`, a positional instantiation, a `=> expr` verb **whose
expression does not itself end in a `}`**, and a type cast from the **peer
mould** are the forms this is visible on — the peer mould's contents are a flat
list of names, so it takes `[ ]` and closes on a `]` rather than a brace.
`package` and `import` are spelled the same at both levels, since §5 gives them
a terminator at both. A `struct`/`variant` mould, a `{ }` verb body, an
enum map, and a `=> expr` verb whose expression *does* end in a `}` — a
`match`, a handler, a trailing call — all end in a brace and are spelled the
same at both levels. The parser reads this off the expression rather than off
the form, so `Int f() => match c { … }` needs no `;` in a body while
`Int f() => c` does.

## 5. `package` and `import` are terminated

**Spec** — [`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
§6.3: "A **package-scope declaration** is not a statement and takes no
terminator of its own; it ends where its own body or bracket ends." The forms
in [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§1.5 and §8.2 are written bare — `import packageName$member`, `package
packageName`.

**Compiler** — these two take a `;`, and the grammar requires it:

```zane
package main;
import core$;
import math$[floor, ceil];

type Meters = Int            // every other declaration is still bare
```

The spec's sentence assumes a declaration ends where its own shape says it
stopped, which is true of every form that closes on a body, a bracket, or an
expression. `package pkg` and `import pkg$member` end on a bare name, and
`import pkg$` ends just before one, so their shape says nothing about where
they stop. That is not merely untidy: it is ambiguous. `import core$` followed
by `main Unit() { }` parses both as a whole-package import and a lambda-valued
declaration, and as a member import of `main` and a constructor declaration for
`Unit`. Measured with `--check-tokens`, that bare spelling had two parses
before the `;` was required; each terminated spelling has one, and the bare one
is now rejected.

The terminator is required inside a body too, where the same two forms are
statements and the same two readings meet. That is stricter than §6.3's
statement rule, which would let `check_terminator` accept the `;` and reject
its absence after the parse — too late, because both spellings parse.

`docs/ambiguity.md` has the full account, in the ledger entry for the state
reducing `import_decl -> IMPORT LIDENT DOLLAR`. Reconciling in the spec's
direction needs the spec to say what separates two adjacent declarations when
the first ends in a name; until it does, the compiler cannot drop the `;`
without re-admitting the ambiguity.

## 6. Only a bare name may be passed as a type

**Spec** — [`generics.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/generics.md)
§5.3: "A type or number can instead be passed as an ordinary argument by
declaring a value parameter of concept type `Type` or `Number`. The argument is
then written positionally in `()`, like any other value." A type is whatever a
type expression describes, so nothing in that sentence narrows it to a name.

**Compiler** — a type name may be written where a value is expected; no other
type spelling may.

```zane
arr Array(Int, 10000);        // accepted, and §6.2's own example
room Slots(math$Vector, 4);   // accepted: a qualified name is still a name
held Slot = @primitives$I64;  // accepted: so is an intrinsic one

register(Array<Int, 4>);      // rejected
register(&Int);               // rejected
register(Int[3]);             // rejected
```

What separates the two lists is whether the spelling **ends at the name**. A
bare name does, so the parser reads it and is finished. Every other type
spelling continues into a bracket that already means something else after an
expression: `<` opens a comparison, `[` a subscript, and a leading `&` belongs
to a lambda's return type
([`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.8). The parser would have to complete the type-value reading before seeing
which, and it cannot.

Measured, that is not a fork GLR resolves but a cost paid in the automaton:
admitting the applied form adds three **reduce/reduce** states, every one of
them `expr -> <name> loption_generics_` against `list_verb_type_suffix_ ->`.
The bare form adds four shift/reduce states and no reduce/reduce state at all.
`docs/ambiguity.md` carries the full measurement.

The narrowing costs nothing the spec demonstrates: every §5.3 and §6.2 example
passes a bare name, and a parameterized type reaches a verb through inference
instead — `values Array<T Type, n Number>` introduces both parameters from the
argument. What is out of reach is passing an *already applied* type as a value,
which the spec neither shows nor rules out.

---

## Closed at the `034f11a` re-pin

Kept briefly so a reader who remembers them can see they were closed on
purpose, and by which spec change.

- **Statements are terminated, not separated.** The spec separated statements
  by newline and called it "the one place a newline is structural"; the
  compiler has always terminated them with `;` and given newlines no meaning.
  Spec [#181](https://github.com/zane-lang/spec/pull/181) adopted the
  terminator — "a `;` **terminates** every statement in a code block" — and
  with it "**`Newlines are never structural`**". The compiler's rule is now the
  spec's. What the compiler had to generalize was the other half of the new
  rule.

  A statement that ends in a `}` takes no terminator. The compiler already
  behaved that way for the statements whose *form* made it look obvious — a
  block-bodied verb, any mould, a call closed by a trailing block — each of
  which reached `stat` by a production with no terminator in it. Reading the
  rule off the form is what made that wrong for one of them: the peer mould's
  contents are a flat list, so it closes on a `]` and never had a brace to end
  it. It took no terminator anyway, and taking one was a syntax error. This
  pull request narrowed the no-terminator productions to the brace moulds and
  routed the peer mould through the ordinary terminated path.

  What the compiler did not have at all was the rule stated over a statement's
  **tail** rather than its form, which is what reaches a variable bound to a
  `match`, an assignment, a `return`, and a `=> expr` verb whose expression
  ends in a brace. That is now decided per statement and checked after the
  parse.

- **A trailing block is placed by position, not by line.** The spec required a
  trailing block's `{` to open on the same line as its call, to tell it from a
  statement block on the next line. Spec #181 removed the rule along with the
  statement block itself: a `{ }` may no longer open a statement
  ([`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
  §6.3.1), so nothing is left for the line to disambiguate. The compiler never
  had a statement block and never read a newline, so it already behaved this
  way; `Unit use() { { work(); } }` is rejected, and the scoped form is
  `do() { work(); }`.

- **A call statement closed by a trailing block takes no handler.** The spec
  gave `expr ? binder { ... }` for any abortable operation, which read as
  permitting a handler after a trailing block. Spec #181 settled it the other
  way: "A trailing argument **MUST** be the last thing in its statement [...]
  neither a `;` nor anything that would continue the call may come after it."
  The compiler now enforces exactly that, for a handler and for a further call
  or subscript alike, and an abortable call that wants a handler writes its
  block inside the argument list:

  ```zane
  done Unit = retry(count, { attempt(); }) ? e {
      resolve Unit();
  }
  ```
