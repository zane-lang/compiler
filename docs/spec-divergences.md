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
over what may follow one. The **Closed** section at the end records those and
everything else that has closed since; an entry that simply vanishes reads as
an oversight.

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

## 2. A constructor call with nothing else to pass may not trail

**Spec** — [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.9: "A call's **last** argument may instead **trail** [...] Only a `{ }`
argument may trail", said of calls in general, and "An argument list with
nothing left inside it still writes its `( )`".

**Compiler** — a constructor call trails its last argument like any other
call, wherever one is written: as a statement, as an expression, and in the
instantiation shorthand of
[`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§1.1. What it may not do is trail when that would leave the `( )` empty.

```zane
worker Thread(name) {           // the block trails the call
    poll();
}

worker Thread(name, { poll(); });   // the same call, written in full
worker Thread() { poll(); }         // not this call: a lambda literal
```

The last line is the whole of what is left, and it is not rejected — it is
read as something else. `Foo() { ... }` is a **lambda literal** whose return
type is `Foo`
([`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.8 lists `ReturnType() { body }` as a form of its own), and in statement
position it is also a positional constructor declaration with a block body
(§3.3). Nothing inside the form tells those from a nullary constructor call
with one trailing block: an empty argument list and an empty parameter list are
the same `( )`, and a trailing block argument and a block body are the same
`{ }`. A lower-case callee has no such reading, which is why `do() { ... }` is
unambiguous and `Foo() { ... }` is not — the casing rule is doing the work.

So what is left is a collision inside the spec rather than a place the
compiler went its own way: §3.8 and §4.9 both claim the spelling, and neither
says which wins. Until the spec settles it, the compiler reads it as §3.8 has
it, and a constructor call whose only argument is a block writes the block
inside the list — `Thread({ poll(); });`, which needs its `;` because it ends
on the `)`.

Measured with `--check-tokens`, `UIDENT LPAREN RPAREN LCURLY RCURLY EOF` has 1
parse and `UIDENT LPAREN LIDENT RPAREN LCURLY RCURLY EOF` — the same call
with something inside the brackets — has 1 parse as the trailing form.
Admitting the nullary trailing reading gives `return Foo() { }` 2.

What stood here before was wider: no constructor call could trail at all,
because `Foo() { ... }` already spelled a constructor declaration with a block
body (§3.3). That reason is real but it only reaches statement position, and
the grammar was refusing the trailing form everywhere on the strength of it.
Narrowing it to the empty argument list keeps every spelling the declaration
and the lambda literal can take, and gives the rest back to the call.

## 3. A declaration inside a body is terminated like the statement it is

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

A raw `type`/`alias`, a positional instantiation that does not trail its last
argument (entry 2 above), a `=> expr` verb **whose expression does not itself
end in a `}`**, and a type cast from the **peer mould** are the forms this is
visible on — the peer mould's contents are a flat list of names, so it takes
`[ ]` and closes on a `]` rather than a brace.
`package` and `import` are spelled the same at both levels, since §5 gives them
a terminator at both. A `struct`/`variant` mould, a `{ }` verb body, an
enum map, and a `=> expr` verb whose expression *does* end in a `}` — a
`match`, a handler, a trailing call — all end in a brace and are spelled the
same at both levels. The parser reads this off the expression rather than off
the form, so `Int f() => match (c) { … }` needs no `;` in a body while
`Int f() => c` does.

## 4. `package` and `import` are terminated

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

Inside a body the same two forms are statements and the same two readings
meet, and there the terminator is no divergence: §6.3 requires a `;` after
every statement that does not end in a `}`, and the grammar carries that rule
for every statement.

`docs/ambiguity/proof-obligations.md` has the full account, in the ledger entry
for the state reducing `import_decl -> IMPORT LIDENT DOLLAR`. Reconciling in
the spec's direction needs the spec to say what separates two adjacent
declarations when the first ends in a name; until it does, the compiler cannot
drop the `;` without re-admitting the ambiguity.

## 5. Only a bare name may be passed as a type

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
`docs/ambiguity/proof-obligations.md` carries the full measurement.

The narrowing costs nothing the spec demonstrates: every §5.3 and §6.2 example
passes a bare name, and a parameterized type reaches a verb through inference
instead — `values Array<T Type, n Number>` introduces both parameters from the
argument. What is out of reach is passing an *already applied* type as a value,
which the spec neither shows nor rules out.

## 6. A `match` parenthesizes its scrutinee list

**Spec** — [`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§4.8: a `match` "names one or more scrutinees — a bare `,`-separated list, never
parenthesised — then a `{ }` block of `;`-terminated arms".
[`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §5.6
gives the reason: "Parenthesising them as `(state, event)` would imply a tuple
to destructure — the pattern-matching road — so the list stays bare."

**Compiler** — the list is written in `( )`. The semantics are the spec's: the
scrutinees stay independent values matched jointly on their tags, with one
selector per position and cross-product exhaustiveness.

```zane
result String = match (e) { … }            // accepted
worst Severity = match (left, right) { … } // accepted
result String = match e { … }              // rejected
```

The bare list is not a syntax the compiler can accept unambiguously. An `expr`
may end in a brace of its own — a constructor's field body, a map literal, a
call's trailing argument — so a bare scrutinee leaves the arms' `{` with two
owners, and a binary operator gives each owner enough to finish on:
`x Foo = match A { } <= B { }` has a complete derivation as
`(match A { }) <= (B { })` and another as `match (A { } <= B) { }`. Measured at
2 for every binary operator the language has, `{` carries no precedence level,
and `docs/ambiguity/policy.md` does not permit two accepting parses to be
narrowed afterward. The `)` ends the scrutinee before the brace is read.

Nothing is lost to the tuple reading §5.6 guards against, because Zane has no
`(a, b)` expression form for the list to collapse into: the parentheses delimit
it rather than build a value from it. What the divergence does cost is the
spelling, which is why it is recorded here rather than treated as a bug fix.
Reconciling it means changing §4.8 and the §5.6 rationale together; if the spec
later adds tuples, a tuple scrutinee needs its own `( )`.

## 7. A value closed by a brace takes no postfix

Checked against spec commit `f61c11b`, not the pin above.

**Spec** — [`lexical.md`](https://github.com/zane-lang/spec/blob/f61c11b/spec/lexical.md)
§6.3: a statement ending in `}` is closed by that brace, and "nothing may
continue the statement past it either — a call or a subscript written there has
nothing left to attach to". That is said of a statement's tail. Elsewhere the
spec does not say whether a call, method call or member access may be written
directly on a `match`, a map literal, an `init` or a constructor call by
fields; [`syntax.md`](https://github.com/zane-lang/spec/blob/f61c11b/spec/syntax.md)
§4.7 lets a `match` appear "anywhere an expression is legal". §4.5 already rules
out a subscript on one, since a subscript needs a place expression and each of
these is a temporary.

**Compiler** — none of the four is a postfix base, in any position. A value
closed by a `}` is continued through parentheses, which is the rule a trailing
argument follows in syntax.md §4.8:

```zane
abort match (x) { } (y)();          // accepted: two statements, the second `(y)()`
abort (match (x) { })(y);           // accepted
use(match (x) { } (y));             // rejected
size Int = (Foo{a = b;}):size();    // accepted
size Int = Foo{a = b;}:size();      // rejected
```

At a statement's tail this is §6.3, and the grammar has to carry it there: the
`(` and `[` a postfix opens with are the two tokens a statement can open with,
so a braced value that took a postfix gave `abort match (x) { } (y)();` two
complete parses
([#102](https://github.com/zane-lang/compiler/issues/102)). Carrying it at the
tail only would need the grammar to know where a statement ends while it is
still inside an expression. Holding it in every position does not, and reads
the same everywhere. What that costs is the parentheses in an argument or an
operand, where the spec is silent; reconciling it means stating the rule in
§4.7 and §4.1–4.2 of syntax.md.

## 8. A variant member read cannot take a handler

Checked against spec commit `e0b4249`, not the pin above.

**Spec** — [`adt.md`](https://github.com/zane-lang/spec/blob/e0b4249/spec/adt.md)
§3: reading a member of a variant value "is **partial**: the case may not be the
live one. A member read is therefore an **abortable** access (`?` / `??`)".

**Compiler** — an abort handler attaches only to a call, an operator, a flip or
a `match`, so `e.a ?? fallback` is rejected with "an abort handler must follow
an abortable operation". This divergence is not deliberate. It closes when
`DotAccess` takes an abort handle, as planned in
[`semantics.md`](semantics.md) D13.

---

## Closed

Kept briefly so a reader who remembers them can see they were closed on
purpose, and by what. The first three closed at the `034f11a` re-pin, when the
spec moved to `;`-terminated statements and a brace that ends one. The next
closed from the other side, when the compiler adopted a spec rule it had been
standing in for, and the last when the compiler followed the spec in removing a
form.

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
  ends in a brace. The grammar now decides whether a statement takes a `;`;
  only a stray `;` after its closing brace, and a trailing argument's `}` with
  something after it, are checked after the parse.

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

- **`and` and `or` were keywords here.** The spec's
  [`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
  §2.4 has no `and` or `or`: `Bool` draws from the same fixed operator set as
  every other type, where `*` is conjunction and `+` is disjunction, and a
  deferred right operand is an overload taking one rather than a token that
  implies it. The compiler kept them as keywords producing a `Logic` node,
  because dropping them would have left nothing to write in their place —
  `a * b` binds too tightly to join two comparisons, so every such line would
  have needed parentheses the spec does not write.

  §3.1's loose tier is what the spec puts there instead, and adding it removed
  the reason to keep them. `a '* b '+ c` groups exactly as `a and b or c` did,
  so the rewrite is one-for-one and the grouping is unchanged:

  ```zane
  settled Bool = Float(0) < middle '* middle < Float(100) '+ answer == Float(42);
  ```

  The `Logic` node and `Logic_op` went with the keywords, since a loose
  operator is an ordinary `Op` carrying the same `Operator.t` as the operator
  it mirrors. `and` and `or` are ordinary lowercase names again, reserved by
  nothing.

- **The compiler had a pipe, `callable|value`.** The spec fixed only its
  grouping, at level 2 of the precedence table, and never said what it did.
  Spec [#190](https://github.com/zane-lang/spec/pull/190) removed it, and the
  compiler followed: `|` is not a token, so `show|Color.red` stops at the
  lexer, and the call is written `show(Color.red)`. The `Pipe` and
  `MethodTarget` nodes went with it, since a method target was only ever a
  pipe's callee.
