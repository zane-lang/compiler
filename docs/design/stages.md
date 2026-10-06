# Compilation stages

The compiler runs in six stages:

```text
source
  ↓ parsing
CST
  ↓ desugaring
SST
  ↓ semantics
TST
  ↓ lowering
CGT
  ↓ optimization (optional)
CGT
  ↓ codegen
binary
```

1. **parsing** — lowers source text to the concrete syntax tree (CST).
2. **desugaring** — lowers the CST to the simplified syntax tree (SST).
3. **semantics** — resolves names, checks types, and lowers the SST to the typed
   syntax tree (TST).
4. **lowering** — lowers the TST to the code-generation tree (CGT).
5. **optimization** — rewrites the CGT into a faster CGT. Each pass maps a CGT
   to a CGT, and an unoptimized build runs no passes. Its one pass evaluates
   at compile time what the program would compute the same way every run
   ([`optimization.md`](optimization.md)).
6. **codegen** — lowers the CGT to LLVM IR and produces the binary. How
   lowering and codegen are designed is in [`lowering.md`](lowering.md).

The CST captures only what the source says: every shorthand the grammar admits
is a node of its own, and a form written two ways is two shapes in the tree.

The SST says the same thing one way. It is still untyped and still holds
unresolved names — what it no longer holds is a choice of spelling. The rewrites
that get there are inventoried in [`desugaring.md`](desugaring.md), along with
the ones that look like they belong and do not.

The TST represents the semantically checked program. Names are resolved and
expressions are typed, so later stages do not need to recover semantic
information from syntax. How it is built is in
[`semantics.md`](semantics.md). "TST" is used instead of the more common "typed AST"
because CST, SST, TST, and CGT name the role of each tree directly. Their names
describe what distinguishes each representation rather than accumulating every
property inherited from earlier stages: the TST remains simplified, and the CGT
remains typed, without encoding those inherited properties in their names.

The CGT is the one input codegen reads. It is a distinct representation from
the TST: lowering introduces backend-oriented forms, stronger invariants, and
explicit compiler-generated structure — block-taking verbs expanded at their
call sites, concepts resolved to primitives. Keeping that freedom out of the
TST lets the TST remain the language-facing representation of the typed program
while the CGT evolves around backend needs.

Lowering does everything codegen depends on; optimization only makes the result
faster. A pass preserves every invariant lowering establishes, so codegen
handles an optimized and an unoptimized CGT alike, and an unoptimized build is
the same pipeline with an empty pass list. Because the two builds share one
lowering and one codegen, a program that behaves differently with and without
optimization points to a bug in an optimization pass.

The line between stages 2 and 3 is what a rewrite needs to know. A desugaring
needs nothing but the syntax tree; anything that has to know what a name refers
to, what package a member came from, or what type an expression has is name
resolution or type checking, and belongs to semantics. That line is why control
flow is not desugared anywhere — `if` and `guard` are ordinary calls, not syntax
— and why a method call keeps its `:`/`!` marker through stage 2 even though
its subject has already become an argument.

Each stage's library under `lib/` is named after the tree it produces:
`lib/cst/`, `lib/sst/`, `lib/tst/` and `lib/cgt/`. Optimization and codegen
produce no tree of their own, so their libraries are named after the stage,
`lib/optimize/` and `lib/codegen/`.

Every stage reports a problem with the program as a diagnostic, a
`Diagnostic.t` that points at the source, a file or a directory, and `zanec`
exits with status 1 once it has printed them. Each stage also relies on what
the stages before it established. When one of those guarantees does not hold,
the fault is the compiler's, not the program's: the stage raises
`Diagnostic.bug`, and `zanec` prints `internal compiler error: …` with a
request to report it, and exits with status 3. Status 2 is a usage error.

The stages run in order through `lib/driver/`: one function per step
(assemble, check, lower, and emit an IR module, an object or an executable),
each a result whose failure is the step's diagnostics with the text they
point into. The rules about a build rather than a stage live there too: which
package a `--stamp` names, and whether the root needs a `main`. `zanec` and
the inspection tools parse their arguments, call the driver, and print.
