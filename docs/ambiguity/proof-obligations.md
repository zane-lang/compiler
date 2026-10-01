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

The grammar has two censuses, because Menhir builds two different automata from
it. The parser that ships is built with `--GLR`, and in that mode Menhir first
rewrites every production ending in a nullable symbol into an empty and a
non-empty alternative (the Menhir manual, §13.6, "Expansion of nullable
suffixes"). The stock automaton is the grammar as written — what a plain
`menhir --explain`, `just explain` and the ambiguity tools read, and what state
numbers in a proof report refer to.

| Automaton | Conflict states | with shift/reduce | with reduce/reduce |
| --------- | --------------: | ----------------: | -----------------: |
| `--GLR`, the parser that ships | 53 | 52 | 8 |
| stock | 46 | 45 | 7 |

Menhir explains each conflict state once, so the explanations file holds one
block per state; a state with both kinds of conflict counts in both of Menhir's
warnings, which is why those do not add up to the state count. The state count
and its families are checked for both automata; the per-kind columns are
Menhir's own warnings, which `dune build` prints and nothing compares. `dune
runtest` summarises each explanations file by family into
[`tests/grammar/golden/`](../../tests/grammar/golden) — `parser.conflicts.census`
for the build's own, `stock.conflicts.census` for the stock one — and a grammar
change that moves either is a diff to read, reconcile with this section, and
promote.

The two are the same forks, reported at different places. With the empty
generic list expanded away, a fork the stock automaton reports as reducing
`loption_generics_ ->` is reported as reducing the name itself —
`type_expr -> UIDENT` and its qualified and `&` forms — and a fork on whether
an empty `( )` is a call or a parameter list, which the stock automaton decides
at the `(` by reducing the empty generics, the `--GLR` one decides at the `)`,
by reducing the empty parameter list. Every family in one census has its
counterpart in the other; what differs is the productions it is reported under
and how many states it spans.

The rewrite happens only on the way to generated code, so
`menhir --GLR --no-code-generation --explain` reports the stock census. The
shipped one is what `dune build` prints and writes to
`_build/default/lib/cst/parser.conflicts`.

The table below is tallied on the stock automaton, since that is the one the
tools number states by. It counts states rather than token occurrences. They
are not independent problems:

| Lookahead | States | Reduction | Root |
| --------- | -----: | --------- | ---- |
| `(`             | 6 | `loption_generics_ ->` | before a call or a lambda |
| `?` `(` `<`     | 3 | `loption_generics_ ->` | the same, where a type may also be the whole argument |
| operators, `(` `<` `{` `.` | 3 | `loption_generics_ ->` | the same, where a type may also be an operand |
| `<`             | 12 | `loption_generics_ ->` | against `<` as a declared operator |
| `(` `<`         | 3 | `loption_generics_ ->` | a named type opening a call or a generic list |
| `(` `<` `{` `.` | 3 | `loption_generics_ ->` | a named type opening a constructor body |
| `(`             | 3 | `list_verb_type_suffix_ ->` | a type opening a statement, against a call |
| `(`             | 6 | `app -> ... DOT LIDENT` | a type member ending a package-scope declaration, against a named constructor call |
| `(`             | 2 | `app -> func_callee` | a package-scope declaration's value, against a call |
| `?` `??`        | 4 | `expr -> SPAWN unbraced_verb_call`, `expr -> SPAWN braced_verb_call`, `func_callee -> unbraced_verb_call`, `app_braced -> braced_verb_call` | a spawned call against what follows it |
| `(`             | 1 | `expr -> SPAWN unbraced_verb_call`, `func_callee -> unbraced_verb_call` | *(reduce/reduce)* the same, before a call |

The `<` row is about the declaration form, not the comparison. Its twelve states
all reduce toward `ret_type "<" "(" params ")" body`, the declaration of the
`<` operator, against shifting `<` as the opening bracket of a generic argument
list: after a name type, `Foo<Int> …` and `Foo <(a Int) { }` open with the same
two tokens. Three of the twelve are the same fork after an abort type,
`Int?Foo<Int>` against `Int?Foo <(a Int) { }`. Dropping `<` and `>` from the
operators a declaration may name removes all twelve and nothing else, which is what identifies the family; it is a
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

**A value closed by a brace is not a postfix base.** The same question comes
back one step later. A statement closed by a `}` is followed by the next
statement, which may open with `(` or `[` — the two tokens a postfix opens
with. So if a `match`, a map literal, an `init` or a constructor call by
fields could take a call or a subscript, `abort match (x) { } (y)();` would
read both as one statement and as `abort match (x) { }` followed by `(y)();`,
and both would finish. That was
[#102](https://github.com/zane-lang/compiler/issues/102), five reduce/reduce
states on `(` and `[`, and it measured two derivations in every statement form.

So none of them is a postfix base: `primary_braced` and `braced_verb_call` are
reached from `expr` through `app_braced`, beside `block_call`, which was
already written that way for the same reason. The postfix forms take only
`primary` and `unbraced_verb_call`, and a value that closes on a `}` is
continued through parentheses — `(match (x) { })(y)`. That holds in every
position, not only at a statement's tail, which is what lets the grammar decide
it without knowing where the statement ends; lexical.md §6.3 requires it at the
tail and says nothing elsewhere, so the rest is recorded in
[`spec-divergences.md`](../spec-divergences.md).

Each witness now has one derivation, the five reduce/reduce states are gone,
and a postfix with nothing to open the next statement — `abort match (x) { }
(y);` — is a parse error. The two `?` `??` states of the spawned-call row
became four: the fork is the one it always was, now counted once per closing
bracket of the call.

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
[`tests/grammar/ambiguity_test.py`](../../tests/grammar/ambiguity_test.py) and
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

**Standalone type values are constructor arguments only.** Previously a bare
name also belonged to `expr`. That left `Foo<1>[]() {}` with two complete
parses: a lambda returning `Foo<1>[]`, and `(Foo < 1) > ([]() {})`. Restricting
collection calls alone did not close the family: `Foo<1>[][Int]() {}` could
subscript the collection before calling it.

The grammar now excludes bare type values from `expr` and admits them through
`constructor_value`, beside ordinary expressions. Both positional and named
constructor arguments use that rule; ordinary calls, collection elements,
operator operands and nested expressions do not. The constructor exception
applies to a whole argument, so `Ctor(Int)` is accepted and `Ctor(Int + 1)` is
rejected. Type annotations, generic arguments, type members and constructed
values retain their explicit grammar positions.

Both witnesses now have one complete derivation, including when nested in a
constructor argument. `tests/grammar/type_arguments_test.py` checks that the
exception does not leak into ordinary expressions. This closes the identified
type-value/comparison family, not every remaining proof obligation.

**Only bare names are supported as standalone constructor type arguments.**
That restriction predates the constructor-only rule. The previous `expr`
production was measured to add three reduce/reduce states when extended to
applied types, against `list_verb_type_suffix_ ->`. Those historical
measurements do not establish a limitation of the new constructor argument
rule. This change preserves the existing bare-name restriction;
[`spec-divergences.md`](../spec-divergences.md) records the remaining gap.

The state counts below describe the earlier census and must be regenerated
before being used as measurements of the constructor-only grammar.

Thirty states reduce `loption_generics_ ->`: 21 predate the terminator change,
and three came with the abort type's own position (below). The empty generics reduction is load-bearing rather
than an artifact: expanding the option into two explicit alternatives raises
the count, and dropping generics from named types raises it too, both by
trading shift/reduce states for reduce/reduce ones. What it stands in for is a
genuine overlap in the surface syntax — `x Foo(…)` is either a constructor
shorthand or a lambda declaration whose return type is `Foo`, and nothing
before the closing bracket says which.

## A type is never parenthesised

[`syntax.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/syntax.md)
§2.4 has no parenthesised type, and the grammar had one: `( type )` anywhere a
type goes. It was ambiguous. `p (Int) = Int(1);` in a body was both a
declaration of `p` at the type `(Int)` and an assignment to the call `p(Int)`,
which passes a type as a value. Measured with `--check-tokens` it had two
parses, and the parser stopped on it with no merge function to call.

The form also carried the one spelling of an abortable verb type,
`(Int ? Error)[Int]`, because `Int ? Error[Int]` read as a return of `Int`
aborting with the verb type `Error[Int]`. Both go together. §2.13 spells the
verb type `Int?Error[Int]`: the abort type stays attached to the return type
written before it. So an abort type is now a bare type atom, a name or `&` a
name, and never takes a verb suffix of its own. `type_expr -> abort_ret_type
verb_type_suffix+` is the verb type, and a verb's own `Int?Error` return is
`abort_ret_type` with nothing after it. The two part at the `[`.

The census moves by one state in the shipped automaton and by none in the stock
one, where the families shift:

- `primary -> LIDENT` and `primary -> THIS` at `(` are gone, all three states.
  That was the fork of a bare name before a `(` that could open a parenthesised
  type, and it is the one the witness above sat in.
- Three `loption_generics_ ->` states at `<` are added. They are the declared
  `<` operator's fork again, after an abort type rather than a return type,
  and belong to that family.
- The three `loption_generics_ ->` states whose lookahead held `)` keep their
  count and lose the `)`, since a type no longer closes on one.

The ambiguous sentence now has one parse, an abortable verb type written in
§2.13's spelling has one in a declaration and in a return position, and the
parenthesised spelling has none. Each is a case in
[`tests/grammar/ambiguity_test.py`](../../tests/grammar/ambiguity_test.py).

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
