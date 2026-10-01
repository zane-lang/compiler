# Ambiguity experiments

## Recursive delimiter summaries (October 1, 2026)

The experimental `ambiguity prove --balanced` mode was tested against grammar
commit `c9877e4196c5ae243b2f5c1e23206f38d8bc5d39`, using checksum-verified Menhir
20260209 and a standalone OCaml 4.14.1 build of the engine. This uses the
repository's pinned Menhir, but not its full OCaml 5 compiler toolchain.
All 468 distinct reachable production shapes have well-nested direct-terminal
skeletons, so the delimiter invariant applies. It does not settle the grammar.

| Probe | Memory budget | Timeout | Outcome |
| --- | ---: | ---: | --- |
| Ordinary level 1, refine 8, 12 rounds, trace | 4096 MiB | 300 s | Pair cap at 4,601,750; no refinement round reached |
| Balanced level 1, full terminal alphabet | 4096 MiB | 300 s | Summary cap at 4,601,750 |
| Balanced level 2, full terminal alphabet | 6144 MiB | 600 s | Summary cap at 6,902,626 after 293.97 s; peak RSS 6,011,920 KiB |
| Balanced level 1, ordinary terminal classes, refine 8, 12 rounds | 8192 MiB | 900 s | Summary cap at 9,203,501 after 255.52 s; peak RSS 4,576,768 KiB; no refinement round reached |

Every probe used `--max-tokens 0 --max-witnesses 1`, one worker, frontier
ratio 1, and a 30-second progress cadence. The token bound applies only to
concretization. Each probe ended `NOT PROVEN`, exit 3. The last run uses the
current implementation's alphabet: delimiter tokens stay distinct, while
ordinary interchangeable terminals use their existing class representatives.
The larger cap and changed alphabet mean this is not a controlled speed
comparison against the preceding run.

These are expensive null results. They establish neither that a larger budget
would finish nor that every finite stack precision must fail. Exact recursive
delimiter summaries close the *unbalanced-history family*, but they still
over-approximate parser context, and the relation space grows substantially.

### A real ambiguity changes the conclusion

A separate generated-sentence check found a genuine complete ambiguity.
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

Both readings obey the delimiter invariant. Semantic type errors in a reading
cannot discharge this grammar obligation: the parser already has two complete
derivations before type checking. A sound prover cannot certify this grammar
commit unambiguous. The generic-lambda/comparison overlap must be resolved
before further unambiguity proof work can succeed. The initial experiment did
not change syntax; the follow-up below records the adopted restriction. The reduced family is a prover soundness fixture
in `tests/ambiguity/prover/balanced_test.py`.

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
All their direct-terminal skeletons pass the nesting check.

Generated-sentence checking completed 100,000 package samples (seed
`20261002`, 80-token budget, depths 7–18) and 50,000 expression samples wrapped
as complete declarations (seed `20261003`, 100-token expression budget, same
depths). Every sample was accepted with one parse. These are samples, not
necessarily distinct sentences, and this is bounded evidence rather than a
proof.

The prover now constrains a reduction's possible base states by matching its
actual RHS symbols backwards, including the retained states. The previous
predecessor walk constrained only the number of edges. Smaller fingerprints
are also available without changing the conservative proof direction.

| Updated-grammar probe | Bits | Budget | Outcome |
| --- | ---: | ---: | --- |
| Before RHS matching: balanced level 1, refine 8 | 10 | 4096 MiB | Cap 4,601,750; 155.99 s |
| RHS matching: balanced level 2, refine 12 | 10 | 4096 MiB | Cap 4,601,750; 182.56 s |
| RHS matching: ordinary level 2, refine 12 | 0 | 512 MiB | Cap 575,218; 88.83 s; three refinement rounds |
| RHS matching: ordinary level 2, refine 24 | 0 | 1024 MiB | Timeout 300 s; 649,030 pairs; four rounds; 104 states deepened, maximum retained depth 13; peak RSS 1,332,688 KiB |
| RHS matching: ordinary level 2, refine 16 | 2 | 512 MiB | Cap 575,218; 37.17 s; no refinement |
| RHS matching: balanced level 3, refine 24 | 0 | 2048 MiB | Cap 2,300,875; 31.07 s; no refinement |
| RHS matching: ordinary level 2, refine 24, delimiter counts modulo 2 | 0 | 1024 MiB | Cap 1,150,437; 50.18 s; no refinement |

All use one worker, frontier ratio 1, `--max-tokens 0 --max-witnesses 1`;
none reached a proof or a new concrete ambiguity. Budgets are graph-entry
limits derived from the configured memory figure, not hard RSS limits. Runs
have different configurations, so elapsed times are not controlled speed
comparisons. Zero fingerprint bits enable useful refinement sooner, but the
remaining abstract context still produces spurious candidates and large
queues. Exact recursive nesting and modular count products did not solve
that at the tested budgets.

A separate scratch experiment replaced the general fingerprint with three
bits representing delimiter-pair parity. It still capped at 1,150,437 pairs
without refinement (114.03 s, 1024 MiB configured). That alternative was not
retained.

The updated restriction is covered by 16 complete-program cases. The existing
38 grammar regression methods also pass exact recognition checks; their AST
shape assertions were not run in this standalone environment. The prover
suite passes 149 tests. Native checks compare RHS matching with 20,000 forward
path queries and check recursive summaries, modular counts, and history
exclusions. The compiler with its full pinned OCaml toolchain was not built.

Changes to the grammar and to the prover's abstraction that looked obviously
right, were tried, and were not kept. They are recorded because the reasoning
that recommends them survives being told they do not work, so each of them
gets proposed again.

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
past any fixed lookahead, which is what the prover is for.

## Sharpenings that were measured and rejected

Two ways of giving the abstraction more stack look obviously right and are
neither. Both are recorded here because the reasoning that recommends them
survives being told they do not work, so they get proposed again.

**Carrying the stack's bottom entries.** The state that says which construct a
stack is inside sits at a fixed height near the bottom, while whatever the
construct contains piles up above it — which is exactly the shape that defeats
depth counted from the top, and exactly the shape a fixed number of entries
counted from the bottom would settle. It also multiplies the abstract stack
space, because every stack shorter than the bound becomes exact and stops
standing in for the others. On the current grammar a level-2 proof costs about
ten thousand pairs with no bottom kept, ninety thousand with three entries
kept, and does not finish within five minutes with five — while the context
markers that motivated it sit at height five and deeper.

**Keeping every stack under a height bound exact.** The same idea reached from
the other side, and the same blowup: "exact below height H" and "keep H entries
from the bottom" describe the same set of stacks.

**Ruling a candidate's sentence out by counting its terminals.** A production's
right-hand side spells exactly what its reduction pops, so a count relation
holding of every production is inherited by every sentence the grammar derives:
on this grammar every one of the 391 expanded productions contains as many `(`
as `)`, `{` as `}` and `[` as `]`, so no sentence can be unbalanced. Three of
the four candidates recorded in
[`reports/ambiguity/prove/`](../../reports/ambiguity/prove) are unbalanced
sentences, and refusing to report a pair whose sentence breaks such an
invariant removes all of them at no measurable cost — a 60-second survey walks
the same 21,018 pairs either way. It was implemented, measured, and taken back
out, because it is **unsound as a filter on reports**, for a reason worth
recording: pairs are deduplicated on first arrival, so the sentence a pair
carries is the first one that reached it, not the only one. A pair reached
first by an unbalanced sentence and later by a balanced ambiguous one is pushed
once, tested against the unbalanced sentence, and suppressed — and a run that
suppressed the only accepting pair prints a proof. The invariant is a fact
about sentences, and the abstraction's nodes are not sentences.

Made sound, it stops paying for itself. The counts have to become part of the
node, which is the same as saying the abstraction tracks them: nesting is
unbounded, so the counter needs a saturating domain, an unknown value that
cannot rule anything out, and one node per count vector where there was one
before. That buys precision the proof was not short of and multiplies a space
it already cannot walk. What the recognizer does instead is answer the same
question exactly, for the one sentence in hand, without touching the node
space.

This does not conflict with the viable-stack residue used by the prover. The
rejected experiment attached a fact about one reported sentence to a pair that
may be reached by many sentences. The residue is part of the pair's stack
identity and is updated by every parser move. It summarizes terminal-labelled
edges still present on the parser stack, rather than totals in the input, and
is checked only against an over-approximation of reachable automaton paths.

**Labelling the backward walk with the production's symbols.** A reduction of
`A -> X1 ... XW` pops entries that spell the right-hand side, so walking down
from the deepest retained entry along those specific symbols looks like it must
beat walking down along every edge that arrives there. It is the same walk. In
an LR automaton every transition into a state carries the same symbol — the
state is `goto(I, X)` for one `X`, which is what its item cores have the dot
after — so a state's predecessors by a given symbol are all of its
predecessors. Instrumented over a level-3 proof of the current grammar, the
labelled walk narrows nothing: zero sites, zero sources. `predecessors` builds
its table with `fun _ target` because the symbol it drops is a function of the
target.

What works instead is depth granted per state, at the state that asked for it,
with the reduction chains keeping what their own pops leave behind. That buys
exactness where a candidate needs it and leaves the rest of the automaton
standing in for itself.
