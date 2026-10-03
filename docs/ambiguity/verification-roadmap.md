# Roadmap to a formally checked unambiguity proof

## Current guarantee

The grammar's unambiguity is a theorem checked by Lean. `just verify-grammar`
proves it for the current `lib/cst/parser.mly`, and the `Grammar verification`
workflow runs that recipe on every relevant change.
[formal-proof.md](formal-proof.md) states the theorems and what they still
assume:

- Lean's kernel, plus its code generator for the executable check.
- The Lean definitions of Menhir's preprocessing and precedence resolution,
  which are cross-checked against Menhir.
- That Menhir's generated GLR parser accepts the trees of its dumped automaton.

All four milestones below are complete. Each one ends with a status line naming
where its evidence lives.

`ambiguity prove-visible` remains the fast, unverified implementation of the
same construction ([visible-proof.md](visible-proof.md)). It is useful while
editing the grammar, and its verdict is conditional on its own Python code.

## Target theorem and scope

Define the accepted parse relation of the source grammar precisely, including
Menhir's precedence rules. For every token string `w`, prove:

> If the source-bound certificate checker accepts, the source grammar has at
> most one accepted syntactic derivation yielding `w`.

Semantic actions are erased. Removing derivations through semantic actions
cannot introduce ambiguity, so the result also applies to their accepted
subset. Correct AST construction, lexer correctness, type checking, and
code generation remain separate compiler properties.

The raw expression CFG without precedence declarations is ambiguous. Proving
that different relation unambiguous would require a grammar change; it is not
a missing step in this roadmap. The result must always identify the exact
source snapshot and parse relation to which it applies.

## Milestones

### 1. Formalize the finite-invariant checker

Start with the final counted visibly pushdown model and certificate. Define
its run semantics, the capped counting semiring `{0, 1, 2}`, epsilon paths,
fragment acceptance, call/return matrices, and frame summaries in Lean or Rocq.
Prove that capped counting detects two or more finite accepting derivations,
including in the presence of epsilon cycles.

Prove that the checker's closure conditions cover every run at every input
length and nesting depth. In particular, accepting a certificate must imply
that the root's accepting count is never 2. The producer need not be verified:
it can remain an untrusted search program producing evidence for the checker.

**Completion evidence:** the proof assistant checks the soundness theorem and
accepts both saved model certificates through an executable checker whose
connection to that theorem is established. A handwritten Python implementation
of a similar algorithm would still require trust; it is not enough by itself.

**Status: done.** `Ambiguity/VpaSound.lean` proves `check_sound` for the
executable checker `check`. The `certificate` command of
`zane-ambiguity-check` runs that checker on a saved certificate.

### 2. Certify the grammar-to-model transformations

Move backward from the model to the exported parse relation. Make each stage
produce correspondence evidence and check that evidence with formally justified
code, or verify the transformation itself. The required obligations are:

| Stage | Required property |
| --- | --- |
| Counted horizontal compilation | Grammar derivations and weighted paths have the same capped counts; determinization/minimization preserve them. |
| Regularity and bracket decomposition | Accepted productions satisfy the structural hypotheses used by compilation; nested bodies remain represented. |
| Aliases, epsilon elimination, factoring, and quotienting | Alternatives and their multiplicities are preserved, including nullable and cyclic cases. |
| Lookahead-guard elimination | An accepted yield determines its annotations uniquely, and guarded derivations correspond to the resulting CFG derivations. |
| Generic-angle tagging | Every competing parse of a token string receives the same uniquely determined tags; tagging preserves derivations. |
| LR context extraction | Exported retained-action runs and guarded grammar derivations correspond, with the correct start, end-of-input condition, shifts, gotos, reductions, and lookahead guards. |
| Model binding | The checked model is the result covered by those correspondences; acceptance, weights, repeated alternatives, and child/continuation pairing are preserved. |

A separate certificate can allow an expensive optimizer to remain untrusted.
The present fresh rebuild is useful, but it invokes the same compiler and
could reproduce the same bug. It does not discharge these obligations.

**Completion evidence:** a checked chain connects the exported parse relation
to the model consumed by milestone 1. No transformation can silently remove a
competing derivation. Each remaining assumption is stated explicitly.

**Status: done.** `verify_sound` (`Ambiguity/Pipeline.lean`) chains the
stages:

- context extraction: `CtxSound`;
- quotienting: `QuotientSound`;
- angles: `AnglesSound`;
- lookahead guards: `LookaheadSound`, `Plain`;
- horizontal compilation and model binding: `HorizMain`, `RuleSound`,
  `DetSound`, `MinSound`, `ChainSound`, `BwdSound`;
- the final checker: `VpaSound`.

Its hypothesis is the executable check `verify`, and its conclusion is that the
automaton's accepted trees are unambiguous.

### 3. Connect the exported relation to `parser.mly`

The existing production-shape checks and manifests detect many mismatches;
they do not prove Menhir's preprocessing or automaton export correct. Define
source production identities and the effect of precedence resolution, then
verify a correspondence between the source relation and the exported relation.
Include GLR's nullable-rule rewrite and parameterized/inlined productions.

Possible implementations are a checked translation certificate from Menhir's
output, or a verified front end for the source grammar. Select an approach
that can account for the retained actions and the actual GLR rewrite; checking
only a final automaton's internal consistency would leave the source gap open.

**Completion evidence:** the formal theorem starts with the exact source
grammar and precedence declarations. It no longer assumes that an arbitrary
Menhir dump faithfully represents them. Stock and GLR results have explicit
source correspondences rather than relying on agreement between two runs.

**Status: done**, as a verified front end. `Mly.sourceGrammar` and
`Lr1.canonical` define the source relation from the file's text, and
`verifySource_sound` proves it unambiguous. For the shipped `--GLR` parser,
`verifyGlr_sound` checks a production-by-production correspondence with the
source grammar: each production either keeps or drops each source symbol, or
is a unit production. It maps every accepted GLR tree to a source derivation of
the same tokens.

### 4. Make proof regeneration a CI gate

This can begin immediately, alongside formalization. The existing
`ambiguity-prove` workflow runs the older stack-abstraction prover and allows
inconclusive verdicts; it does not gate changes with `prove-visible`.

Add a dedicated workflow that pins Menhir and checker dependencies, regenerates
the source-bound certificates, checks them, and uploads the manifests and
reports. Run it on relevant grammar, prover, checker, dependency, and workflow
changes. Configure the resulting check as required for merging.

Ambiguity, unsupported input, timeout, checker failure, and stale source
identity must all fail this gate. Reusing a historical certificate without
checking the current source is insufficient. Initially this enforces the
current conditional guarantee; switch the verifier to the formally checked
pipeline as the earlier milestones become available.

**Completion evidence:** a relevant PR cannot pass with an incomplete run or
a certificate for a different source snapshot. CI preserves the exact source,
tool versions, verified evidence, and stated assumptions for review.

**Status: done.** `.github/workflows/ambiguity-verify.yml` runs
`just verify-grammar`. It triggers on changes to the grammar, `formal/`, the
justfile or the workflow itself, and uploads the run's report. The checker
reads `parser.mly` directly, so no certificate can describe a different
snapshot. Marking the check as required is a repository setting.

## Recommended order and reporting

Formalize the small final checker first, then certify the transformations
backward toward the source. Introduce the CI gate early so grammar edits do
not silently invalidate the current result. Choose the proof assistant before
implementation and establish the executable checker's proof connection before
porting the entire pipeline.

Until the source connection is complete, report results as a complete
unambiguity certificate **conditional on the documented trusted components**.
Afterward, report the formal theorem and its remaining foundational assumptions
(the proof assistant kernel and the environment used to run it). Formal
verification reduces implementation trust; it does not mean that all software,
hardware, or foundations become assumption-free.

Additional testing remains useful for finding defects and protecting practical
behavior. Increasing bounded tests, stack depth, or agreement between tools
cannot replace any of these proof obligations.
