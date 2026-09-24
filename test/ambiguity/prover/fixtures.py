#!/usr/bin/env python3
"""The tiny grammars the prover is measured against.

Each is small enough to reason about by hand and chosen for one property: it
is ambiguous, or unambiguous, or conflict-free, or it puts the divergence
somewhere the abstraction has to work to see. That is what makes them usable
as a soundness corpus -- the answer is known by construction rather than by
the tool being asked.

They are data, and nothing here runs anything, so other callers can read them:
`tools/ambiguity/precision_sweep.py` sweeps the abstraction level over these
same grammars.
"""

# Two blind spots that share nothing: one palindrome over `a` and another over
# `x`, reachable from one start symbol through disjoint alternatives, each
# behind an opening token of its own so that the two empty sentences stay
# distinct. Retiring prunes the subtree under a site it gave up on, and the
# property that pruning could break is exactly the one retirement exists for --
# reaching what lies behind the site. A grammar with one site cannot tell the
# two apart.
#
# Both sites have to be blind spots rather than ambiguities. A real ambiguity
# is settled by the recognizer as soon as the abstraction names a candidate,
# and a settled grammar has nothing left to retire: the run reports the witness
# instead, which is the right answer and the wrong fixture.
TWO_INDEPENDENT_SITES = """\
%token L "l"
%token R "r"
%token A "a"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | L p EOF { () }
  | R q EOF { () }
p:
  | { () }
  | A p A { () }
q:
  | { () }
  | X q X { () }
"""

# Ambiguous: `a + a + a` groups two ways with nothing to choose between them.
AMBIGUOUS_EXPRESSION = """\
%token A "a"
%token PLUS "+"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | e PLUS e { () }
"""

# The classic dangling else: `if x then if x then x else x` attaches the else
# to either conditional.
DANGLING_ELSE = """\
%token IF "if"
%token THEN "then"
%token ELSE "else"
%token X "x"
%token EOF "<eof>"
%start <unit> main
%%
main: s EOF { () }
s:
  | X { () }
  | IF X THEN s { () }
  | IF X THEN s ELSE s { () }
"""

# The same shape as AMBIGUOUS_EXPRESSION, but the declared precedences remove
# the losing actions from the automaton, leaving it conflict-free.
PRECEDENCE_EXPRESSION = """\
%token A "a"
%token PLUS "+"
%token TIMES "*"
%token EOF "<eof>"
%left PLUS
%left TIMES
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | e PLUS e { () }
  | e TIMES e { () }
"""

# Plainly LR(1): one action per state and lookahead, no precedence needed.
LR1_LIST = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main: items EOF { () }
items:
  | { () }
  | items A { () }
"""

# Unambiguous but not LR: the parser cannot know it has reached the middle
# until the input ends, so this needs the GLR fork the policy allows. Proving
# it is the standing precision target for the abstraction.
EVEN_PALINDROME = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main: p EOF { () }
p:
  | { () }
  | A p A { () }
  | B p B { () }
"""

# A blind spot that accepts sentences the grammar does not derive. Every `a`
# has to be matched by a trailing `a` and the core is four `b`s, so `a b b b b
# b` is not a sentence -- but the top-1 abstraction loses the `a` it is standing
# on and accepts it anyway, and does so on a shorter sentence than any it
# accepts legitimately. That ordering is what makes it a fixture: the walk
# reports the shortest accepting pair it can find, so a grammar whose shortest
# ones are real never exercises a rejected candidate.
ACCEPTS_NON_SENTENCES = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main: p EOF { () }
p:
  | B B B B { () }
  | A p A { () }
  | B p B { () }
"""

# A small version of the unbounded lookahead family in the Zane grammar. After
# `MATCH UIDENT`, a `{ }` pair is either the match body or part of the nested
# expression. Every finite top-K stack abstraction used to admit both readings
# all the way to acceptance, even though exactly one has enough braces. The
# terminal residue attached to the viable stack path closes the whole family at
# level 1 rather than chasing one more nested sentence per refinement round.
RECURSIVE_MATCH = """\
%token LIDENT UIDENT LPAREN RPAREN LCURLY RCURLY MATCH EOF
%start <unit> package
%%
package: declarations EOF { () }
declarations:
  | { () }
  | declaration declarations { () }
declaration: LIDENT UIDENT LPAREN expr RPAREN { () }
expr:
  | UIDENT { () }
  | UIDENT LCURLY RCURLY { () }
  | LPAREN expr RPAREN { () }
  | MATCH expr LCURLY RCURLY { () }
"""

# Ambiguous, and the divergence is born on the EOF lookahead: `a` reduces to
# either `x` or `y`, and nothing before end of input distinguishes them. EOF is
# not one of the terminals the survey iterates -- it is a separate sentinel --
# so a grammar whose only divergence lives there is what catches a survey that
# counts sites on regular lookaheads alone.
EOF_REDUCE_REDUCE = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | x EOF { () }
  | y EOF { () }
x: A { () }
y: A { () }
"""

# Two identical-looking alternatives are still two distinct reductions and
# therefore two derivations. Menhir prints both as `e -> A`, which makes this
# fixture exercise production-occurrence identity rather than just a conflict
# between differently named nonterminals.
DUPLICATE_PRODUCTION = """\
%token A "a"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | A { () }
"""

# The duplicate reductions live on non-representative terminal B. If terminal
# equivalence discards reduction multiplicity, A and B merge and the prover
# only searches A, missing the ambiguous sentence `B EOF`.
DUPLICATE_NONREPRESENTATIVE_TERMINAL = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main: e EOF { () }
e:
  | A { () }
  | B { () }
  | B { () }
"""

# A prior sentence-blocking CEGAR walk merged the AM/AO histories after they
# reached the same abstract parser state and falsely reported a proof after
# excluding the first, singly parsed sentence. The reversed prefix has two
# parses, so a path-sensitive DFA product must keep it visible.
CEGAR_AM_AO_PERMUTATIONS = """\
%token AM "am"
%token AO "ao"
%token A "a"
%token LB "["
%token RB "]"
%token SEMI ";"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | AM AO d_outer EOF { () }
  | AO AM d_outer EOF { () }
  | AO AM d_suffix EOF { () }
d_outer: ty LB RB SEMI { () }
d_suffix: ty SEMI { () }
ty: A suffixes { () }
suffixes:
  | { () }
  | LB RB suffixes { () }
"""

# The same reduce/reduce conflict, but reached over two symbols instead of one.
# At proof level 1 the retained stack is a single state, so the competing
# reductions here are strictly wider than it while `EOF_REDUCE_REDUCE`'s are
# exactly as wide -- the two sides of the boundary the site dump has to keep
# apart.
WIDE_REDUCE_REDUCE = """\
%token A "a"
%token B "b"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | x EOF { () }
  | y EOF { () }
x: A B { () }
y: A B { () }
"""

# A conflict that is only reached after a reduction has already popped past the
# retained stack, which is what makes the rebuilt stack observable at all. `w`
# is six symbols wide, so at proof level 4 reducing it pops into the unknown and
# the abstraction rebuilds the stack from a goto target and a guessed source.
#
# Everything before `w` is a forced chain -- `p q r` can be reached exactly one
# way -- so the states below that source are determined by the automaton rather
# than guessed, and the rebuilt stack should reach the full retained depth
# instead of stopping at the two entries a rebuild starts from.
REBUILT_STACK = """\
%token P "p"
%token Q "q"
%token R "r"
%token A "a"
%token B "b"
%token C "c"
%token D "d"
%token E "e"
%token F "f"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | P Q R w x EOF { () }
  | P Q R w y EOF { () }
w: A B C D E F { () }
x: A { () }
y: A { () }
"""

# Three productions reduced in one state on one lookahead, so a pair walking
# through it takes two of them and leaves the third unselected. A trace claims
# to say what happened on the path this pair took, so the chain it never entered
# must not appear in it.
THREE_WAY_CONFLICT = """\
%token A "a"
%token B "b"
%token C "c"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | p C EOF { () }
  | q C EOF { () }
  | r B EOF { () }
p: A B { () }
q: A B { () }
r: A B { () }
"""

# No end-of-input terminal, so the two parses can only part ways under the
# sentinel the search appends. That is the case where the walk has no recorded
# edge to replay and has to fall back to the accepting node's own step.
SENTINEL_REDUCE_REDUCE = """\
%token A "a"
%start <unit> main
%%
main:
  | x { () }
  | y { () }
x: A { () }
y: A { () }
"""

# One nonterminal reachable both early and late. `d` can begin a sentence or
# follow four `B`s, so the goto that rebuilds a stack after an imprecise
# reduction has two sources, and the far one needs terminals a short sentence
# has not read. The bracket conflict is the shape the real grammar stalls on:
# on `[`, either the suffix list ends and the brackets belong to `d`, or
# another suffix begins.
LATE_ARM = """\
%token A "a"
%token B "b"
%token LB "["
%token RB "]"
%token SEMI ";"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | d EOF { () }
  | B B B B d EOF { () }
d: ty LB RB SEMI { () }
ty: A suffixes { () }
suffixes:
  |                  { () }
  | LB RB suffixes   { () }
"""

# The late arm again, with an unbounded blind spot bolted on. `pal` is the
# even-length palindrome, so no fixed retained depth ever separates its two
# parses and every level ends in a surviving candidate -- while the `B B B B d`
# arm still gives the abstraction guessed goto sources that no short stack can
# be standing on. A run needs both to show that the height test reports what it
# did even when the run does not end in a proof.
LATE_PALINDROME = """\
%token A "a"
%token B "b"
%token LB "["
%token RB "]"
%token SEMI ";"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | d EOF { () }
  | B B B B d EOF { () }
  | pal EOF { () }
d: ty LB RB SEMI { () }
ty: A suffixes { () }
suffixes:
  |                  { () }
  | LB RB suffixes   { () }
pal:
  |            { () }
  | A pal A    { () }
"""

# A chain that reduces several times before it shifts, over a stack deeper than
# the retained depth. `decl` wraps a `ty` whose own suffix list is built from
# bracket pairs, so closing the list on `[` runs `suffixes -> epsilon`, then
# `suffixes -> LB args RB suffixes`, then `ty -> U gen suffixes`, each popping
# from what the one before it left. Every one of those pops stays inside the
# retained stack, so every goto along the way resolves exactly -- but a chain
# that re-truncates at each step throws the deeper entries away between them,
# and the descent walks them back through every context `ty` appears in, which
# `alias` and `bind` make several. The chain then walks on over a stack no
# parse was standing on, with nothing about it reading as a guess.
MID_CHAIN = """\
%token U "u"
%token L "l"
%token DOT "."
%token LB "["
%token RB "]"
%token SEMI ";"
%token BANG "!"
%token EOF "<eof>"
%start <unit> main
%%
main:
  | decl EOF { () }
  | alias EOF { () }
  | bind EOF { () }
decl: U gen DOT L ty LB args RB SEMI { () }
alias: L DOT ty SEMI { () }
bind: BANG ty SEMI { () }
ty: U gen suffixes { () }
gen: { () }
args: { () }
suffixes:
  |                     { () }
  | LB args RB suffixes { () }
"""

AMBIGUOUS_GRAMMARS = {
    "expression without precedence": AMBIGUOUS_EXPRESSION,
    "dangling else": DANGLING_ELSE,
    "reduce/reduce on eof": EOF_REDUCE_REDUCE,
    "duplicate production text": DUPLICATE_PRODUCTION,
    "duplicate non-representative terminal": DUPLICATE_NONREPRESENTATIVE_TERMINAL,
}

UNAMBIGUOUS_GRAMMARS = {
    "lr(1) list": LR1_LIST,
    "precedence-resolved expression": PRECEDENCE_EXPRESSION,
    "even-length palindrome": EVEN_PALINDROME,
    "late arm": LATE_ARM,
}

# Conflict-free automata offer exactly one action per state and lookahead, so
# no pair of abstract runs can ever take differing moves. That makes the proof
# a property of the automaton rather than of the abstraction's sharpness, and
# it must hold at every level — given a pair budget large enough to finish,
# which the environment below leaves ample for grammars this size.
CONFLICT_FREE_GRAMMARS = {
    "lr(1) list": LR1_LIST,
    "precedence-resolved expression": PRECEDENCE_EXPRESSION,
}
