# Ambiguity experiments

Changes to the grammar that were measured, and ambiguities that were found and
resolved. They are recorded because the reasoning that recommends a rejected
change survives being told it does not work, so each of them gets proposed
again.

## Generic lambda against comparison (October 1, 2026)

A generated-sentence check found a genuine complete ambiguity in grammar commit
`c9877e4196c5ae243b2f5c1e23206f38d8bc5d39`.
The generator sampled the expanded grammar with seed `20261001`, an 80-token
budget and derivation depths 7–18, planning up to 100,000 samples and stopping
on the first two-parse sentence. Deleting and replacing subexpressions reduced
the finding to this 14-token complete program:

```zane
x Result = Foo<1>[]() {}
```

```sh
ambiguity check LIDENT UIDENT EQUAL UIDENT LESS INT MORE LBRACKET RBRACKET LPAREN RPAREN LCURLY RCURLY EOF
```

The exact recognizer reports `Accepting derivations: 2`. A separate tree-carrying
LR walk produces two complete `package` trees:

1. `Foo<1>[]` is the lambda's return type. The following `()` is its empty
   parameter list and `{}` its body.
2. `(Foo < 1) > ([]() {})`: `Foo` is a bare type value, `<` and `>` are
   comparisons, and the right operand calls the empty collection with a
   trailing block argument.

The independently generated `--GLR` parser, built from the action-erased
`--only-preprocess-uu` grammar under Menhir 20260209, also aborts with:

```text
Error: the symbol expr is ambiguous,
yet no merge function for this symbol has been defined.
```

The witness also has two complete derivations inside constructor arguments and
inside a function's `return` statement. Removing the verb-type suffix, giving
`Foo<1>() {}`, removes this particular collision. That is a diagnostic, not a
proposed language change.

Semantic type errors in a reading cannot discharge this grammar obligation:
the parser already has two complete derivations before type checking, so no
proof could certify that grammar commit unambiguous until the
generic-lambda/comparison overlap was resolved. The follow-up below records the
adopted restriction.

### Constructor-only type arguments

The follow-up retains the language-design decision to admit standalone bare
type values only as complete positional or named constructor arguments. They
are no longer ordinary `expr` operands. Both witnesses, including
`Foo<1>[][Int]() {}`, now have one complete parse. The independently generated,
action-erased Menhir GLR parser accepts both without its ambiguity failure.
Collections remain callable in the grammar.

The updated `lib/cst/parser.mly` SHA-256 is
`a9e5a9c47d95e4ce0bef3b4c19b1d3d69e79d0e0f2a0b7db4a1947188d0485af`.
Its automaton has 1,393 states and 481 distinct reachable production shapes.

Generated-sentence checking completed 100,000 package samples (seed
`20261002`, 80-token budget, depths 7–18) and 50,000 expression samples wrapped
as complete declarations (seed `20261003`, 100-token expression budget, same
depths). Every sample was accepted with one parse. These are samples, not
necessarily distinct sentences, and this is bounded evidence rather than a
proof.

The witnesses are grammar regressions in `tests/grammar/type_arguments_test.py`,
each pinned to one derivation. The grammar with this restriction in place is
proven unambiguous at every sentence length: [formal-proof.md](formal-proof.md)
states the Lean theorems, and [visible-proof.md](visible-proof.md) the
construction they check.

## Restructurings that were measured and rejected

`enum_map_tail` removed twelve conflicts by shifting every bracket group before
classifying it, and the same move looked like it should close the generics
family: give the constructor path the same `loption(generics)` the type path
carries, so that no reduction has to decide which one a name type is opening.
Measured, it goes the wrong way. Adding the option to `constructor_name` turned
29 conflict states into 49, twelve of them reduce/reduce; routing `verb_call`
through `constructor_decl_name`, which reaches the same shape by a different
edit, landed on the same 49.

What the enum-map case had and this one does not is a common shape to shift.
Both readings of a bracket group there were `[ … ]`, differing only in the role
the contents played, so one rule could take the group and let the actions sort
it out afterward. Here the two readings diverge in shape at the token the
decision is about: `Foo<Int>` continues as a type, `Foo(x)` as an argument
list, and `Foo.bar` as either a type member or a constructor member. Giving
both paths the same optional generics makes their prefixes identical without
making their continuations identical. It buys two `(` states and pays ten new
`.` states and twelve reduce/reduce ones for them: the parser now cannot tell
which nonterminal it is completing at the point where it used to know.

Both measurements were taken before the terminator change and have not been
retaken against the current grammar; the counts they cite are relative to the
29-state baseline.

The reading to take from this is that the remaining families are not waiting
for a factoring. They are overlaps in the surface syntax whose resolution sits
past any fixed lookahead, which is what a GLR parser and an unambiguity proof
over the whole parse relation are for.
