# Ambiguity

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

This page is the index. The detail is in five documents, each written for one
question:

- [**policy.md**](ambiguity/policy.md) — the smallest-grouping rule, and what
  the repository accepts. Read this to know which of two readings Zane means.
- [**proof-obligations.md**](ambiguity/proof-obligations.md) — the obligation
  every LR conflict state carries, what a semantic action is allowed to do
  under GLR, and where the current conflicts come from. Read this before
  changing the grammar.
- [**tooling.md**](ambiguity/tooling.md) — `ambiguity search`, `prove`,
  `survey` and `refine`, watching a run, the search profiles, and the local
  machine configuration they all need. Read this to run something.
- [**soundness.md**](ambiguity/soundness.md) — what bounds the prover's
  abstraction, what each verdict is allowed to mean, and why the scheme is
  sound at all. Read this to know what a "proven" run has proved.
- [**experiments.md**](ambiguity/experiments.md) — grammar restructurings and
  abstraction sharpenings that were measured and rejected. Read this before
  proposing one of them again.
