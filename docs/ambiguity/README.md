# Ambiguity

Zane's grammar is deliberately not LR(1): the language is parsed with a
GLR+LR hybrid (menhirGLR, previously Elkhound), and constructs may require
unbounded lookahead. Nondeterminism is accepted; ambiguity is not.

**Policy: the grammar must remain provably unambiguous.** The grammar's
unambiguity is a Lean-checked theorem. It is stated for the text of
`parser.mly`, under Menhir's precedence rules, and covers the shipped GLR
parser too. [formal-proof.md](formal-proof.md) states the theorems and their
remaining assumptions. CI re-proves them on every grammar change:

```sh
just verify-grammar
```

The [visible-stack proof](visible-proof.md) explains the construction. Its
faster, unverified implementation is useful while editing:

```sh
dev/bin/ambiguity prove-visible
```

The proof covers arbitrary sentence length and bracket nesting. It uses an
exact counted visibly pushdown model. Grammar edits require a fresh
certificate. General CFG ambiguity remains undecidable, but this grammar
passes the structural checks needed for the exact method.

To find a concrete ambiguous input rather than prove there is none,
`ambiguity search` runs a bounded search for complete ambiguous sentences, and
`ambiguity check` counts the derivations of one token sequence.

This page is the index. The detail is in seven documents, each written for one
question:

- [**visible-proof.md**](visible-proof.md) — the complete exact proof and its
  certificate checker. Read this to reproduce the current unambiguity result.
- [**formal-proof.md**](formal-proof.md) — the Lean theorems, how to run them,
  and what they still assume. Read this to know exactly what is proven.
- [**verification-roadmap.md**](verification-roadmap.md) — the formal proof
  obligations, their acceptance criteria and where each is discharged.
- [**policy.md**](policy.md) — the smallest-grouping rule, and what
  the repository accepts. Read this to know which of two readings Zane means.
- [**proof-obligations.md**](proof-obligations.md) — the obligation
  every LR conflict state carries, what a semantic action is allowed to do
  under GLR, and where the current conflicts come from. Read this before
  changing the grammar.
- [**tooling.md**](tooling.md) — `ambiguity search`, `check`, `classes` and
  `prove-visible`, watching a run, the search profiles, and the local machine
  configuration they need. Read this to run something.
- [**experiments.md**](experiments.md) — ambiguities that were found and
  resolved, and grammar restructurings that were measured and rejected. Read
  this before proposing one of them again.
