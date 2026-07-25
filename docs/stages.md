# Compilation stages

The compiler runs in four stages:

1. **parsing** — produces the concrete syntax tree (CST).
2. **semantics** — lowers the CST to the abstract syntax tree (AST).
3. **optimizations** — mutate the AST.
4. **codegen** — produces the binary.

The CST captures only what the source says. Name resolution and desugaring
belong to the semantics stage, which is where the AST gets its meaning.
