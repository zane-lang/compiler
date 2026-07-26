# Ambiguity policy

Zane's grammar is deliberately not LR(1): the language is parsed with a
GLR+LR hybrid (menhirGLR, previously Elkhound), and constructs may require
unbounded lookahead. Nondeterminism is accepted; ambiguity is not.

**Policy: the grammar must remain provably unambiguous.** A GLR parser may
fork wherever it needs to, but on every input all forks except one must
eventually die. General context-free ambiguity is undecidable, so no tool
can certify this automatically for arbitrary grammars — instead the proof
is maintained as a finite set of per-conflict obligations, which is
possible because every fork point is an LR conflict state and Menhir
enumerates those exhaustively.

## Smallest grouping rule

When otherwise valid readings differ only in how much unparenthesized syntax a
construct captures, Zane chooses the **smallest complete grouping**. Following
syntax attaches to the nearest immediately preceding construct that can accept
it; an enclosing expression does not capture that syntax merely because it
could also accept it. Parentheses explicitly request the larger grouping.

For example, postfix operations stay inside a shorthand lambda body:

```zane
Int() => value()
Int() => value.field
```

These mean `Int() => (value())` and `Int() => (value.field)`, not
`(Int() => value)()` or `(Int() => value).field`. Applying the postfix
operation to the lambda requires explicit grouping:

```zane
(Int() => value)()
(Int() => value).field
```

This is a general language-design default for resolving grouping pressure after
explicit delimiters, precedence, and associativity have been considered. It is
not permission for the implementation to keep two accepting parses and choose
one afterward: the grammar must encode the rule so every accepted input still
has exactly one complete derivation.
