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

## Proof obligations

Every LR conflict state must carry exactly one of:

1. **A precedence resolution.** The conflict is resolved by a declared
   precedence or associativity; the resolution is deliberate and the
   intended reading is documented. Resolved conflicts are deterministic and
   need no further argument.
2. **A transience argument.** A short written proof that the two branches
   of the fork can never both reach acceptance, keyed to the conflict
   state's LR items so that grammar changes touching the construct
   visibly invalidate the argument.
3. **An open obligation.** Permitted, but tracked: open obligations are the
   standing targets of the bounded ambiguity search, and a found witness
   turns one into a bug.

A grammar change that introduces a new conflict state is incomplete until
the state is triaged into one of these categories.

### What a semantic action may do

An action runs on **every branch the parser has live**, not only on the branch
that goes on to be accepted. A conflict state forks, both branches reduce, and
the losing one is discarded a token or twenty later — but its actions have
already run by then.

So an action **MUST NOT** raise to reject its own branch. Raising ends the
parse, not the branch, and the input that dies is whatever was being read when
the losing branch got far enough to raise — which is ordinary, valid input.
`Parse_error.Rejected` is therefore safe only where the raise cannot fire on a
branch that competes with a valid reading: `attach_abort_handle` raises on a
handler following a trailing argument, and no valid program has one, so no
accepted input reaches it.

The statement terminator is the case that taught this. Whether a statement
needs `;` depends on whether it ends in `}`, which the grammar cannot see when
it has to choose — after `ran Bool = if(ready)` the next token decides, and a
`{` there continues the call. So the grammar takes either spelling and the
mismatch is checked afterward. Checked from a raise in the action, it failed 18
tests at once, every one of them on the early-ending branch of a program that
parses correctly one token later. The check now records the mismatch on the
statement and `Statement_check` walks the finished tree, where the losing
branches are gone.

The rule that follows: a check that depends on more than the branch it is in
belongs **after the parse**, over the tree that survived. A check that is local
to its own branch can stay in the action. Neither is a substitute for encoding
the rule in the grammar where the grammar can carry it.

### Where the current conflicts come from

Menhir reports 53 states with shift/reduce conflicts and 4 with reduce/reduce
conflicts; the explanations file accounts for 55 conflict blocks, since a state
carrying both kinds is explained once per kind. The table counts states rather
than token occurrences. They are not independent problems:

| Lookahead | States | Reduction | Root |
| --------- | -----: | --------- | ---- |
| `(`             | 9 | `loption_generics_ ->` | before a call or a lambda |
| `<`             | 9 | `loption_generics_ ->` | against `<` as a declared operator |
| `(` `<`         | 3 | `loption_generics_ ->` | a named type opening a call or a generic list |
| `(` `<` `{` `.` | 3 | `loption_generics_ ->` | a named type opening a constructor body |
| `[`             | 12 | `list_verb_type_suffix_ ->` | a vanished terminator against a verb-type suffix |
| `(`             | 3 | `list_verb_type_suffix_ ->` | the same, before a call |
| `(`             | 2 | `app -> func_callee` | a vanished terminator against a call |
| `[`             | 2 | `expr -> app`, `ref_target -> app` | a vanished terminator against a subscript |
| `(` `[`         | 2 | `boption_SEMICOLON_ ->`, `expr -> SPAWN verb_call` | *(reduce/reduce)* the same, on `spawn` |
| `?` `??` `(` `[` | 2 | `expr -> SPAWN verb_call`, `func_callee -> verb_call` | a spawned call against what follows it |
| `{`             | 3 | `computed_call_no_trailing_arg_ -> ... RPAREN` | a call's trailing argument against an enclosing brace |
| `{` / `(` `{`   | 3 | `app -> ... DOT LIDENT` | a field access against a constructor body |
| `(`             | 2 | `primary -> LIDENT`, `primary -> THIS` | a bare name against a call or a lambda |

The `<` row is about the declaration form, not the comparison. Its nine states
all reduce toward `ret_type "<" "(" params ")" body`, the declaration of the
`<` operator, against shifting `<` as the opening bracket of a generic argument
list: after a name type, `Foo<Int> …` and `Foo <(a Int) { }` open with the same
two tokens. Dropping `<` and `>` from the operators a declaration may name
removes all nine and nothing else, which is what identifies the family; it is a
language change rather than a restructuring, so it is a measurement here and
not a proposal.

**The vanished terminator is one root, not six.** Twenty-one shift/reduce
states and both reduce/reduce conflicts — 23 of the 55 — trace to a single
fact: a statement's `;` is optional
in the grammar, because whether it is required depends on whether the statement
ends in a `}`, and that is not a question a bracket answers. So the token that
used to end a statement can now be the first token of the next one, and every
reduction that used to be decided by seeing `;` is decided by seeing `[` or `(`
instead — the two tokens a statement can begin with. `type T = Int[]` followed
by a statement opening `[a] = b;` is the shape; the parser must close the
verb-type suffix list before it can know. The import state shared this root and
forked over a name rather than a bracket; it is the one place the missing
terminator produced an ambiguity rather than a fork, and what closed it is
below.

These are **open obligations**, and the reason they are permitted rather than
resolved is that the conflict is an artifact of where the check lives, not of
the language. Exactly one of the two readings survives the grammar in every
case measured, and the one that survives is then accepted or rejected by
`check_terminator`, which reads the statement's own tail off the tree. The
alternative — splitting the expression grammar into brace-ending and
non-brace-ending halves so that the terminator is decided by the shape — would
resolve them at the cost of two copies of every operator production, since
`a + match e { … }` ends in a brace because its right operand does. That trade
has not been made.

What removed twelve conflicts and what brought them back is worth recording
together. The twelve were on `[`, and all twelve were one adjacency: an enum
map's type was a `type_expr`, whose own run of verb-type suffixes had to be
closed before the entry list's bracket could be shifted. Which kind a bracket
group was depended on what followed its closing bracket, so deciding at the
opening one was a question LR could not answer. `enum_map_tail` shifted every
group before classifying it, which removed all twelve without changing what the
language accepted.

The spec then moved the enum map's entries from `[ ]` to `{ }`
([`adt.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/adt.md) §6), and
the adjacency went with it: the entry list no longer shares a bracket with the
suffixes, so the decision is made at the opening bracket by the bracket itself.
`enum_map_tail`, the classifier that carried a group's kind, and the two
rejected orders are all gone, and the enum map is a `type_expr` followed by a
`{ }` body again. The twelve `[` states in the table above are a different
family that happens to be the same size — they are the vanished terminator, and
they appear on a plain `type` declaration with no enum map in sight.

**`package` and `import` carry a `;`, and the grammar requires it.** They are
the two declarations that end on a bare name — `import pkg$` ends just before
one — so their own shape says nothing about where they stop, and the terminator
says it instead. Every other package-scope declaration ends in a body, a
bracket, or an expression and still takes none. The rule lives in `header_decl`
and applies inside a body too, where the same two forms are statements.

This one is worth recording in full, because it is the only obligation so far
that was a bug rather than a fork. The state reducing
`import_decl -> IMPORT LIDENT DOLLAR` was tracked as an open obligation: after
the `$`, a name was either the member being imported or the first token of the
next declaration, and with no terminator there was nothing between them to
read. It looked transient, and the shape of a proof looked clear — the shift
branch consumes a name the reduce branch needs in order to open a declaration,
so for both to accept, some token sequence would have to be a run of
declarations both with and without a name in front of it.

That is exactly what a run of declarations can be. `ambiguity prove` found it,
the first proof run to exit 1 rather than 3, and the recognizer confirmed two
derivations of

```zane
import core$
main Unit() { }
```

— a whole-package import followed by a lambda-valued declaration, and a member
import of `main` followed by a constructor declaration for `Unit`. Both halves
are complete declarations on their own, so no lookahead separates them. The
evidence behind the obligation had tried every continuation but this one: a
following `import`, a lowercase *variable* declaration, an uppercase verb
declaration, a `type` declaration, a constructor declaration and an enum map
each resolve to one derivation, and a lowercase *lambda-valued* declaration was
not among them. The reports are in [`reports/prove/`](../reports/prove) — the
run that found it, and the run that no longer does — and
[`spec-divergences.md`](spec-divergences.md) §5 records what the terminator
costs against the spec.

What it leaves behind is the general lesson the ledger is for: a continuation
survey is evidence that an obligation is *plausible*, never that it holds. The
obligations below are open on the same footing.

The three `{` states that reduce a completed call are **open obligations**. A
call may be closed by a trailing argument, so after `f(x)` a following `{` is
either that argument or a brace belonging to whatever encloses the call — in
`match f(x) { … }`, the arms. The smallest grouping rule attaches following
syntax to the nearest preceding construct that can accept it, which reads the
brace as the call's argument and leaves the `match` unclosed, so the rule and
the intended reading point opposite ways here. Settling that is a language
decision, and until it is settled these states carry neither a precedence
resolution nor a transience argument.

What the grammar does today is pinned by three witnesses. Two are accepted by
exactly one derivation, so the fork is resolved rather than ambiguous on them,
and the third is rejected outright:

```sh
ambiguity check LIDENT UIDENT EQUAL MATCH LIDENT LPAREN RPAREN LCURLY RCURLY LCURLY LIDENT THICK_ARROW INT SEMICOLON RCURLY EOF
```

`x Int = match f() { } { a => 1; }` is accepted, and reads the first brace as
the call's block and the second as the arms. `x Int = match f() { a => 1; }`
is accepted the only way it can be, since `a => 1;` is not a statement and so
cannot be the call's block. `x Int = match f() { a => 1; } { }` is rejected
for the same reason, once the arms are spent there is nothing left to take the
last brace. The first of the three is what block arguments added: before them
it was rejected. That every arm list which is not also a statement list escapes
the fork is the shape a transience argument would have to take, and it is not
one yet — the case where a brace's contents read as both has not been ruled
out.

That shape is now load-bearing in a second place. A **map literal** stands in a
value position behind no introducing token, and so does a block argument, so in
argument position the two can meet. They are told apart by the mark after the
first expression — a `,` opens an entry's value, a `;` ends a statement — which
is a parse rather than a scan, since both now hold `;`-terminated things. Both
readings are explored and exactly one survives on every case measured,
including the one that looks like a counterexample: a `match` consumes its own
scrutinee commas before the entry's mark is reached. `f({ a, b; })` and
`f({ g(); })` each have one derivation, and so do both of their trailing
spellings.

Twenty-four states reduce `loption_generics_ ->`, 21 of which predate the
terminator change and are unchanged by it. The empty generics reduction is load-bearing rather
than an artifact: expanding the option into two explicit alternatives raises
the count, and dropping generics from named types raises it too, both by
trading shift/reduce states for reduce/reduce ones. What it stands in for is a
genuine overlap in the surface syntax — `x Foo(…)` is either a constructor
shorthand or a lambda declaration whose return type is `Foo`, and nothing
before the closing bracket says which.

### Restructurings that were measured and rejected

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

## Tooling

- `ambiguity search [PROFILE]` — bounded, parallel GLR search for complete
  ambiguous sentences (`tools/ambiguity_search.ml`). A completed bound is a theorem
  ("no ambiguous sentence of at most N tokens"), up to the astronomically
  unlikely collision of the 124-bit frontier digests used for
  deduplication; an interrupted bound is evidence only.
  `AMBIGUITY_MEMORY_MB` sets an approximate total resident-memory budget shared
  by all workers. The tool derives two per-worker limits from it: a queue cap,
  which controls search reach and the live stack set, and an evicting
  digest-cache size, which controls deduplication.
  `AMBIGUITY_MAX_FRONTIER_RATIO` is the number of digest-cache entries per
  queued frontier: raising it trades queue reach for stronger deduplication,
  while lowering it does the opposite. The estimate is based on
  `queue * (600 + 24 * max_tokens) + cache * 240` bytes per worker. The cache
  limit covers both of its generations; it is not multiplied behind the
  scenes. Workers also monitor their actual OCaml heap: they compact at 80% of
  their share, first release the older (purely optional) dedup generation,
  stop admitting new frontiers at 90%, and resume below 85%. The remaining 10%
  covers the coordinator, native allocations, and transient compaction/
  copy-on-write overhead. This keeps memory near the configured plateau while
  prioritizing queue reach even when real frontiers are larger than the
  estimate. Named profiles in `ambiguity-searches.toml` collect search intent
  in one reviewable place. `ambiguity profiles` lists them, and command-line
  options can temporarily override a profile. The default `general` profile
  is breadth-first; `deep-function-body` fixes the function-body prefix and
  rotates depth waves so sibling statements continue to receive attention.
  The search itself is bounded by the profile's token range and timeout, and
  every run states the depth it reached and why it ended: the token bound was
  exhausted, or the timeout, witness limit or memory budget curtailed it. That
  distinction is what a result without witnesses is worth — an exhausted bound
  has checked every sentence that short, while a curtailed run has only stopped
  looking — so it is reported rather than left to be inferred.
  In an interactive terminal, one transient status line shows the active token
  depth, ambiguity families found at that depth, explored and unique frontiers,
  elapsed time, and a RAM bar against the configured memory budget. The
  coordinator deduplicates ambiguity families across workers before displaying
  the count. Redirected output and saved reports contain no progress line.
  `--nodes-per-depth N` expands up to `N` queued frontiers at one depth before
  descending to the next populated depth. When a deep wave ends, the search
  returns to the shallowest unfinished depth, so earlier token choices rotate
  instead of one deep subtree monopolizing the run. Smaller values are
  narrower and deeper; larger values explore more siblings before descending.
  Omitting the option preserves breadth-first scheduling. The scheduler does
  not prune queued frontiers, so a run that completes its bound remains
  exhaustive.
  `--min-tokens N` prevents shorter ambiguities from consuming witness slots.
  `--prefix-tokens "TOKENS..."` first advances the GLR parser through a fixed
  token prefix and searches from that frontier, which is useful for targeting
  contexts such as a function body. Minimum and maximum token counts include
  the prefix and `EOF`.
  Witnesses are grouped by the conflict states they
  traverse, which maps each finding directly onto an obligation above.
  Before searching, the tool computes **terminal equivalence classes**:
  terminals that behave identically throughout the LR automaton — the same
  shifts (up to a state bisimulation), the same reductions as a lookahead, and
  the same acceptance — are interchangeable, so swapping one for another is an
  automorphism of the recognition relation. The search explores a single
  representative per class instead of every interchangeable token, which cuts
  the branching factor wherever a construct admits several equivalent terminals
  (for the current grammar, the value atoms `FALSE`/`FLOAT`/`STRING`/`TRUE`
  collapse to one class, as do same-precedence operator groups such as
  `+`/`-` and `*`/`/`). Precedence and associativity are already resolved in
  the automaton's concrete actions, so tokens with different precedence never
  share a class; and a token that reaches a context the others do not — `INT`,
  which is also a const-generic argument — stays in its own class. Because
  class members generate isomorphic parse forests, a completed bound is a
  theorem up to renaming terminals within their class: an ambiguous sentence
  exists with one member iff it exists with every member, so no obligation is
  lost. Witnesses render with the representative terminal.
- `ambiguity prove K [PROFILE]` — conservative unambiguity proof mode built
  into the ambiguity search. It abstracts GLR stacks to their top-K states and
  exhaustively explores pairs of abstract parses of the same input, comparing
  reduction chains in lockstep. It does not depend on an external constraint
  solver. Three verdicts, each reported in the exit status so a script can act
  on it without reading the report: exit 0 "PROVEN UNAMBIGUOUS" is a genuine
  proof with no sentence-length bound; exit 1 means a concrete ambiguous
  sentence was found, which is a bug in the grammar rather than a limit of the
  abstraction; exit 3 means not proven — the abstraction reported a candidate
  the bounded search could not concretize, so raise the proof level or override
  the concretization profile; or the abstract pair limit was reached, so raise
  the memory budget; or the timeout expired mid-proof, so raise it. Exit 2
  keeps its usual meaning
  everywhere in this tool — the run itself failed — so a caller can tell a
  verdict from a broken invocation. Only proof mode reports a verdict: a plain
  `ambiguity search` exits 0 whether or not it found witnesses, since a bounded
  finding is not one.
  Because unambiguity is undecidable in general, the "not proven" verdict can
  never be eliminated entirely; the prover is validated against known-ambiguous
  grammars, LR(1) grammars, precedence-resolved expression grammars, and
  unambiguous non-LR grammars such as palindromes. That corpus lives in
  `tools/test_prover.py`, which pins both directions of soundness — an
  ambiguous grammar is never proven, and an unambiguous one never yields a
  witness — so a change that sharpens the abstraction cannot quietly start
  proving false theorems. A conflict-free automaton offers one action per state
  and lookahead, so no pair of abstract runs can ever diverge and it is proven
  at every level, given a pair budget large enough to finish: that is a
  property of the automaton rather than of how sharp the abstraction currently
  is, but exhausting the budget still reports "not proven", since a search that
  stopped early has proved nothing.

  Three things bound the abstraction's reach, and they are independent. **Its
  precision** is the proof level: below the top K states the stack is unknown,
  and a reduction popping into the unknown has to guess where it lands, which is
  where spurious candidates come from. The guess is narrowed by the shape of the
  automaton rather than left open. A stack is a chain of adjacent states — each
  entry is pushed onto the one below it by a shift or a goto — so a reduction
  popping `W` entries off a suffix that knows `D` of them lands on a state
  `W - D + 1` entries below the deepest one retained, and only states that many
  predecessor steps away are admitted. Popping exactly the known suffix is the
  one-step case, narrowed to that entry's predecessors. The set widens with
  every step past the suffix, which is the precision a deeper stack buys back,
  and it is empty exactly where the suffix reaches the bottom of the stack:
  nothing sits below the initial state, so a reduction that would pop past it is
  not a move any parse can make.

  A reduction that pops past the retained stack also has to *rebuild* it, as a
  goto target sitting on one of those guessed sources — two entries, with
  nothing underneath. Walking downward from the deepest entry recovers context
  wherever the automaton leaves no choice about what sits below, which holds
  for 860 of the current grammar's 1040 reachable states, and the walk stops at
  the first entry with more than one possible predecessor. Descending through a
  branch would mean carrying one stack per predecessor, and two stacks
  differing only in how a split resolved are different possible worlds rather
  than two parses of one sentence: the joint walk pairs each side's variants
  against the other's across every pair of distinct productions, so the cost of
  a split is quadratic in it while the depth it buys is not.
  `AMBIGUITY_DESCENT_LIMIT` raises the bound for a grammar that wants the
  split; the descent then stops at whatever depth it has reached when the next
  level would cross it.

  What makes stopping at a branch affordable is that a reduction chain no
  longer loses the depth it starts with. A chain fires several times before it
  shifts, and each reduction keeps the entries its own pop leaves behind rather
  than cutting the stack back to what the state left on top is entitled to
  retain. Without that, a chain whose every goto resolved exactly could still
  be standing on entries the descent had invented — imprecision that nothing in
  a trace reads as a guess, since each goto along the way was exact. Keeping
  them costs nothing that lasts: a pop never leaves more than it was given, and
  the shift that ends the chain cuts the stack back to the retained depth
  before it becomes a node the search stores, so the extra depth lives only
  inside one token's chain.

  All of that reads the automaton's shape, and shape is not the only thing
  known about a stack. **How tall it is** is a separate fact with its own
  consequences, and the abstraction used to have no way to hold it: a suffix
  says which states are on top and never says where the stack ends, so there
  was always assumed to be more below. That assumption is what admits a
  reduction with nothing left to goto from, and the guess about where it landed
  is what keeps spurious pairs alive.

  So an abstract stack carries its height. A reduction popping `W` entries
  needs `W` of them and a state underneath, so on a stack of exactly `W` it is
  not a move any parse can make, and the abstraction can say so instead of
  guessing. A guessed goto source is checked the same way against the fewest
  entries a stack can have with that state on top — the length of the shortest
  path to it through the automaton — which rules out sources belonging to parts
  of the grammar no stack this short has reached. Both bounds are minima over
  all paths, so refusing on them removes only moves no parse could make.

  While the height is exact it says more than a minimum. The reduction leaves a
  stack of a known height with the goto target on top, so the source is the
  entry directly below it, at a height one less — and every stack a parse
  builds starts at the initial state. A source the initial state cannot reach
  in exactly that many steps is not standing on any stack at all, however well
  it fits the automaton's shape read backwards. The same reasoning steers the
  rebuilding descent: when the height is exact it says precisely how many
  entries are still missing, so a candidate for one of them is only real if the
  bottom is still that many predecessor steps below it, which is what makes the
  walk forced as often as it is.

  The height is exact while it stays under a ceiling and saturates there.
  Saturation is the safe direction, because a stack that might be taller than
  any reduction is wide is one no reduction can be ruled out on, which is what
  the abstraction assumed everywhere before it counted at all — and a saturated
  height stays saturated through a reduction rather than having a width
  subtracted from it, since subtracting from "at least this" manufactures an
  exact height smaller than the truth and an undercounted height rules out
  moves a real parse can make. The ceiling only has to clear the widest
  reduction in the grammar, which is what keeps the abstract stack space
  finite.

  Knowing the height is also what lets a stack reach its own bottom. A suffix
  as long as the height is the whole stack, so the descent stops there rather
  than inventing entries below the initial state, and the reductions that would
  have popped past it are gone.

  A run says what the height test refused, for the same reason it says when a
  refinement request was clamped: a test that removes moves silently leaves the
  output looking like a search of a space it did not make. **Its budget** is
  the abstract pair limit, derived from `AMBIGUITY_MEMORY_MB` and
  `AMBIGUITY_MAX_FRONTIER_RATIO`. The abstract phase is a single sequential
  search, so the budget is derived for one worker and `AMBIGUITY_JOBS` does not
  divide it; the concretization search that may follow still uses every worker.
  The profile's token bound feeds the same estimate, so a narrower
  concretization profile also buys a larger pair budget.

  `--refine K` treats a candidate as a question rather than as an answer. A
  uniform proof level has to be paid for everywhere it is raised, and on a
  grammar this size the level that would close one blind spot is the level that
  makes the proof too expensive to run: level 2 takes about ten minutes and
  level 3 does not finish. Refinement instead deepens the retained stack only
  behind the candidate that needed it shallow, and tries again. `K` is a
  retained stack depth, the same quantity the proof level sets, and bounds how
  deep refinement may go; `--refine-rounds` bounds how many attempts it makes.
  Because the retained depth is a property of the state on top rather than of
  the run, deepening one blind spot leaves the rest of the automaton at the
  base level.

  A round grants the depth at the state that asked for it and nowhere else.
  Nothing has to be bought behind it: a reduction chain keeps the entries its
  own pops leave behind, so depth survives a chain rather than being re-capped
  at each step, and where a stack does arrive short the rebuilding descent
  walks it back down through the entries the automaton forces. That is what
  makes a round cheap enough to be worth repeating — a request granted to its
  whole backward cone instead reaches every state of a dense automaton at a
  depth close to the request, which on this grammar is the same thing as
  raising the uniform level.

  Invented gotos are not the only imprecision worth a request. A truncated
  stack conflates every real stack that ends the same way, and two of those can
  differ in what happens next, so a pair can survive an abstraction whose
  gotos were all exact. Each round therefore also walks the reduction chains
  and asks any stack cut below its own height for that height: a stack
  retaining as many entries as it is tall is the whole stack, and no deeper
  request can mean anything, since nothing sits below the initial state. The
  chains matter and not only the stacks between tokens — a candidate can reach
  acceptance with every recorded stack complete and every goto exact, standing
  the whole way on a chain that was cut short between them.

  Being cut short is not on its own a reason to ask. A truncated stack has lost
  nothing if walking it back down reconstructs the whole of it, since the
  entries were forced and the descent recovers the ones that were really there.
  So the walk runs to the stack's full height, and the depth is asked for
  whenever it comes back short of it — stopped at a branch, split into several,
  or handed a height too saturated to pin anything down. When neither the
  gotos nor the chains have anything new to ask, the round widens by one
  instead of stopping, which lets refinement climb to the ceiling the caller
  set rather than stalling well below it.

  Refining cannot produce a false proof. Every depth assignment
  over-approximates, because truncation is the only thing that ever shortens a
  suffix and nothing ever invents one, so a sharper abstraction can remove
  spurious pairs but never a real parse. That is what lets the choice of where
  to deepen be a heuristic without putting the verdict at risk, and it is
  pinned in `tools/test_prover.py` against grammars known ambiguous by
  construction.

  The round lines are worth as much as the verdict. Each names the candidate
  that provoked it and the deepest stack then retained, so a run shows directly
  whether a blind spot is bounded — the candidate changes, and eventually
  disappears — or unbounded, which answers every widening with a longer
  sentence. The palindrome does the latter unmistakably, pushing its
  counterexample out by one `A p A` nesting per round. That is the same
  conclusion a level sweep reaches by running a whole proof once per level, at a
  fraction of the cost. When refinement gives up it says why, and prints the
  surviving candidate's site in the same form a survey uses, so a stall can be
  read rather than guessed at.

  `--retire N` decides what to do about the unbounded case. Refinement pursues
  one candidate at a time, so a site no depth in this abstraction reaches keeps
  producing candidates for as long as there is clock left, and the run ends
  having said nothing about any other part of the grammar — the site with the
  longest queue of counterexamples decides what the whole run reports.
  `--retire N` stops pursuing a site once `N` consecutive rounds have left the
  divergence where it was, prints it, and carries on with the rest. Every later
  candidate born at a retired site is stepped over rather than answered, so the
  search reaches the sites behind it.

  A retired site takes its whole subtree with it. A pair inherits its
  divergence from its parent, and a site is where a divergence was *born*, so
  every pair below a diverged one reports that same site: the subtree under a
  retired divergence cannot produce a candidate anywhere else, and walking it
  is work with no possible outcome. Stepping over such a site without pruning
  it was measured on this grammar at 55 minutes and 1.3 million pairs after the
  retirement, with no second candidate and no end to the abstract phase. What
  this costs is a floor rather than a count: pairs are deduplicated on first
  arrival, so a pair first reached under a retired site is not pushed again
  from elsewhere, and a site reachable only that way is not found. That is one
  more reason a retiring run reports what it looked at rather than a proof.

  A site is identified by the two states on top of the diverging stacks and the
  lookahead, which is the part of it a deepening never changes: refinement
  lengthens what sits below those states, so the rendered site names a
  different triple after every round even when the blind spot has not moved.
  Two rounds landing on the same identity is what "the round bought nothing"
  means here. A site is retired for either of two reasons, both about that site
  alone: it has stopped moving under `N` rounds of deepening, or it wants more
  depth than `--refine K` allows. The round limit is a budget for the whole run
  and still ends it.

  Whether a blind spot is finite is not something a run can decide, so
  retiring is a decision to stop looking rather than a finding about the
  grammar, and the report says so in those terms. A run that retired anything
  never prints `PROVEN UNAMBIGUOUS`, however much it closed: the retired sites
  were stepped over, not answered. What it prints instead is the sharper
  statement that is actually available — the sites it gave up on, each with the
  sentence that reached it and the conflict behind it, and a verdict saying the
  grammar is unproven at those sites and closed everywhere else. It also always
  goes on to the bounded concretization search, because retiring drops the
  candidate that search would otherwise have been handed, and a retired site
  that was a real ambiguity rather than a blind spot has to still produce its
  witness.

  Splitting the rebuild at that stopping point was first tried on its own and
  measured at 26% more abstract pairs on this grammar and 75% more on the
  palindrome, without changing a verdict. It is in the tool now, because a
  split that reaches the bottom of the stack is worth what a split that stops
  four entries above it is not.

  A reading that came with it did not survive. A candidate that stalled here
  for a long time, `& ( Foo ) [ ] ;`, sat at a site whose two *competing* moves
  are both untagged — an empty `list_verb_type_suffix_` reduction against a shift — and
  that was taken to mean the pair was not being kept alive by a guessed goto at
  all, so that stack depth could not be the lever. `--trace` showed otherwise on
  its first run: the very first step of the walk guesses, at a state exact only
  from a retained stack of six. `conflict at stack …` prints the two moves in
  conflict, not the rest of the reduction chain they sit in, so untagged moves
  there say nothing about whether the step guessed. Read a localized conflict
  as evidence about precision and this is the mistake it invites.

  What the candidate looks like now is worth stating, because the shape did not
  change when the numbers did. The one that survives is `Foo . bar Baz [ ] ;`,
  and its stacks reach the initial state — `7 888 887 102 1 0` — which is the
  height doing its work: before it, a rebuilt stack floated above a branch
  point with entries assumed below it that were not there. What is left is a
  handful of guessed gotos on chains the refinement has already been given the
  depth for, which is a different situation from the one three abstractions ago
  and is where the next attempt starts.

  `--trace` follows a reported candidate from its divergence site down to
  acceptance. Every other diagnostic here reports where a divergence was
  *born*, which explains a candidate only when the site is also the reason it
  survived. When the site's own conflict is exact — two moves a real sentence
  could both begin with — the pair is admitted by both sides walking on to
  acceptance, and the step that should have killed one of them is somewhere
  along that walk, which nothing else shows.

  Each step names the token, the abstract stacks, and either `[exact]` or the
  states where a side had to guess a goto, with the retained depth that would
  have made it exact. That last number is the useful one: it is a refinement
  request the loop may not have been able to honour: a request past `--refine K`
  is clamped to `K` so the round still makes what progress it can, and the run
  now says so — `Refinement was capped: … the deepest is state N, which is
  exact from D` names the depth to raise the ceiling to. Before that line
  existed the clamp was silent, and a candidate could need a retained stack of
  11, be asked for 9 every round, and survive with nothing in the output
  saying the ceiling was the constraint.
  Reading a localized conflict that way is the trap this option exists to
  close: `conflict at stack …` prints the two *competing* moves, not the rest
  of the reduction chain they sit in, so untagged moves there do not mean the
  step guessed nothing.

  The walk replays the step the way the proof's own joint walk takes it, both
  sides in lockstep under the same pairing rules, and keeps only the joint nodes
  that can still reach the outcome the recorded child carries. A reduction is
  reported when it fires on an edge between two such nodes — taken on a path
  that demonstrably ends where this pair ended. Scanning each side's chains
  separately, or asking only whether a chain can reach one of the child's
  stacks, would report guesses from branches the pair never entered, and a trace
  that names the wrong state to sharpen is worse than none. Guesses carry no
  side attribution, because a pair is stored with its two sides ordered and
  which one became which is not recoverable; labelling them would be a guess
  about a guess.

  `--survey N` answers a different question from a proof. The proof stops at
  the first divergence it can reach, which says nothing about how many more lie
  behind it — and that count is what decides whether sharpening the abstraction
  is worth attempting. A survey walks the whole abstract space instead,
  reporting how many **distinct sites** produce a divergence, with up to `N`
  example sentences. A site is the stack pair and lookahead at which two parses
  first part ways, so the same blind spot reached by many sentences counts
  once. A handful of sites is a tractable list to attack; a large number means
  the grammar is not unambiguous for any reason this abstraction can see, and
  the remaining conflicts belong in written transience arguments rather than in
  a larger proof level. Surveying costs more than proving, since it cannot stop
  early, and its counts are a floor rather than a total if the pair budget or
  the timeout cut the walk short.

  Each example is printed with the site it was born at, because the sentence
  alone does not say why the pair was admitted — the same trail appears whether
  two parses genuinely differ or the abstraction merely lost the context that
  separated them. Under the sentence come the lookahead, the abstract stack
  (top state first, cross-referencing the `.automaton` file), and the two moves
  in conflict, with productions named as `menhir --explain` names them.

  A site holds one stack rather than two. Two runs can part ways only by taking
  different moves, and the step that does marks the pair diverged, so every
  pair still undiverged carries the same stack on both sides.

  The conflict is reported at the stack it fires from, which is usually **not**
  the site's own. The chain reduces in lockstep for as long as one move is on
  offer, so a site's top state typically shows a single shared reduction and
  explains nothing; the competing moves appear a step or two further down. The
  report follows the shared chain from the site until a stack admits two moves
  that two parses of one sentence could take — two different productions, or a
  reduction against a shift — and prints that stack and those moves. Moves that
  share a production and differ only in their goto are different possible
  worlds rather than a divergence, so the chain continues through them.

  A reduction is tagged by how far it pops, which is what says how much the
  abstraction had to invent about where it lands. An untagged reduction pops
  less than the retained stack, so its goto resolves exactly and nothing was
  lost. `[pops the retained stack exactly: goto limited to predecessors]` pops
  the whole retained stack, exposing whatever sat directly below its deepest
  entry — the goto source is narrowed to that entry's predecessors, so it is
  constrained but no longer known. `[pops past the retained stack: any goto
  edge]` pops further still, landing somewhere the stack constrains in no way,
  where every goto edge on the reduced nonterminal stays admissible.

  Only the third is unconstrained context loss, and the three must be read
  apart: the middle case is already narrowed by the predecessor filter, so
  treating it as the third points a refinement at a gap that is not there. A
  conflict whose competing moves are `pops past` reductions is a candidate for
  sharpening the abstraction; one between genuinely different productions over
  stack that is retained or predecessor-constrained is a real conflict to
  settle in the grammar or in a transience argument.

  Which of those two a site turns out to be shows in how its example behaves as
  the level rises. A bounded blind spot keeps the same shape and disappears at
  some level; one that stands on unbounded stack correlation grows longer with
  every level and never disappears, because defeating a deeper abstraction
  simply takes a longer sentence. The palindrome in the corpus is the second
  kind, which is why no level proves it. **Its time** is
  `--timeout`, which each search phase gets in full: the abstract proof runs
  under its own deadline, and the concretization search that may follow starts
  a fresh one, so a proof run's worst case is twice the value passed. A proof
  cut short by either deadline reports "not proven", never a proof.
- `ambiguity classes` — lists the terminal equivalence classes the search
  collapses, so a grammar change that unexpectedly splits or merges a class is
  visible. The same classes bound the prover's terminal alphabet.
- `syntax-experiment` — compares candidate grammar changes under
  equal search bounds before they are adopted
  (`tools/SYNTAX_EXPERIMENT.md`).
- `menhir --explain` — enumerates the conflict states that constitute the
  obligation ledger.

### Watching a run

Every tool here writes as it goes, so a run in progress is readable rather than
a wait for a verdict. The engine flushes each line as it prints it, `ambiguity`
streams the engine's output to the terminal and into `--output` line by line,
and the sweep passes each level's output through under a `[level N]` prefix
while the level runs. What ends up on disk is therefore always current: a run
that is killed or interrupted leaves behind everything it had printed, not an
empty file.

Both long phases report their own throughput. The abstract phase prints how
many stack pairs it has settled, how many are still queued, and how many
accepting divergences it has found; the concretization search prints its depth,
witness count, explored and unique frontiers, and resident memory. On a
terminal these are one line rewritten in place several times a second.
Elsewhere — under a wrapper, in a saved report, in CI — there is no cursor to
move back to, so the same numbers go out as ordinary lines every ten seconds and
stay in the log.

`AMBIGUITY_PROGRESS_SECONDS` overrides that cadence; zero or less turns progress
off entirely, for a caller that wants the verdict and nothing else. Anything
that is not a finite number is refused rather than obeyed: `nan` and `infinity`
parse as floats and would each be taken for a setting and then quietly show
nothing, one reading as switched off and the other as enabled but never due. Unlike the
four settings below it is optional, so it does not belong in
`machine-config.txt` — it is a property of how a particular run is being
watched, not of the machine. The sweep's `--quiet` (`just sweep GRAMMAR
--quiet`) and `syntax-experiment --quiet` suppress the pass-through of the
engine's output without touching what the sweep or the experiment prints
itself.

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

## Local machine configuration

The ambiguity-tool executables load machine-specific values from the ignored
`machine-config.txt` file. Copy `machine-config.example` before running them.
There are no fallback values: a missing setting is an error. This keeps memory,
worker-count, and executable-path tuning out of normal command invocations and
out of version control. The file supplies `AMBIGUITY_MEMORY_MB`,
`AMBIGUITY_MAX_FRONTIER_RATIO`, `AMBIGUITY_JOBS`, and `AMBIGUITY_MENHIR` as
environment variables; they are deliberately not command-line options.

Search intent lives in versioned profiles, with concise overrides for one-off
runs. For example, `ambiguity search general --tokens 0..100 --timeout 1h`
searches through 100 tokens for up to one hour, using the local machine budget.
Friendly durations such as `90s`, `30m`, and `1h` are accepted. Add
`--output report.txt` to display and save a report, or `--dry-run` to inspect
the resolved settings without building the engine.

Every profile setting has an identically named override flag: the TOML key and
the `--flag` share the same kebab-case spelling (`tokens`, `timeout`,
`witnesses`, `prefix-tokens`, `nodes-per-depth`, `breadth-first`, `output`), and
the command line overrides the profile. A single registry in
`tools/ambiguity.py` declares every flag once — value flags, the `breadth-first`
toggle, and the `dry-run` mode alike — and marks which ones profiles may set, so
the flags and the profile keys are one list and cannot drift apart. The only
flag that is not a profile key is `--dry-run`, which is a run mode (show the
resolved settings without running the engine), not saved search intent.

Scheduling is one slot with two spellings: a profile sets either
`nodes-per-depth = N` (depth waves) or `breadth-first = true` (shortest-first),
never both. Because breadth-first is now a real key, a child profile can reset
an inherited `nodes-per-depth` back to breadth-first (or the reverse) — the
child's choice replaces whichever the parent set. On the command line,
`--breadth-first` overrides a profile's `nodes-per-depth`, and giving both
`--breadth-first` and `--nodes-per-depth` at once is an error.

The `output` path — whether set as a profile key or passed with `--output` —
may contain placeholders that are filled in when the run starts: `{profile}` is
the resolved profile name, and `{date}`, `{time}`, and `{datetime}` are
timestamps laid out like the existing `reports/` filenames (`2026-07-23`,
`21-38-17`, and `2026-07-23_21-38-17`). Any directories in the expanded path are
created automatically, so `output = "reports/{profile}-{date}.txt"` in a profile
(or `--output reports/{profile}-{date}.txt` on the command line) drops a dated
report into `reports/` without a manual `mkdir`. Write `{{` and `}}` for literal
braces.

To concentrate a run inside a function body and favor depth over breadth:

```sh
ambiguity search deep-function-body
```

To change just one aspect without creating a profile:

```sh
ambiguity search deep-function-body --nodes-per-depth 4 --timeout 2h
```

Exact witnesses can be checked without quoting their token names:

```sh
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN EOF
```

## Why this is sound

Unambiguity of an arbitrary grammar admits no complete decision procedure,
but a *specific* grammar is proven unambiguous by a finite argument when
its structure supports one. Keeping the obligations discharged is exactly
keeping such a finite argument in existence at all times: determinism
certificates where the grammar is locally LR, human induction arguments
where it is not, and exhaustive bounded search as the continuous attempt at
falsification.
