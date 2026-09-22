# Proof obligations

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

## What a semantic action may do

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

## Where the current conflicts come from

Menhir reports 72 states with shift/reduce conflicts and 2 with reduce/reduce
conflicts; the explanations file accounts for 74 conflict blocks, since a state
carrying both kinds is explained once per kind. The table counts states rather
than token occurrences. They are not independent problems:

| Lookahead | States | Reduction | Root |
| --------- | -----: | --------- | ---- |
| `(`             | 6 | `loption_generics_ ->` | before a call or a lambda |
| `)` `?` `(` `<` `{` `[` | 3 | `loption_generics_ ->` | the same, where a type may also be the whole argument |
| operators, `(` `<` `{` `.` | 3 | `loption_generics_ ->` | the same, where a type may also be an operand |
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
| `{`             | 12 | `verb_call -> ... RPAREN`, `simple_decl -> ... RPAREN` | a constructor call's trailing argument against the same |
| `{` / `(` `{`   | 6 | `app -> ... DOT LIDENT` | a field access against a constructor body or its trailing form |
| `(`             | 3 | `primary -> LIDENT`, `primary -> THIS` | a bare name against a call or a lambda |

The `<` row is about the declaration form, not the comparison. Its nine states
all reduce toward `ret_type "<" "(" params ")" body`, the declaration of the
`<` operator, against shifting `<` as the opening bracket of a generic argument
list: after a name type, `Foo<Int> …` and `Foo <(a Int) { }` open with the same
two tokens. Dropping `<` and `>` from the operators a declaration may name
removes all nine and nothing else, which is what identifies the family; it is a
language change rather than a restructuring, so it is a measurement here and
not a proposal.

**The vanished terminator is one root, not six.** Twenty-one shift/reduce
states and both reduce/reduce conflicts — 23 of the 74 — trace to a single
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
`Statement_check`, which reads the statement's own tail off the tree. The
alternative — splitting the expression grammar into brace-ending and
non-brace-ending halves so that the terminator is decided by the shape — would
resolve them at the cost of two copies of every operator production, since
`a + match (e) { … }` ends in a brace because its right operand does. That trade
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
not among them. The reports are in
[`reports/ambiguity/prove/`](../../reports/ambiguity/prove) — the run that
found it, and the run that no longer does — and
[`spec-divergences.md`](../spec-divergences.md) §5 records what the terminator
costs against the spec.

What it leaves behind is the general lesson the ledger is for: a continuation
survey is evidence that an obligation is *plausible*, never that it holds. The
obligations below are open on the same footing.

The fifteen `{` states that reduce a completed call are **open obligations**.
A call may be closed by a trailing argument, so after `f(x)` a following `{` is
either that argument or the first token of the next statement — a statement may
open with a brace, since a map literal is a `primary` and so may be called or
assigned through. The smallest grouping rule attaches following syntax to the
nearest preceding construct that can accept it, which reads the brace as the
call's argument. Exactly one reading survives every case measured, but the
argument that one always does is the map-literal mark below, and it is not
written as a transience argument yet; until it is, these states carry neither a
precedence resolution nor a transience argument.

**A `match` does not reach this fork.** Its scrutinee list is parenthesized, so
the brace that opens the arms is read after a `)` rather than after an
expression, and `list_match_arm_` appears in no conflict explanation the
grammar produces. What made that necessary is recorded in
[`2026-09-18_full-grammar-ambiguity.txt`](../../reports/ambiguity/prove/2026-09-18_full-grammar-ambiguity.txt)
and closed in
[`2026-09-18_match-scrutinee-parens.txt`](../../reports/ambiguity/prove/2026-09-18_match-scrutinee-parens.txt):
with a bare scrutinee, `x Foo = match A { } <= B { }` had two complete
derivations — `(match A { }) <= (B { })` and `match (A { } <= B) { }` — because
an expression may itself end in a brace and an operator gives both groupings
enough to finish on. Every binary operator in the language produced it, and no
declaration in the precedence table could reach it, since `{` carries no level.
An operator was not even required: a postfix call on the match supplies the
second owner as well, and `match A { } ( ) { }` was the second family the
search found. Behind the family's own prefix that search now exhausts its
bound without a witness, on a sixth of the frontiers it explored before.

Twelve of the fifteen are the same question asked of a constructor call, which
reaches the fork through `verb_call` and through the instantiation shorthand
rather than through `computed_call`. The witnesses below are written with a
function call; the constructor spelling of each measures the same.

What the grammar does today is pinned by two witnesses, each accepted by
exactly one derivation, so the fork is resolved rather than ambiguous on them:

```sh
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN SEMICOLON RCURLY RCURLY EOF
```

`Unit use() { f() { g(); } }` reads the brace as the call's block argument,
since `g();` is a statement and the brace has no other owner once the body's
own `}` is spoken for. `Unit use() { f() { k, v; }(x); }` reads the same brace
as a map literal handed to `f`, because `k, v;` is an entry rather than a
statement — and not as a separate statement calling a map literal, which would
leave `f()` unterminated. That every brace whose contents read one way escapes
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

**A constructor call may trail its last argument, unless that would leave the
`( )` empty.** The fifteen states that rule adds are the fork above, reached
from six more places: twelve on `{` where a completed constructor call — the
call itself, and the instantiation shorthand that writes a name in front of it
— meets a brace that is either its trailing argument or the enclosing
construct's, and three that double the `app -> ... DOT LIDENT` family, where a
named constructor's `.member` now opens the trailing form as well as a field
access. Under GLR both readings are explored and one survives, measured on
every case in
[`test/parser/ambiguity_test.py`](../../test/parser/ambiguity_test.py) and
searched for in
[`reports/ambiguity/search/general/`](../../reports/ambiguity/search/general),
where the run that added the rule exhausted every sentence of at most nine
tokens without finding one.

Which token carries the fork was a choice. The trailing form reads a non-empty
argument list, and if the plain form reads `( )` as a list that may be empty,
the two diverge while the list is being reduced: the parser picks at the `)`,
before the `{` that decides is in view, and that spelling measures twelve
states on `)` instead. Giving the empty list its own production lets both
spellings share the non-empty one, so the `)` is shifted either way. The count
is the same; the fork is the one already on this ledger.

The empty list is the case the grammar has to keep out, and the reason is not
the constructor declaration the divergence entry used to name. `Foo() { ... }`
is a **lambda literal** whose return type is `Foo`
([`syntax.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/syntax.md)
§3.8 gives `ReturnType() { body }` as a form of its own), and a lambda literal
is an expression, so that reading is live everywhere the trailing one would be
— not only in statement position, where a constructor declaration is also
spelled that way. Nothing inside the form separates them: an empty argument
list and an empty parameter list are the same `( )`, and a trailing block
argument and a block body are the same `{ }`. Admitting the trailing reading
there gives `return Foo() { ... }` two derivations, measured; requiring
something inside the `( )` gives every spelling one. What makes `do() { ... }`
safe by comparison is the casing rule: a lower-case callee cannot be a return
type, so no lambda reading exists to collide with.

**A type may be written where a value is expected**, which is how the explicit
half of
[`generics.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/generics.md)
§5.3 reaches a verb — `Array(Int, 10000)` passes a type the way it passes a
number. Where the production sits is the whole of what makes that safe. A type
is never a postfix base: there is no dot access on a type, a name in front of
an argument list is already a constructor call, and a `[ ]` after a type name
is a verb-type suffix. So the production belongs at expression level, not among
the `primary` forms, which are exactly the ones `app` threads `.`, `(` and `[`
onto. Written as a `primary` it measures `Colors.red`, `Int(3)` and
`Span.point(0)` at **two** derivations each — an access, a call and a chain on
a type value, beside the readings they already have. Written at expression
level each stays at one, and so does every case in the suites.

The four states it adds — four more than the same grammar without the
production — are over the same empty generic list the family below is about:
after an uppercase name the parser cannot yet tell a type used as a value from
the head of an applied type or a constructor call, and the next token says
which. Three of them are the `loption_generics_` reduction under two new
lookahead sets — the argument position and the operand position — and the
fourth doubles the `primary -> LIDENT` state. No reduce/reduce state is added.

That they are forks rather than ambiguities is measured, not proved. Both
readings are explored and exactly one survives on every case in
[`test/parser/ambiguity_test.py`](../../test/parser/ambiguity_test.py), and the
search in
[`reports/ambiguity/search/general/`](../../reports/ambiguity/search/general)
exhausted every sentence of at most nine tokens without finding one. Neither
reaches inputs of every length, so these four stand where the rest of the
ledger does: **open obligations**, until `ambiguity prove` closes them or a
longer search finds a witness.

**Only a bare name may be written that way**, and the measurement is what drew
the line. Admitting an applied `Array<Int, 4>` as well costs three
**reduce/reduce** states, all of them `expr -> <name> loption_generics_`
against `list_verb_type_suffix_ -> ` — after the name, a `[` is either a verb
type's parameter list or a subscript, and the type-value reading has to be
complete before the parser knows. The spec's own examples pass bare names, so
the cheaper half is the whole of what §5.3 asks for;
[`spec-divergences.md`](../spec-divergences.md) records the rest.

Twenty-seven states reduce `loption_generics_ ->`, 21 of which predate the
terminator change and are unchanged by it. The empty generics reduction is load-bearing rather
than an artifact: expanding the option into two explicit alternatives raises
the count, and dropping generics from named types raises it too, both by
trading shift/reduce states for reduce/reduce ones. What it stands in for is a
genuine overlap in the surface syntax — `x Foo(…)` is either a constructor
shorthand or a lambda declaration whose return type is `Foo`, and nothing
before the closing bracket says which.

## The loose operator tier costs nothing

The loose forms of [`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
§3.1 — `'*` `'/` `'+` `'-` `'<` `'>` `'<=` `'>=` `'==` `'~=` — add ten terminals,
three precedence levels and three `expr` productions, and **no new conflict
block**. The census does not move at all, rather than moving by less than the
rest of the ledger: measured with the project's own `--GLR` build and again
without it, every conflict block before and after this change matches family for
family, on `(kind, tokens involved, reductions)`, with none new and none gone.

Two things make that so. A loose operator is strictly infix and lexically
distinct, so no loose token can begin an expression or end one — the decision
the parser faces at each is the same decision it already faces at the operator
being mirrored, and the precedence declaration settles it before it can become
a conflict, exactly as `%left STAR SLASH` settles `*`. And the mirror is one
tier deep by construction: the levels are fixed in the grammar rather than
chosen by a program, so there is no recursion between the tiers for a state to
have to unwind.

The tier is also what let `and` and `or` go. They were the compiler's own
stand-in for a level below the comparisons, and removing them — two terminals,
two productions, a `Logic` node and its `Logic_op` — moves the census by nothing
either, family for family, for the same reason: an infix level settled by a
precedence declaration never reaches the automaton as a conflict.
[`spec-divergences.md`](../spec-divergences.md) records that closure.

The lexer carries the part of §3.1 that the grammar would have found expensive.
Each loose form is a single token, so `'` must touch its operator, and the three
spellings the spec calls illegal — `a ''* b`, `'~a`, `a '| f()` — are rejected
for want of a token to spell them rather than by a rule that has to be stated
and then defended. A `'` between digits stays the separator of an integer
literal: that separator wants digits on both sides, and no loose form has them,
so `1'000'000 '* Int(2)` and even `2'*3` come apart the one way.
