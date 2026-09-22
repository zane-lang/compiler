# Soundness

What `ambiguity prove` is allowed to conclude, and why.

The command itself — how it is run, what each verdict's exit status is, and the
profiles and machine settings it takes — is in [`tooling.md`](tooling.md). This
document is the argument behind it.

## What bounds the abstraction

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

**Which terminals remain on the viable stack** is another finite fact the
suffix used to discard. Each terminal labels an automaton edge. The prover
assigns those labels a nonzero 10-bit fingerprint and carries their XOR in
every abstract stack. A shift XORs in its terminal; a reduction XORs out the
terminals written directly in that production's right-hand side. These are
exact updates for every concrete LR stack, including arbitrarily deep ones.

Before the walk starts, the prover computes which `(state, residue)` pairs
occur on paths from the initial automaton state. Every concrete viable stack
is such a path. A guessed reduction base whose residue cannot reach its
selected state is therefore invented context and can be refused. This closes
recursive families where every finite suffix loses one more delimiter, such
as nested `MATCH` expressions whose braces were falsely reassigned between a
constructor and the match body.

The fingerprint is conservative. Hash collisions merge paths and admit
extra moves; they cannot rule out a concrete one. The residue is part of the
abstract node, so two paths with different fingerprints are not collapsed by
pair deduplication. Acceptance requires residue zero because the accepting
stack contains the initial state and the start-symbol goto, with no terminal
edge left on it. A run reports how many moves this test refused and the
number of residue classes used.

While height is exact, the reachability check now asks for a single path
with both that height and that residue. Separate tests would allow one path
to supply the height and another to supply the residue, even when no stack
satisfies both. A bounded dynamic program over automaton edges computes
this joint table. Saturated heights use unrestricted residue reachability,
so saturation never manufactures an exact height.

The retained suffix adds further constraints. Where all incoming edges to a
state have the same residue, removing that edge's contribution gives the
residue at the next retained state. Each such prefix must also be reachable
at its corresponding height. If incoming edge residues disagree, the check
conservatively stops; it never guesses which label a concrete path used.

Reduction results are cached by stack and production, since lookahead only
enables a reduction and does not change its result. Completed single-stack
closures are also shared across pairs, under a bounded optional cache. All
these caches are rebuilt for each refinement precision.

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

**A round is aimed by the real parse, not by the whole path.** Replaying the
candidate through the recognizer says which stacks a real parse of that
sentence was standing on after each of its tokens, and the abstraction's own
stacks are compared against them step by step. The first step whose abstract
stack no real stack carries is where the abstraction left the language: the
steps before it were tracking a parse that exists, the ones after are a walk
the real parse never took. The round asks for the depth the guesses at that
one step wanted, and the whole-path scan stays as the fallback for a
candidate that never parts from a real parse — which is what a genuinely
ambiguous sentence does, since both of its parses are real. The saving is
rounds rather than milliseconds: the palindrome in the corpus reaches the
same verdict in five rounds where the unaimed scan took eight. How much it
narrows a single round depends on where the step falls. A candidate whose
real parse dies in the middle of the sentence names a step with a short chain
in it; this grammar's standing candidate dies at end of input, where the
chain that unwinds the whole package is the longest one there is, so aiming
takes its first round from 52 states down to 43 rather than to a handful.

**An aim that stops moving the blind spot is widened, not repeated.** A site
that answers a round with the same site has not been moved by it, and asking
the same step again buys one entry per round — the crawl the jump above
exists to avoid, paid for with a whole abstract phase each time. So a repeat
falls back to every guess on the path, and the aim resumes at the next site.
The difference is the whole outcome on this grammar: aimed alone, the
`x Foo(y(Bar)` site takes rounds 4 through 15 and is still standing at a
retained stack of 18; widened on the repeat, it closes at round 5 and the run
moves on to sites behind it.

**Rounds share one walk.** A round used to re-prove the grammar from nothing
at the precision the last one left behind, which is what made the rounds get
dearer as they went: the twenty-second round of a ninety-minute run was
re-deriving the first round's pairs before it could reach anything new.
Nothing about the previous round's work goes stale, though. Deepening a
retained stack only sharpens the abstraction, and a sharper abstraction has
fewer behaviours than the one it refines — so a pair explored under the blunt
abstraction and found not to accept cannot start accepting once the stacks
behind it get longer. The pairs are a result about the grammar, not about the
round that found them, so the table and the queue live across rounds.

What a deepening does put back into play is the pairs standing on it, and
what that means depends on whether the walk has been through them. A stack is
truncated to what the state on top is granted, so deepening a state changes
every stack that state appears in. A **settled** pair — one the walk has
already taken its successors from — is still true, and stays: deleting it
would strand the ancestry that the trail and the site read. What is missing
is the sharper pair that would stand in its place, and that is reached by
asking the pair before it again. An **unsettled** pair — pushed but not yet
walked — is not a result at all, only a plan to look, and a stale plan is
the round's own work undone: left in the queue, the walk looks at the blunt
pair instead of the sharp one. Those are discarded, and their parents rebuild
them at the precision that now applies. Each round prints both: `reopened
355 of 4955 settled pair(s) from 399 entry point(s), discarding 4674 queued`.
The two counts are of different things and usually of different sizes: at any
moment most of the table is queued rather than settled, so a round on this
grammar reopens between a twentieth and a third of what it had settled while
discarding several times that many plans to look, where restarting threw away
both entirely every time. Measured against the same run without it — same flags, same five
minutes — the walk reaches eight rounds where restarting reached three.

Two things follow from sharing the walk. **A retirement empties it**: a pair
is deduplicated on first arrival, so it keeps the ancestry it was first
reached by, and after a retirement that ancestry decides whether it is
stepped over — a pair first reached through the site just retired is written
off, and a site behind it goes with it. Restarting every round hid that;
carrying the table does not, and the palindrome loses its second site to it.
So retiring resets the walk, which costs the round it happens in and keeps
the rest. **And the queue is bucketed by depth** rather than a single FIFO,
so the walk still meets the shortest candidate first: a round otherwise
resumes with deep pairs left over beside shallow ones just reopened, and
would report whichever lay nearest to where it stopped.

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
pinned in `test/ambiguity/prover/` against grammars known ambiguous by
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

## What a derivation has to be

Everything above is about which *derivations* the abstraction can tell apart.
What counts as one is a separate question, and the answer is not "whatever the
automaton accepts": the grammar admits both spellings of a statement's
terminator on purpose and `Statement_check` rejects the wrong one after the
parse, so a raw accepting derivation may be no reading at all. Two of those are
not an ambiguity, and a run that reported them would be reporting a bug in a
language nobody can write. The scheduled proof run of 2026-09-21 did exactly
that, on `Int {} { abort false[]() }`, whose two derivations leave a statement
unterminated apiece.

`Validity` closes that where a derivation is still separable: at the reduction
that completes a statement, which is the only place the rule is about. The
predicate is positional rather than structural, and it is the same rule.
`Statement_shape` walks the tail of a statement's tree to decide one thing —
whether its last token is a `}` — and at that reduction the token last shifted
*is* that token, for every form in the walk: a map literal, a field body, a
match's arms and a trailing argument end on the brace, while a subscript, a
collection, parentheses and a bare name end on `]`, `)` or the name. So
refusing the reduction removes exactly the derivations carrying a defective
statement, which is what makes the count a count of programs.

Two things follow for the verdicts. **The filter is concrete-side only.** The
abstract phase reasons about every sentence at once and so has no position in
one to read the model at, so it keeps over-approximating; a candidate it raises
is settled by the recognizer as before, and one whose derivations are not
programs is now answered "not proven" rather than "ambiguous". That is the
honest verdict: the obligation behind such a candidate is neither discharged
nor refuted. **And the filter can only remove candidates, never a proof.**
Refusing a reduction removes derivations, so a grammar the abstraction proves
unambiguous over raw derivations is proven over this subset of them too.

What it does not model is the other half of `Statement_check`: a trailing
argument's `}` ends its statement, so nothing may continue past it. That is not
a property of the statement's last token, so the reduction's position does not
decide it. Leaving it out over-counts, which can leave a spurious witness
standing but cannot hide a real ambiguity — so a reported witness is still to
be read rather than believed, and that is the direction the omission has to
point.

## Why this is sound

Unambiguity of an arbitrary grammar admits no complete decision procedure,
but a *specific* grammar is proven unambiguous by a finite argument when
its structure supports one. Keeping the obligations discharged is exactly
keeping such a finite argument in existence at all times: determinism
certificates where the grammar is locally LR, human induction arguments
where it is not, and exhaustive bounded search as the continuous attempt at
falsification.
