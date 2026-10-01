# Exact unambiguity proof

The current grammar has a complete unambiguity certificate under Menhir's
precedence and associativity rules, conditional on the correctness of the
trusted components listed below. The [verification roadmap](verification-roadmap.md)
describes how to discharge those implementation assumptions. This includes the original grammar's
retained conflicts and the automaton produced by the shipped `--GLR` backend.
The constructor-only restriction on standalone type values is unchanged.

The proof counts syntactic derivations with semantic actions erased. Thus it
also covers every assignment of token payloads and every subset of parses
accepted by semantic actions. It does not prove that semantic actions build
the intended AST, or that the lexer or compiler implementation is correct.
The raw expression CFG without its precedence declarations is ambiguous;
that is not the parse relation certified here.

## Reproduce and check

Use the project's pinned Menhir 20260209 and Python 3. No OCaml compilation,
Java tool, external ambiguity analyzer, or stack-precision setting is needed.

```sh
AMBIGUITY_MENHIR=/path/to/menhir dev/bin/ambiguity prove-visible \
  --output reports/ambiguity/visible

# Independently check the saved finite invariant, without running the search.
python3 -m tools.ambiguity.visible.verify \
  reports/ambiguity/visible/certificate.json \
  --grammar reports/ambiguity/visible/factored.y

# Check the source grammar before GLR's nullable-rule rewrite too.
AMBIGUITY_MENHIR=/path/to/menhir dev/bin/ambiguity prove-visible --stock \
  --output reports/ambiguity/visible-stock
```

A successful run emits `PROVEN UNAMBIGUOUS`, a certificate, the intermediate
grammars and automaton, and a manifest binding them to SHA-256 hashes of the
source and transformation implementation. The saved 2026-10-01 source hash is
`a9e5a9c47d95e4ce0bef3b4c19b1d3d69e79d0e0f2a0b7db4a1947188d0485af`.
Consult the manifest for the authoritative hash; certificates never apply to
later grammar edits automatically.

The actual GLR run closed **2,704 configurations in 31 frames**, with a
**1,486-state exact model**. The source automaton has 1,766 states and 714
production shapes. The entire run, including grammar transformations, took
about 44 seconds in the investigation environment. The final fixed-point
search took about 0.1 seconds. None of these are input or nesting bounds.

Exit statuses are 0 for a verified proof, 1 for an exact ambiguity verdict,
2 for a command/input error, and 3 for an incomplete or unsupported proof.
Exhausting a time, component, model, or configuration limit cannot emit a
proof. The exact ambiguity verdict currently does not reconstruct a token
witness; use the existing recognizer/search to obtain one.

## What fundamentally changed

The former prover retains a suffix of each LR stack and guesses reductions
that reach below it. Making that suffix larger can remove a particular
spurious pair without making the whole grammar tractable.

This prover constructs a count-preserving model of the entire accepted
parse relation. It checks that horizontal recursion is regular after matched
bracket groups are treated as units, and uses visible stack operations only
at the brackets. Arbitrarily long horizontal sequences are finite automata;
arbitrarily deep nesting is a recursive summary fixed point. No LR stack is
truncated and no reduction source is guessed.

The model is weighted over the finite semiring

\[
S=\{0,1,2\},\qquad a\oplus b=\min(2,a+b),\quad
 a\otimes b=\min(2,ab).
\]

Here 2 means “at least two.” Every transformation preserves the number of
accepted derivations in this semiring. An accepting weight of 2 is ambiguity;
a closed reachability invariant containing only accepting weights 0 and 1
is an unambiguity proof.

## Count-preserving construction

### 1. Exact LR context grammar

For each retained reduction `A -> X1 ... Xn` in state `r`, enumerate all
bases `q` whose automaton path is labelled exactly `X1 ... Xn` and ends in
`r`. The nonterminal `(q,A)` emits this RHS, with each child nonterminal
annotated by the state preceding that child on the path. Attach the
reduction's actual one-token lookahead set as a guard. Terminal shifts and
nonterminal gotos must exist on the path.

These annotations are uniquely determined by a derivation from the initial
state. Conversely, a guarded derivation gives its exact left-to-right LR
reduction run. The package goto must accept end of input. This is a
bijection, not a stack approximation. Productive/reachable pruning and
structural bisimulation reduce its size.

The exporter checks the dump's production shapes against Menhir's erased
expansion. Duplicate shapes, noninjective normalization of parameterized
symbol names, unproductive starts, and unfamiliar action formats fail
closed. The current source has no duplicate production shapes.

### 2. Unique generic-angle annotation

Ordinary `<` and `>` are also comparison and declaration-operator tokens.
They cannot all be treated as visible brackets.

The checker certifies that every generic opening `<` has predecessor
`UIDENT` and a successor other than `LPAREN`. Every ordinary `<` fails this
condition. It also checks that generic interiors contain no ordinary `<` or
`>` through any nonterminal expansion. Consequently every accepted token
string has the same generic opening positions, and each `>` while a generic
region is open is its matching generic close. Tag these occurrences
`GLESS`/`GMORE`.

Each original derivation has exactly one tagged derivation, and competing
parses of an original string have the same tags. Proving the tagged grammar
unambiguous therefore proves the original accepted parse relation
unambiguous. The former bare-type-as-expression grammar fails this check.

### 3. Eliminate the guards exactly

Partition guarded nonterminals by their following token, and where necessary
by their first token or epsilon. Sequence nonterminals pass a child's guard
the first token of its suffix, or the enclosing following token when that
suffix is empty. These are least-fixed-point FIRST summaries, not bounded
lookahead approximations.

The actual yield fixes every such annotation uniquely. Thus this ordinary
CFG has exactly the guarded grammar's parse counts. A compact variant avoids
partitioning a child's first token when nothing constrains it. Balanced
bracket groups are kept together so intermediate sequence rules have balanced
terminal skeletons.

Remove deterministic unit aliases and uniquely epsilon-only nonterminals,
factor shared prefixes, and quotient structurally bisimilar equations.
Repeated alternatives remain repeated: they are derivation multiplicities.

### 4. Check regular horizontal recursion

Replace each directly matched bracket group by an opaque unit. Compute
strongly connected components of the remaining nonterminal dependency graph.
Each production must contain at most one child from its own component; all
nonempty context on recursive productions in a component must be consistently
on one side. Epsilon-only context contributes its exact multiplicity.

The current grammar passes every component. Components with nonlinear,
two-sided, or mixed-orientation recursion are rejected by this proof method.
Passing this structural check alone is not an unambiguity proof.

### 5. Compile counted horizontal languages

A right-linear component has one entry per nonterminal and a shared final
state. A left-linear component has a shared entry and one final state per
nonterminal. Production choices are weighted epsilon edges; terminals and
bracket groups are labelled edges. Tree derivations correspond to paths.

Compile lower components first, substitute their counted finite automata,
and then determinize and minimize each requested horizontal language. State
weights and accepting weights retain counts in `S`. Minimize before inserting
a language into its parent; inserting every unminimized continuation was the
source of the initial construction's exponential expansion.

Bracket atoms still distinguish their inner languages. Different atoms with
the same opening token may recognize overlapping bodies, so proving each
horizontal automaton alone would be insufficient.

### 6. Exact visible-stack fixed point

Expand bracket atoms into visible calls with a saved return state and matching
closing token. A bracket body's entry/end pair is a fragment. Internal
transitions consume ordinary tokens. Epsilon closures count paths exactly in
`S`, including cycles and parallel alternatives.

A deterministic control vector records weights `(fragment, state, count)`.
On an opening bracket, save a finite matrix from parent fragments and return
states to child fragments, and start each distinct child fragment with weight
one. On a closing bracket, multiply this matrix by the child's accepting
weight vector. This retains both overlapping child languages and ambiguous
parses within an individual child.

A frame is keyed by its child-fragment set and closing token. Its invariant
contains every reachable weighted control vector and every accepting summary.
New summaries propagate to all callers until no frame changes. There are only
finitely many vectors and return matrices over `S`; recursive calls reuse
frames. The invariant is closed under internal tokens, bracket calls, and
returns at every depth.

The certificate checker independently recomputes epsilon closures by a
bounded-path fixed point rather than the producer's delta propagation. It
checks all frame entries, all internal successors, all child frames, every
return successor, and the exact exit summaries. It rejects any root accepting
weight of 2. Closure proves the result for all input lengths and nesting
depths by induction over balanced words.

## Trust and validation

When `--grammar` is supplied, the checker also rebuilds the counted model
from the hashed final grammar in a fresh process. It checks weighted strong
bisimulation between the rebuilt and supplied models, independently of state
and fragment numbering. Each comparison state includes its active fragment
and whether it is accepting; call signatures retain the child/continuation
pair, and repeated edges retain their multiplicities. Thus a modified model
cannot pass merely by retaining the grammar hash. Without `--grammar`, the
checker verifies only the supplied model's finite invariant and reports
`model_binding: unchecked`.

The certificate checker is independent of the reachability search. The
Menhir dump, production exporter, grammar transformations, and counted
horizontal compilation remain trusted parts of the pipeline. This is an
executable proof with a mathematical construction and a checked finite
invariant, not a Rocq/Lean verification of those implementations.

Tests compare parse counts with an independent tree-height/span CFG evaluator
and a concrete-stack VPA recognizer. They exercise left and right recursion,
nullable ambiguities, epsilon cycles, ambiguous concatenation boundaries,
overlapping and disjoint bracket languages, and 100 nested brackets. They
also check factoring, rejected incomplete runs, corrupted certificates,
Menhir precedence, both backend modes, and duplicate source production
rejection. Model-binding tests cover token tampering, state renumbering,
acceptance, repeated edges, weights, and child/continuation pairing.

The final command dumps the original grammar with the selected backend.
`--dump` is after benign precedence resolution and before severe conflict
resolution; GLR retains those severe forks. In particular,
`--no-code-generation` must not be appended to a GLR invocation: it switches
the backend. Refeeding GLR's expanded grammar to GLR can perform another
nullable rewrite. Parameterized dump symbols are normalized injectively and
checked against the erased expansion instead.
