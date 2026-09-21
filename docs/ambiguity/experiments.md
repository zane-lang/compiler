# Measured and rejected

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
