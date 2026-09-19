# Compilation stages

The compiler runs in five stages:

1. **parsing** — produces the concrete syntax tree (CST).
2. **desugaring** — lowers the CST to the simplified syntax tree (SST).
3. **semantics** — resolves names and types, lowering the SST to the abstract
   syntax tree (AST).
4. **optimizations** — mutate the AST.
5. **codegen** — produces the binary.

The CST captures only what the source says: every shorthand the grammar admits
is a node of its own, and a form written two ways is two shapes in the tree.

The SST says the same thing one way. It is still untyped and still holds
unresolved names — what it no longer holds is a choice of spelling. The rewrites
that get there are inventoried in [`desugaring.md`](desugaring.md), along with
the ones that look like they belong and do not.

The line between stages 2 and 3 is what a rewrite needs to know. A desugaring
needs nothing but the syntax tree; anything that has to know what a name refers
to, what package a member came from, or what type an expression has is name
resolution or type checking, and belongs to semantics. That line is why control
flow is not desugared anywhere — `if` and `guard` are ordinary calls, not syntax
— and why a method call keeps its `:`/`!` marker through stage 2 even though
its subject has already become an argument.
