# `comptime`: calls evaluated at compile time on request

> **Status: built.** This page describes how the compiler implements a call
> marked `comptime`
> ([`effects.md`](https://github.com/zane-lang/spec/blob/bdb1070/spec/effects.md)
> §5.6, [`syntax.md`](https://github.com/zane-lang/spec/blob/88cc67f/spec/syntax.md)
> §4.10). Each decision is numbered (**K1**…). Where the compiler accepts less
> than the spec, [`spec-divergences.md`](../spec-divergences.md) §15 and §16
> record the difference.

Stage 5 ([`optimization.md`](optimization.md)) evaluates every expression
it can at compile time, within budgets, and only in an optimized build: an implicit
fold is optional, so it may give up. A call marked `comptime` is not
optional. Every build evaluates it, unoptimized and tiered builds included,
runs it to completion, and fails the build when it cannot. The marked call
may also read capability-backed state through capabilities that stand for
the build machine's, which no implicit fold may do.

```zane
notes String = comptime readNotes(files, "notes.txt");
```

---

## 1. What is checked

**K1. The checker decides what the tree shows.** `Check.comptime` types the
marked call as an ordinary call and `Comptime_check`
(`lib/tst/check/comptime_check.ml`) holds it to these rules:

| Rule | Spec |
|---|---|
| The marked call is a function call, a `:` method call, a constructor call, or a call through a function value; never a `!` call, and never a call to a verb that declares a `@concepts$Block` parameter | §5.6, syntax.md §4.10 |
| Its result type is a value type (`Type_decls.is_value`), so no reference, capability or handle crosses into the program | §5.6 |
| It names no local of the verb it is in, a foreign variable aside (K2) | §5.6, narrowed: divergence §15 |
| No call in its arguments, other than another marked call, is given a value that reaches a capability, through fields or elements at any depth, since such a call could read capability-backed state outside a marked call; a lambda in the arguments is held to the same rule unless it is given to the marked call itself, in which it runs | §5.6, conservatively |
| Nothing in it, handlers included, leaves the verb it is in: no `abort`, and no `return` but a match arm's | §5.6: "the whole expression is one constant" |

A marked call is an expression (`Tst.Nodes.Expr.Comptime`). Written as a
statement, it is the same expression with its value dropped: it is still
evaluated, so a call that cannot be is still an error. The grammar takes
`comptime` before a whole call, as it takes `spawn`, so a trailing block
argument, and with it a verb that takes a block, cannot follow it; a block
written inside the parentheses is refused by the checker.

**K2. "Computable at compile time" is "names no local".** The spec lets an
argument depend on any computation §5.3 permits to be evaluated at compile
time, a local of the verb bound to a literal among them. The compiler
evaluates a marked call in every build, and an unoptimized build has no
fold that tracks the value a local holds at a given point, so it accepts only what
can be evaluated without one: literals, package constants, foreign
variables, the program's console and runtime, and calls, marked or not, on
those. A local bound inside the marked expression is its own: a lambda's
parameter, a handler's binder, a match arm's binder, and a local a block in
it declares. A foreign variable declared in the body is the one local accepted:
its value is its C global, fixed where it is declared, since a foreign
capability has no setter.

---

## 2. Lowering

**K3. A marked call is lifted into a lambda of no parameters.**
`Lower_comptime` (`lib/cgt/lower_comptime.ml`) makes, for each marked
expression, a TST lambda whose body returns it, handler included, and
lowers the marked expression as a call of that lambda. Lowering lifts the
lambda as it lifts any (L14): a function of its own, named among the
lambdas of the verb it is written in (`Program.name_lambdas`), so each
instance of a generic verb lifts its own. A marked call in a field's
default is named after its constructor's instance and the field's slot
(`…$defaultN$lambdaM`), and lowered where a call leaves the field out. Because the marked expression
names no local (K2), the lifted body needs nothing from the verb. A foreign
variable it names is declared again at the top of the lambda's body, with
the same C global. The lambda is never given a C entry, since C never calls
it, and a verb holding a marked call is not written out where it is called
(L11), so each marked expression is lifted once.

Each lifted function is listed in the program's `comptime`
(`Cgt.Nodes.Program`), with the span of the marked call. At its site the
call is an ordinary call through a function value, `Call_value` of
`Function` with no arguments, so every rule lowering applies to a call's
result, where it arrives and which arena holds it, applies to it unchanged.

---

## 3. Evaluation

**K4. Every build evaluates marked calls, between lowering and stage 5.**
`Optimize.comptime` (`lib/optimize/comptime.ml`) runs in the driver right
after lowering, in an unoptimized build, an optimized build, a library's
object and both tiers of a tiered build. It runs each lifted function with
stage 5's evaluator (`Eval`), in the order lowering reached them, then
writes the value each gave, as code (O7), in place of every call of it, and
drops the lifted functions. Codegen never sees one: a `comptime` list that
reaches it is a compiler bug. A build that holds a marked call makes the
program's C before evaluating it, as an optimized build does for stage 5,
so a marked call can run C whose body is in the build (F16).

**K5. A marked call's run takes no budget.** A run marked explicit
(`Eval.explicit`) runs to completion: it takes nothing from the step
budget of one fold or the total of all folds, no call depth ends it, in
Zane or in C (`C_eval.hooks.bounded`), no cap bounds what it outputs or
the size of the value it gives, and stage 5,
which runs afterwards with budgets of its own, starts with them full.
A marked call that does not terminate is a build that does not terminate,
as §5.6 says. The one limit left is the compiler's own stack: calls nested
deeper than it holds are a compile-time error.

**K6. What a run may read.** Inside a marked call, a capability stands for
its counterpart where the build runs:

| Read | At compile time |
|---|---|
| The runtime's `arguments` | The arguments the build was started with: each `--build-argument ARGUMENT` given to `zanec`, in order, which `zane` passes on (zane's [`docs/design/cli.md`](https://github.com/zane-lang/zane/blob/main/docs/design/cli.md)). When a marked call reads them, `--object OUT` writes an empty `STEM.arguments` beside the object (below) |
| A method without `mut` on a foreign capability | Its C, run by the C evaluator against the build's own C memory, where the capability's C global holds its first value, as each run's C memory starts (F16) |
| An approximate `@math$` function | The build machine's C math library, through OCaml's, in double precision and rounded once for an `F32` |

An object built from code whose marked calls read the arguments depends on
them, while any other object is the same whatever arguments the build was
given. So `--object OUT` marks a dependent object: when any marked call of the
build read the runtime's `arguments`, `zanec` writes an empty file
`STEM.arguments` beside the object, `STEM` being `OUT` without its
extension, and when none did, it removes such a file an earlier build left
there ([`separate-compilation.md`](separate-compilation.md) C3). The marker
records the read, not the values: `zane` keys its cache of a marked object
on the arguments it passed, and of an unmarked object on nothing else.
Only the root package reaches `@program$runtime`, so a library's build,
given `--no-root`, never writes the marker.
`Eval.explicit`'s `read_arguments` records the read, and `Comptime.run`
returns it beside the program.

A package constant the run reads is made in the run, as the program makes
one the first time it is read (L16), whether or not stage 5 could fold it.
A worker pool and a worker's timer (O3) are not run: a marked call that
reaches one is a compile-time error (divergence §16).

**K7. A write is an error when it is made.** A print, a change to the
runtime's threads, or a call to a `mut` method on a foreign capability
(`Cgt.Nodes.Foreign.writes`), made anywhere in the run, raises
`Eval.Writes`, which becomes a compile-time error naming the call. That
includes a write a package constant's maker makes when the run makes it,
and one an argument's computation makes, which §5.6 would replay at run
time (divergence §16).

**K8. A remembered call is remembered only when it read nothing.** A run
reuses calls stage 5's memo table holds (O6), and records a call in it
only when the call made no read of capability-backed state and made no
package constant: another call with the same arguments gives the same
value only then. A remembered call that output anything is a write, and an
error, inside a marked call.

**K9. A run that cannot finish names its call.** An index out of range, a
call into C whose body is not in the build, a function value with no body,
a write (K7): each is reported at the marked call, with what the run
reached, and every marked call of the build is tried, so one build reports
them all. A value that holds an address is refused too, which a value type
(K1) never does.

---

## 4. How it is tested

- `tests/codegen/fixtures/comptimeCalls` holds a result of each kind (a
  scalar, a struct, a variant's case, a string, a list), package constants
  made by marked calls, one reading another, a marked call in another's
  arguments, a method call on a constant, calls through function values,
  both handler forms, the build's arguments, and a loop of several times
  the steps one implicit fold may take, a handled `match` in the
  arguments, a field's default, and a lambda that reads given to the
  marked call. Its `.cgt` golden is the
  unoptimized tree, which shows every value built in and no lifted function
  left, and its `.out` golden holds every build of it to one output.
- `tests/codegen/fixtures/reject/comptimeRefused` holds three calls that
  cannot be evaluated, each reported: a print, an index out of range, and a
  handler that prints.
- `tests/ffi/fixtures/comptimeC` runs a pure C function, C whose calls nest
  deeper than an implicit fold's limit, and a read through a foreign
  capability at compile time in an unoptimized build.
- `tests/semantics/fixtures/typing/reject/bad/comptime.zn` holds each rule of
  K1.

---

## 5. Open questions

- **Writes found statically.** The spec derives whether a call writes
  capability-backed state from its body (§5.2), so a write the run never
  reaches would be an error too. Finding writes when they are made (K7)
  needs no effect analysis the compiler does not have yet.
- **Callees left behind.** A function only a lifted function called stays
  in the program after the lifted function is dropped. An optimized build
  leaves it to LLVM; an unoptimized build emits it.
- **Reads that change between builds.** Every read K6 lists gives the same
  value to both tiers of a tiered build, which are two processes given the
  same arguments. A read of the clock, or of a file, would not, and tier 1
  would have to take tier 0's values.
