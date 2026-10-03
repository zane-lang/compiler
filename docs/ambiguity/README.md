# Ambiguity

Zane's grammar is deliberately not LR(1): the language is parsed with a
GLR+LR hybrid (menhirGLR, previously Elkhound), and constructs may require
unbounded lookahead. Nondeterminism is accepted; ambiguity is not.

**Policy: the grammar must remain provably unambiguous.** The current grammar
has an exact unambiguity certificate for its retained Menhir parse relation,
including the shipped GLR backend, conditional on the correctness of the
[documented trusted components](verification-roadmap.md). The [visible-stack proof](visible-proof.md) describes
the construction, checked certificate, scope, and reproduction command:

```sh
dev/bin/ambiguity prove-visible
```

The proof covers arbitrary sentence length and bracket nesting. It uses an
exact counted visibly pushdown model; the former stack-suffix prover remains
available for investigation and other grammars. Grammar edits require a fresh
certificate. General CFG ambiguity remains undecidable, but this grammar
passes the structural checks needed for the exact method.

This page is the index. The detail is in seven documents, each written for one
question:

- [**visible-proof.md**](visible-proof.md) — the complete exact proof and its
  certificate checker. Read this to reproduce the current unambiguity result.
- [**verification-roadmap.md**](verification-roadmap.md) — remaining formal
  proof obligations, acceptance criteria, and CI enforcement. Read this to
  distinguish the current guarantee from a formally checked source theorem.
- [**policy.md**](policy.md) — the smallest-grouping rule, and what
  the repository accepts. Read this to know which of two readings Zane means.
- [**proof-obligations.md**](proof-obligations.md) — the obligation
  every LR conflict state carries, what a semantic action is allowed to do
  under GLR, and where the current conflicts come from. Read this before
  changing the grammar.
- [**tooling.md**](tooling.md) — `ambiguity search`, `prove`,
  `survey` and `refine`, watching a run, the search profiles, and the local
  machine configuration they all need. Read this to run something.
- [**soundness.md**](soundness.md) — what bounds the prover's
  abstraction, what each verdict is allowed to mean, and why the scheme is
  sound at all. Read this to know what a "proven" run has proved.
- [**experiments.md**](experiments.md) — grammar restructurings and
  abstraction sharpenings that were measured and rejected. Read this before
  proposing one of them again.
