# Contributing

How changes to the compiler are written and what has to change with them.
[`docs/README.md`](docs/README.md) says where each part of the compiler is
designed; the [`justfile`](justfile) has the recipes that build and test it.

## Writing code

### Prefer modules with narrow edges

Split code into modules that each own one job and expose only what their
callers need. A change then stays inside the module it concerns: its blast
radius is that module and the few places that call it, not every file that
happened to reach into its internals. Modules that are not intertwined can
also be replaced, reordered or reused without untangling them first.

In practice:

- Give each module one responsibility, named by what it does, and keep its
  interface (`.mli`, or the functions it exports) small.
- Pass what a function needs as arguments rather than reaching into another
  module's state. `lib/cgt/`'s `lower_*.ml` modules take the walk they need
  as a parameter for this reason, so they stay outside its recursion.
- When two concerns start to share code, give the shared part a module of
  its own instead of letting one depend on the other's details.
- Keep data and the passes over it apart: a tree is defined once, and each
  pass that reads or rewrites it is its own module.

### Keep abstractions light

Abstractions are welcome when they make code easier to change: a helper
that names a repeated pattern, a type that keeps two kinds of value from
being mixed up, a function that hides a fiddly detail behind a clear name.

They should not cost the reader a tour of the codebase. A reader following
one piece of behaviour should find it in one or two places, not by jumping
through layers of indirection.

- Abstract a pattern once it is actually repeated, not in anticipation.
- Prefer one plain function over a hierarchy of wrappers, functors or
  configuration that each forward to the next.
- An abstraction should be understandable from its name and signature. If
  using it correctly requires reading its implementation, it is hiding the
  wrong thing.
- If removing a layer would make the code shorter and just as clear, remove
  it.

### Keep nesting shallow

No function nests more than five levels deep. A level is an enclosing
`match`, `function`/`fun`, `try`, `if`, `while` or `for`, counted on the
parsed tree rather than on indentation, so reformatting neither hides depth
nor adds it. An anonymous `fun x -> match x with` is one level, and an
`else if` chain is one however long it is. CI runs the check, and
`just check-nesting` runs it locally; [`tools/nesting/`](tools/nesting/) has
the full count.

The fix for a function past the limit is to name its inner steps as functions.
A function bound by `let`, at top level or locally, costs no level of its own,
by design: its body counts from where it is bound, so pulling an inline closure
out into a named `let` brings the code back under the limit without moving it
far from where it is used. For a chain of steps that each fail or continue,
`let*` over `Result` or `Option` keeps the chain flat. This is the light kind of
abstraction [Keep abstractions light](#keep-abstractions-light) asks for: a
name for a step, read in the same place, not a new layer.

### Match the code around it

Follow the naming, comment density and idiom of the module you are editing.
Comments say what a piece of code is and why it is that way, in present
tense; the history of how it got there belongs in the commit message.

## What changes with the code

A change carries its tests and its documentation in the same commit or pull
request.

- **Tests.** Behaviour a change adds or fixes has a test that would fail
  without it. `just test` runs the suites.
- **Design documents.** A change to how a stage works updates its document
  in [`docs/design/`](docs/design/), and a new departure from the spec is
  recorded in [`docs/spec-divergences.md`](docs/spec-divergences.md).
- **Optimizations.** Every optimization of the programs the compiler builds
  has an entry in [`docs/optimizations.md`](docs/optimizations.md). A change
  that adds one adds its entry, a change that alters one updates the entry
  (what it does, the builds that get it, where it lives, its measured
  effect), and a change that removes one deletes the entry. That file's
  opening section has the entry format and a blank entry to copy.
