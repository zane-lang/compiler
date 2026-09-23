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
needs `;` depends on whether it ends in `}` — after `ran Bool = if(ready)` the
next token decides, and a `{` there continues the call. Checked from a raise in
an action, it failed 18 tests at once, every one of them on the early-ending
branch of a program that parses correctly one token later. The checks that stay
after the parse — a `;` after a closing brace, and a trailing argument
continued past its `}` — record the mismatch on the statement, and
`Statement_check` walks the finished tree, where the losing branches are gone.
Whether the `;` is there at all is the grammar's to decide, below.

The rule that follows: a check that depends on more than the branch it is in
belongs **after the parse**, over the tree that survived. A check that is local
to its own branch can stay in the action. Neither is a substitute for encoding
the rule in the grammar where the grammar can carry it.

## Where the current conflicts come from

A plain `menhir --explain` of the grammar — the stock build, without the
`--GLR` flag the compiler is built with — reports 43 states with
shift/reduce conflicts and 12 with reduce/reduce conflicts, and the
explanations file accounts for 49 conflict blocks. The census of the `--GLR`
build is larger and is tracked in
[#97](https://github.com/zane-lang/compiler/issues/97). The table counts states rather than
token occurrences. They are not independent problems:

| Lookahead | States | Reduction | Root |
| --------- | -----: | --------- | ---- |
| `(`             | 6 | `loption_generics_ ->` | before a call or a lambda |
| `)` `?` `(` `<` | 3 | `loption_generics_ ->` | the same, where a type may also be the whole argument |
| operators, `(` `<` `{` `.` | 3 | `loption_generics_ ->` | the same, where a type may also be an operand |
| `<`             | 9 | `loption_generics_ ->` | against `<` as a declared operator |
| `(` `<`         | 3 | `loption_generics_ ->` | a named type opening a call or a generic list |
| `(` `<` `{` `.` | 3 | `loption_generics_ ->` | a named type opening a constructor body |
| `(`             | 3 | `list_verb_type_suffix_ ->` | a type opening a statement, against a call |
| `(`             | 6 | `app -> ... DOT LIDENT` | a type member ending a package-scope declaration, against a named constructor call |
| `(`             | 2 | `app -> func_callee` | a package-scope declaration's value, against a call |
| `(`             | 3 | `primary -> LIDENT`, `primary -> THIS` | a bare name against a call or a lambda |
| `?` `??`        | 2 | `expr -> SPAWN verb_call`, `func_callee -> verb_call` | a spawned call against what follows it |
| `(`             | 1 | `expr -> SPAWN verb_call`, `func_callee -> verb_call` | *(reduce/reduce)* the same, before a call |
| `(` `[`         | 5 | a `_braced` rule against the same form continued | *(reduce/reduce)* a statement closed by a `}`, against a call or subscript written after it |

The `<` row is about the declaration form, not the comparison. Its nine states
all reduce toward `ret_type "<" "(" params ")" body`, the declaration of the
`<` operator, against shifting `<` as the opening bracket of a generic argument
list: after a name type, `Foo<Int> …` and `Foo <(a Int) { }` open with the same
two tokens. Dropping `<` and `>` from the operators a declaration may name
removes all nine and nothing else, which is what identifies the family; it is a
language change rather than a restructuring, so it is a measurement here and
not a proposal.

The two package-scope rows are the one place a declaration still ends without
a mark of its own. At package scope only `package` and `import` take a
terminator, and a declaration may open with `(` — the subscript declaration `(this T)[…] => …` — so a value
ending in a name or a type member meets a `(` that is either a call on it or
the next declaration.

**A statement is closed by its own terminator, and the grammar says which.**
lexical.md §6.3 requires a `;` after every statement except one that ends in a
`}`, where the brace closes it. [`stat`](../../lib/cst/parser.mly) writes each
form twice: once followed by `";"`, and — where its tail can end in a brace —
once ending in a `_braced` rule and nothing after it. `expr_braced` is the
right spine of `expr` with the tail restricted to a form that closes on `}`,
since `a + match (e) { … }` ends in a brace because its right operand does;
every left operand is still a plain `expr`, so the precedence table decides the
same groupings it decides everywhere else. `simple_decl_braced`,
`body_braced`, `abort_handle_braced` and `ref_target_braced` carry the same
restriction through the forms that reach an expression.

This was the ledger's largest open obligation, and it was a bug. The terminator
used to be optional, `boption(";")`, with the mismatch checked after the parse
by `Statement_check`. So a statement could end on any token, and then a `[` or
`(` after it — the two tokens a statement can begin with — had two owners. The
obligation claimed exactly one reading always survived; the scheduled proof run
of 2026-09-21 found `Int {} { abort false[]() }`, and the valid program next to
it measured two complete derivations:

```sh
ambiguity check UIDENT LCURLY RCURLY LCURLY ABORT FALSE LBRACKET RBRACKET LPAREN RPAREN SEMICOLON RCURLY EOF
```

— `abort false[]();` as one statement, and as `abort false` followed by
`[]();`. GLR has no way to choose between two finished parses, so the compiler
failed on it before `Statement_check` had a tree to read. `return` and an
assignment reached it the same way; `false[]` alone and `false()` alone did not.

Requiring the mark removed 29 shift/reduce states and the `boption`
reduce/reduce conflict of that family: every `[` state reducing an empty verb-type suffix,
the `[` states closing an `app` before a subscript, and the fifteen `{` states
below that reduce a completed call. Each of those witnesses now has one
derivation, and a statement with no mark is a parse error rather than a tree
`Statement_check` has to reject. What the grammar still admits is a `;` after a
statement that ends in a brace; that spelling has one parse, since nothing
begins with a `;`, so `Statement_check` still rejects it from the tree.

**The `(` `[` row is an ambiguity, not a fork.** It is what is left of the same
question, one step later. A statement closed by a `}` is followed by the next
statement, which may open with `(` or `[` — and a brace-closing primary or
constructor call may also take a call or a subscript after it. So
`abort match (x) { } (y)();` reads both as one statement and as
`abort match (x) { }` followed by `(y)();`, and both finish. lexical.md §6.3
settles which is meant — nothing may continue a statement past the brace that
closed it — but the grammar does not carry that yet. It measured two
derivations before the terminator was required and measures two now; it is
open, and it is a bug.

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
`{ }` body again. Twelve more `[` states of the same size appeared later on a
plain `type` declaration with no enum map in sight; they were a different
family — the optional statement terminator — and went with it.

**`package` and `import` carry a `;`, and the grammar requires it.** They are
the two declarations that end on a bare name — `import pkg$` ends just before
one — so their own shape says nothing about where they stop, and the terminator
says it instead. Every other package-scope declaration ends in a body, a
bracket, or an expression and still takes none. The rule lives in `header_decl`
and applies inside a body too, where the same two forms are statements.

This one is worth recording in full, because it was the first obligation that
turned out to be a bug rather than a fork. The state reducing
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
survey is evidence that an obligation is *plausible*, never that it holds.
Every entry below that rests on measurement rather than proof is open on the
same footing; the two that follow are settled by the grammar's shape.

**A call's trailing argument has one owner.** A call may be closed by a
trailing argument, so after `f(x)` a following `{` is that argument — the next
statement cannot begin there, because `f(x)` does not end in a brace and so is
not closed until its `;`. The fifteen `{` states that reduced a completed call
against that brace were open obligations while the terminator was optional;
requiring it removed all fifteen.

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

What the grammar does is pinned by two witnesses, each accepted by exactly
one derivation. They are written with a function call; the constructor
spelling of each measures the same:

```sh
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN LCURLY LIDENT LPAREN RPAREN SEMICOLON RCURLY RCURLY EOF
```

`Unit use() { f() { g(); } }` reads the brace as the call's block argument,
since `g();` is a statement. `Unit use() { f() { k, v; } }` reads the same
brace as a map literal handed to `f`, because `k, v;` is an entry rather than a
statement.

What tells a block from a map literal is load-bearing on its own. A **map
literal** stands in a value position behind no introducing token, and so does a block argument, so in
argument position the two can meet. They are told apart by the mark after the
first expression — a `,` opens an entry's value, a `;` ends a statement — which
is a parse rather than a scan, since both now hold `;`-terminated things. Both
readings are explored and exactly one survives on every case measured,
including the one that looks like a counterexample: a `match` consumes its own
scrutinee commas before the entry's mark is reached. `f({ a, b; })` and
`f({ g(); })` each have one derivation, and so do both of their trailing
spellings.

**A constructor call may trail its last argument, unless that would leave the
`( )` empty.** The call and the instantiation shorthand that writes a name in
front of it both reach the trailing form, and a named constructor's `.member`
opens it as well as a field access; that last is three of the six
`app -> ... DOT LIDENT` states in the table. Under GLR both readings are
explored and one survives, measured on every case in
[`test/parser/ambiguity_test.py`](../../test/parser/ambiguity_test.py) and
searched for in
[`reports/ambiguity/search/general/`](../../reports/ambiguity/search/general),
where the run that added the rule exhausted every sentence of at most nine
tokens without finding one.

The trailing form reads a non-empty argument list, and the plain form's empty
`( )` is a production of its own rather than a list that may be empty. Both
spellings then share the non-empty list, so the `)` is shifted either way and
the decision falls on the token after it.

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
