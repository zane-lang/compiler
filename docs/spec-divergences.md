# Where the compiler differs from the spec

The [spec](https://github.com/zane-lang/spec) is authoritative for anything not
listed here. This file records the places the compiler deliberately departs
from the spec, or settles a question the spec leaves open, so a contributor
reading a spec section and then the compiler knows which of the two is
currently ahead.

The syntax is still experimental, so divergences are expected to appear and
close. The intent is to reconcile in the spec's direction once the surface
settles, in one pass rather than section by section. Until then:

- **When a change here creates or closes a divergence, update this file in the
  same pull request.** An entry that survives the behaviour it describes is
  worse than no entry, because it is read as current.
- Each entry cites the spec section it departs from and states both rules, so
  the claim can be rechecked rather than taken on trust.

A choice the spec leaves open is recorded here when a running program can
observe it. The rest sit beside the design they belong
to: what the type checker determines is in
[`design/semantics.md`](design/semantics.md) §9, with D12 and D14, and how
lowering and the runtime place and represent values is in
[`design/lowering.md`](design/lowering.md) §9.

Each entry's links point at the spec commit the entry was last checked
against, so a later spec edit cannot silently make a quotation here differ
from the text it links to. Re-pin them when the entries are rechecked. Where a claim is
about what the parser accepts, it was measured with
`ambiguity search --check-tokens`, which reports how many parses a token
sequence has: `0` is a syntax error, `1` is accepted.

Three entries closed at the `034f11a` re-pin, when the spec moved to `;`-terminated
statements and a brace that ends one. The widest divergence — the
spec separating statements by newline where the compiler terminated them — is
gone, and with it the same-line rule for a trailing block and the disagreement
over what may follow one. The **Closed** section at the end records those and
everything else that has closed since; an entry that simply vanishes reads as
an oversight.

---

## 8. A write through a reference is judged by type

**Spec** — [`concurrency.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/concurrency.md#43-single-writer-per-storage-location)
§4.3: a spawn is lent every owner passed to it, and until its block drains
the spawning scope "**MUST NOT** write a lent owner". "A write reached through
a reference is a write of the owner the reference names."

**Compiler** — where it can follow a reference to the owner it names, it
applies that rule as written. Where it cannot, it judges the write by type: a
write through a reference whose type may hold a lent owner counts as a write
of that owner, so some programs that would not race are rejected.

```zane
view &Dial = dial;
seen Int = spawn glance(view);   // lent `dial`, through `view`
other &Dial = spare;
@controlflow$branch(flag, {
	other = view;
});
other.reading!nudge();           // rejected, even when `flag` is false
```

`lib/tst/analyses/spawns.ml` checks it, and
`tests/semantics/fixtures/typing/reject/bad/spawns.zn` has the cases.
Reconciling means following a reference to its owner in more of the cases
where the type alone settles it today.

---

## 9. A case is not a type

**Spec** — [`adt.md`](https://github.com/zane-lang/spec/blob/7fa876f/spec/adt.md)
§3: "A member projected as a type is written `Expr.intLit`", and §5.2: "if the
scrutinee's static type is already a single case (`Expr.strLit`), that arm is
chosen statically with no jump."

**Compiler** — `Type.case` names a case only where a value is built or read:
`Expr.intLit("5")` builds one, `e.intLit ? x { … }` reads one, and a `match`
arm selects one. It is not a type, so no parameter, field or local can be
declared at one, and every `match` dispatches on the live tag.

```zane
e Expr = Expr.intLit(text);          // accepted
String f(x Expr.intLit) => …;       // rejected: a syntax error
```

Nothing is lost that the compiler could otherwise rely on: a value of a
projected case type would still be the whole variant (§3.2), and the
narrowing it enables is an optimization the tag jump already gives. Reconciling
means adding the type form and its narrowing, or the spec dropping it.

---

## 11. A wait holds its pool thread when the pool has none to spare

**Spec** — [`concurrency.md`](https://github.com/zane-lang/spec/blob/88cc67f/spec/concurrency.md)
§3.4: "A waiting call holds back only its caller [...]. Every other spawned
call, and every worker of every worker pool (§6), keeps running while the
wait lasts."

**Compiler** — while a pool thread waits for a call running elsewhere, or
waits in a `register` for its timer, the pool runs a stand-in thread in its
place. Once the wait is over, the stand-in thread exits the next time it
finds no work. The pool keeps at most
4095 threads, one fewer than it has deques, so a wait past that holds its
thread, and queued work waits for one. A pool thread that waits for a
package constant another thread is making has no stand-in, and neither has
one that blocks in a call into C, where the spec is silent.
`runtime/spawn.c` (`zane_block_begin`) is the decision.

Only a program with that many waits at once, or with waits on constants or
in C that depend on queued work, observes the difference.

Reconciling means waits that hold no thread: a waiting call suspended off
its thread and resumed when what it waits for is ready.

---

## 12. A read of a pool's state or elements waits for a writer

**Spec** — [`concurrency.md`](https://github.com/zane-lang/spec/blob/bdb1070/spec/concurrency.md)
§4.4: a read of a value another live spawn is mutating "observes a coherent
snapshot of the value rather than blocking", so "a real-time reader never
waits on a writer"; §6.2 and §6.6 take a pool's state and each element by
coherent snapshot.

**Compiler** — the funnel applies an event while it holds the pool's state
lock, and a step's snapshot and `state` copy the state under the same lock,
so a reader waits for at most the one event being applied. `elements`
copies each element while it holds that element's lock, which its step
holds while it runs, so the read waits for a running step of that element.
Each copy is coherent, as §6.6 requires. `runtime/workers.c`
(`zane_run_step`, `zane_workers_state`, `zane_workers_elements`) is the
decision.

Reconciling means reads validated and retried against the funnel's writes,
as `zane_snapshot` does for a spawned call's write-back, including the
bounded walk §4.4 gives a value that owns boxed members.

---

## 15. A `comptime` call is given no local of its verb

**Spec** — [`effects.md`](https://github.com/zane-lang/spec/blob/bdb1070/spec/effects.md)
§5.6: "An argument qualifies when everything it depends on is a literal, a
constant, the result of another marked call, or a computation §5.3 permits
to be evaluated at compile time", and §5.3 permits any computation that
depends on no parameter and no read of capability-backed state, so a local
bound to a literal qualifies.

**Compiler** — the marked call, handler included, names no local of the
verb it is in, except a foreign variable, which is fixed where it is
declared. `x Int(3); y Int = comptime f(x);` is refused; `comptime f(Int(3))`
and `comptime f(limit)`, for a package constant `limit`, are accepted. A
call in an argument that is given a value reaching a capability is refused
too, other than another marked call, since it may read. Both are checked
from the tree, because a marked call is evaluated in every build and an
unoptimized build has no fold to say what a local holds.
[`design/comptime.md`](design/comptime.md) K1, K2 are the decision, and
`tests/semantics/fixtures/typing/reject/bad/comptime.zn` the cases.

Reconciling means evaluating a marked call against what the verb has
computed before it, in every build.

---

## 16. A `comptime` call's writes are refused when they are made

**Spec** — [`effects.md`](https://github.com/zane-lang/spec/blob/bdb1070/spec/effects.md)
§5.6: "A marked call **MUST NOT** write capability-backed state", whether a
call writes being derived from its body (§5.2); a write an argument's
computation makes "still happens at run time, as in §5.3".
[`concurrency.md`](https://github.com/zane-lang/spec/blob/bdb1070/spec/concurrency.md)
§6.5: "A pool created inside a `comptime` call runs at compile time with
that call".

**Compiler** — a write is refused when the evaluation reaches it: a marked
call whose body could write, on a path this build does not take, is
accepted. A write made while the arguments are computed is refused too,
rather than replayed at run time. A marked call that reaches a worker pool
or a worker's timer is refused, since the evaluator runs neither.
[`design/comptime.md`](design/comptime.md) K6, K7 are the decision, and
`tests/codegen/fixtures/reject/comptimeRefused` the cases.

Reconciling requires an effect analysis that finds a write in the body, the
arguments evaluated apart from the call, and pools run by the evaluator.

---

## Closed

Kept briefly so a reader who remembers them can see they were closed on
purpose, and by what. The first three closed at the `034f11a` re-pin, when the
spec moved to `;`-terminated statements and a brace that ends one. The next
closed from the other side, when the compiler adopted a spec rule it had been
standing in for, the next when the compiler followed the spec in removing a
form, the next when the spec's memory model made the compiler's departure
unnecessary, the next when the spec settled a question the compiler had
answered differently, the next when the spec dropped a form the compiler
never had, the next two when the spec gave a package-scope declaration the
terminator a statement takes, the next when the spec stated what may
continue a value that closes on a brace, the next, which was §3, when
the compiler widened a form it had limited to constructors to every call,
the next, most of §11, when the spec dropped parking and the runtime
gave a waiting pool thread a stand-in, and the last eleven when the spec
adopted rules the compiler had settled first: spec PR
[#298](https://github.com/zane-lang/spec/pull/298) carried nine of them,
the spec had already settled the out-of-range entry, and the build's
arguments turned out to belong to `zane`'s documentation.

- **Statements are terminated, not separated.** The spec separated statements
  by newline and called it "the one place a newline is structural"; the
  compiler has always terminated them with `;` and given newlines no meaning.
  Spec [#181](https://github.com/zane-lang/spec/pull/181) adopted the
  terminator — "a `;` **terminates** every statement in a code block" — and
  with it "**`Newlines are never structural`**". The compiler's rule is now the
  spec's. What the compiler had to generalize was the other half of the new
  rule.

  A statement that ends in a `}` takes no terminator. The compiler already
  behaved that way for the statements whose *form* made it look obvious — a
  block-bodied verb, any mould, a call closed by a trailing block — each of
  which reached `stat` by a production with no terminator in it. Reading the
  rule off the form made that wrong for one of them: the peer mould's
  contents are a flat list, so it closes on a `]` and never had a brace to end
  it. It took no terminator anyway, and taking one was a syntax error. This
  pull request narrowed the no-terminator productions to the brace moulds and
  routed the peer mould through the ordinary terminated path.

  The compiler lacked the rule stated over a statement's
  **tail** rather than its form, which is the rule that reaches a variable bound to a
  `match`, an assignment, a `return`, and a `=> expr` verb whose expression
  ends in a brace. The grammar now determines whether a statement takes a `;`;
  only a stray `;` after its closing brace, and a trailing argument's `}` with
  more code after it, are checked after the parse.

- **A trailing block is placed by position, not by line.** The spec required a
  trailing block's `{` to open on the same line as its call, to tell it from a
  statement block on the next line. Spec #181 removed the rule along with the
  statement block itself: a `{ }` may no longer open a statement
  ([`lexical.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/lexical.md)
  §6.3.1), so nothing is left for the line to disambiguate. The compiler never
  had a statement block and never read a newline, so it already behaved this
  way; `Unit use() { { work(); } }` is rejected, and the scoped form is
  `do() { work(); }`.

- **A call statement closed by a trailing block takes no handler.** The spec
  gave `expr ? binder { ... }` for any abortable operation, which read as
  permitting a handler after a trailing block. Spec #181 settled it the other
  way: "A trailing argument **MUST** be the last thing in its statement [...] <!-- prose-lint: ignore placeholder-noun -->
  neither a `;` nor anything that would continue the call may come after it."
  The compiler now enforces exactly that, for a handler and for a further call
  or subscript alike, and an abortable call that needs a handler writes its
  block inside the argument list:

  ```zane
  done Unit = retry(count, { attempt(); }) ? e {
      resolve Unit();
  }
  ```

- **`and` and `or` were keywords here.** The spec's
  [`operators.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/operators.md)
  §2.4 has no `and` or `or`: `Bool` draws from the same fixed operator set as
  every other type, where `*` is conjunction and `+` is disjunction, and a
  deferred right operand is an overload taking one rather than a token that
  implies it. The compiler kept them as keywords producing a `Logic` node,
  because dropping them would have left nothing to write in their place —
  `a * b` binds too tightly to join two comparisons, so every such line would
  have needed parentheses the spec does not write.

  §3.1's loose tier is what the spec puts there instead, and adding it removed
  the reason to keep them. `a '* b '+ c` groups exactly as `a and b or c` did,
  so the rewrite is one-for-one and the grouping is unchanged:

  ```zane
  settled Bool = Float(0) < middle '* middle < Float(100) '+ answer == Float(42);
  ```

  The `Logic` node and `Logic_op` went with the keywords, since a loose
  operator is an ordinary `Op` carrying the same `Operator.t` as the operator
  it mirrors. `and` and `or` are ordinary lowercase names again, reserved by
  nothing.

  The spec later retired the loose tier and brought `and` and `or` back
  ([`operators.md`](https://github.com/zane-lang/spec/blob/6e232ce/spec/operators.md) §2.4) as reserved operator words,
  not keywords: intersection and union, overloadable like `+`, with both
  operands evaluated. The compiler followed, and they are again two levels
  below the comparisons, now carried by `Op` like every other operator.

- **The compiler had a pipe, `callable|value`.** The spec fixed only its
  grouping, at level 2 of the precedence table, and never defined its behaviour.
  Spec [#190](https://github.com/zane-lang/spec/pull/190) removed it, and the
  compiler followed: `|` is not a token, so `show|Color.red` stops at the
  lexer, and the call is written `show(Color.red)`. The `Pipe` and
  `MethodTarget` nodes went with it, since a method target was only ever a
  pipe's callee.

- **The console's `print` took a reference.** The spec declares
  `print(this @runtime$Console, text @primitives$String)`, and while
  `@primitives$String` was a reference type a plain parameter of it consumed
  its argument, which would have spent the caller's string and left `core`'s
  `String` no way to pass the view it holds in a field. The compiler took
  `text &@primitives$String` instead. Spec
  [#209](https://github.com/zane-lang/spec/pull/209) made
  `@primitives$String` a value type, whose parameter is a read-only borrow,
  and [#212](https://github.com/zane-lang/spec/pull/212) made a bare
  reference-type parameter a borrow too, so the spec's own signature reads the
  text without taking it. The compiler now declares `print` exactly as the
  spec does, and a string built in the argument is passed as it is.

- **An integer division by zero stopped the program.** The spec was silent
  about it, and the compiler stopped with status 1 after writing `division by
  zero` to stderr. Spec [#222](https://github.com/zane-lang/spec/pull/222)
  gives it a result, zero (`operators.md` §2.6), and makes `truncate` total
  too: it saturates a float its target
  cannot hold and gives zero for a NaN (`types.md` §2.9). The compiler follows, and the runtime functions that stopped the
  program at either are gone; `tests/codegen/fixtures/scalars` checks both.

- **A block yielded a value.** The spec typed a block `@concepts$Block<T>`
  when it yielded a `T`, ending each yielding path with `resolve`, and used
  one for a condition computed only when reached:
  `ran!elif({ resolve expensiveCheck() }) { … }`. The compiler never accepted
  a type argument on `@concepts$Block`, since no `@controlflow$` intrinsic
  hands a block's value back to the verb that received it. Spec
  [#225](https://github.com/zane-lang/spec/pull/225) dropped the form: a
  block yields nothing, `resolve` in one finishes the handler around the call
  and is an error with no handler, and a condition that must run only when
  reached is nested in the chain's `else` (`control-flow.md` §2.4 and §3.3).
  That is the compiler's rule, and the rejection in
  `tests/semantics/fixtures/typing/reject/bad/exits.zn` now cites the spec.

- **A declaration inside a body was terminated like the statement it is.**
  The spec stated that a package-scope declaration "is not a statement and takes no
  terminator of its own"; the compiler followed that rule at package scope and applied the
  statement rule inside a body, so moving a declaration between the two levels
  changed how it was spelled. Spec
  [`lexical.md`](https://github.com/zane-lang/spec/blob/482bf99d4db1fa34c48042357e0baabc75126830/spec/lexical.md)
  §6.3 now gives package scope the statement rule: a declaration ends with a
  `;`, unless it ends in a `}`. The compiler follows at both levels, with
  `top_decl` taking the declaration forms of `stat`, and a declaration is
  spelled the same wherever it stands. Five conflict states in each automaton
  went with it ([`ambiguity/proof-obligations.md`](ambiguity/proof-obligations.md)).

- **`package` and `import` were terminated.** The spec wrote them bare, and
  the compiler required a `;` after them, because `import core$` followed by
  `main Unit() { }` parses two ways without one. The same §6.3 terminates them
  with every other declaration that does not end in a brace, so the
  compiler's `;` is now the spec's rule.

- **A value closed by a brace took no postfix.** The spec stated only that
  nothing continues a statement past the brace that ends it, and the compiler
  held a `match`, a map literal, an `init` and a constructor call by fields to
  that in every position: none took a call, a subscript, a field access or a
  method call, so `Vector2{x = 0; y = 0;}.x` was a syntax error. Spec
  [`syntax.md`](https://github.com/zane-lang/spec/blob/8ed220ca1ce5dd18cdd277006f79eb8e2e93f94d/spec/syntax.md)
  §4.9 now states the rule by token: a `.`, `:` or `!` opens no statement and
  continues the value directly, except a map literal's, which a statement
  would otherwise open with; a `(` or `[` can open one, so a call or subscript
  is written on the parenthesized value. The compiler follows, with no new
  conflict state ([`ambiguity/proof-obligations.md`](ambiguity/proof-obligations.md)).

- **A type was passed only to a constructor.** The spec lets any verb declare
  a `T Type` parameter and receive a type "positionally in `()`, like any other
  value"
  ([`generics.md`](https://github.com/zane-lang/spec/blob/034f11a/spec/generics.md)
  §5.3). The compiler took a type only as a whole positional argument of a
  constructor call. A type as an operand has to stay out: there
  `x Result = Foo<1>[]() {}` is both a lambda returning `Foo<1>[]` and
  `(Foo < 1) > ([]() {})`. A whole argument is never an operand, since the
  `,`, `)` or `;` after it ends it, so the line at constructors was a choice,
  not a grammar requirement. The compiler now takes a type as a whole
  positional argument of every call, a function's and a method's included:
  `emptyOf(Pair<Int>)`, `registry!add(Int)`, `port:tallied(&Port)`. As there,
  the token after the type settles the choice between the argument and a
  lambda it begins ([`ambiguity/experiments.md`](ambiguity/experiments.md#a-type-in-every-call)).
  A named argument takes no type, as the spec's "positionally" says: it fills
  a field constructor's entry, which is one of the type's fields, and `Type`
  is a concept, never storage.

- **A spawned worker's wait no longer holds back the pool.** The spec had a
  stalling call made with `spawn`, or in a worker pool's step, "parked by the
  runtime so it does not consume a worker thread while waiting", and never
  listed the calls that stall. The compiler parked nothing: `workEvery` slept on
  the thread that ran it, so a pool of `n` threads ran at most `n` waiting
  workers. Spec [#292](https://github.com/zane-lang/spec/pull/292) dropped
  parking for "A waiting call holds back only its caller"
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/88cc67f/spec/concurrency.md)
  §3.4) and replaced `workEvery` with `register`. The runtime now gives a
  pool thread a stand-in while it waits in a join or a `register`, so the
  pool keeps its threads for the work that does not wait. What remains is
  §11.

- **A `match` arm whose body was a block took no `;`.** The spec terminated
  every arm, the same as every entry of a `{ }` body. It now ends a
  block-bodied arm at its brace, as a statement ending in `}` is ended, and
  keeps the `;` on an `=> expr` arm
  ([`lexical.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/lexical.md#61--terminates-an-entry-inside--) §6.1).

- **A constructor call with nothing else to pass did not trail.** The spec
  let every call trail its last `{ }` argument, which collided with the
  lambda literal `TypeName() { body }`. It now keeps a constructor call's
  only block argument inside the `( )`, as the compiler did
  ([`syntax.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/syntax.md#48-block-arguments-and-trailing-arguments) §4.8).

- **A `match` parenthesized its scrutinee list.** The spec wrote the list
  bare, which has two parses before a binary operator. It now writes
  `match (e) { … }` and `match (a, b) { … }`, on the reasoning that the `( )`
  delimits the list and forms no tuple
  ([`syntax.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/syntax.md#47-match-expressions) §4.7,
  [`adt.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/adt.md#56-matching-several-scrutinees) §5.6).

- **A `'` separated groups of digits.** The spec's numeric literals had no
  separator. It now takes `'` between two digits before the `.`, for the
  reason the compiler had: `,` and `.` swap roles between American and
  German notation, and the Swiss `'` means only grouping
  ([`lexical.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/lexical.md#7-literals) §7). `parseI64` and `parseF64`
  still read digits without it.

- **An exit ended the run of a block.** The spec had an exit end the
  invocation that called the exiting verb, which therefore had to return
  `Unit`. It now ends the run of the innermost block the call is written in,
  and a call to an exiting verb is legal only in a block, since a body ends in
  the `return` its verb needs
  ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/control-flow.md#23-a-block-is-transparent-to-return-and-abort-and-an-exit-ends-its-run)
  §2.3, §3.6, §4.2).

- **A spawned call's handler ran where the call settled.** The spec left the
  time and place open. It now settles the call once, on the spawning thread, at
  the first read of its symbol or where its block ends, and a block left early
  runs no handler
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/concurrency.md#33-abortable-spawned-calls-are-handled-at-the-spawn-site) §3.3).

- **A block did not write an owner it lent a running spawn.** The spec was
  silent on the spawning block's own writes. It now lends a spawn every
  owner passed to it and bars the spawning scope from writing one until the
  block drains (§4.3, linked from §8). What remains is §8: where the compiler
  cannot follow a reference, it judges the write by type.

- **An index out of range stopped the program.** The spec had left the
  outcome open. It now stops the program for a position or a range outside its
  sequence ([`control-flow.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/control-flow.md#52-a-position-outside-its-sequence-stops-the-program)
  §5.2), with a status other than `0`
  ([`packages.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/packages.md#63-a-program-ends-with-an-exit-status) §6.3),
  which the compiler's status 1 is.

- **A publish function called outside its pool's work stopped the program.**
  The spec left that case open. It now has a publish function publish to the pool of
  its event type whose work is running the call, and stop the program where
  none is
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/concurrency.md#65-the-funnel-is-the-one-writer-of-the-shared-state) §6.5).

- **Missed timer ticks merged.** The spec left open what a step slower than
  its interval sees. A timer is now ready at most once per call of its step,
  with its next deadline the first deadline on its schedule after the call
  ([`concurrency.md`](https://github.com/zane-lang/spec/blob/b158a77b47b03590543750f08ea46d8b04559197/spec/concurrency.md#63-when-a-step-runs) §6.3).

- **The build's arguments came from `--build-argument`.** The spec's
  `arguments` inside a `comptime` call gives "the arguments the build was
  started with", and how a build is started belongs to the tool that starts
  it. `zane`'s own
  [`docs/design/cli.md`](https://github.com/zane-lang/zane/blob/main/docs/design/cli.md)
  documents `--build-argument`, which it passes on to `zanec`.
