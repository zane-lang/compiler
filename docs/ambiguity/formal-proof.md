# Formally checked unambiguity

`formal/` is a Lean 4 development whose theorems state that Zane's grammar is
unambiguous. They start from the text of `lib/cst/parser.mly`, and every step
from that text to the final finite invariant is either a definition or carries
a proof that Lean's kernel has checked. The construction it formalizes is the
one [visible-proof.md](visible-proof.md) explains; the
[verification roadmap](verification-roadmap.md) lists the obligations it
discharges.

## The theorems

Both theorems count syntactic derivations, with semantic actions erased.

**The source relation.** `SourceUnambiguous text` (`Ambiguity/Source.lean`)
says that the parse relation `text` defines assigns at most one derivation to
every token string. That relation is the set of trees accepted by the canonical
LR(1) automaton of the expanded grammar, with conflicts resolved by the
precedence declarations as Menhir's manual specifies (§6.3); a severe conflict
keeps all of its actions. Both halves are definitions in Lean:

- `Mly.sourceGrammar` (`Ambiguity/Mly.lean`) reads the file: tokens,
  precedence levels, parameterized rules, `%inline` with `%prec`
  propagation, and the standard library's `option`, `list`,
  `separated_nonempty_list` and the other rules a grammar can use.
- `Lr1.canonical` (`Ambiguity/Lr1.lean`) builds the automaton and resolves its
  conflicts.

`verifySource_sound` proves `SourceUnambiguous text` from a `true` answer of
the executable check `verifySource text ev`.

**The shipped parser.** The compiler parses with Menhir's `--GLR` backend,
whose automaton `G` belongs to a grammar in which nullable symbols are split
into an empty and a nonempty part. `GlrSound text G` (`Ambiguity/Glr.lean`)
says two things:

- the trees `G` accepts are determined by their yields;
- a function `rho` reads each accepted tree as a derivation of the expanded
  source grammar of `text`, rooted at its start symbol, with the same tokens,
  and distinct accepted trees give derivations of distinct token strings.

`verifyGlr_sound` proves it from a `true` answer of `verifyGlr text G ev`, which
checks `G` and a correspondence between each of its productions and a source
production.

Both theorems depend only on Lean's three standard axioms (`propext`,
`Classical.choice`, `Quot.sound`).

## How a check is structured

The checks follow the same pipeline as the Python tools:

1. LR context extraction.
2. Quotienting.
3. Generic-angle tagging.
4. Lookahead-guard elimination.
5. Counted horizontal compilation and the final visible-stack fixed point.

An unverified producer computes the evidence for every stage: quotient maps,
angle sets, determinization vectors, minimization maps, witnesses and the
certificate. The verified checks accept or reject that evidence. No producer
needs to be correct for a `true` answer to mean what its theorem says.

## Run it

```sh
just verify-grammar
```

The recipe needs Lean (installed with elan, at the version
`formal/lean-toolchain` names) and Menhir. It builds the checker, dumps the GLR
automaton from the current `parser.mly`, then runs both proofs:

```text
zane-ambiguity-check prove-source lib/cst/parser.mly
zane-ambiguity-check prove-glr lib/cst/parser.mly <dir>/parser.automaton
```

Each prints `VERIFIED` and exits 0, or prints `REJECTED` and exits nonzero. The
two take about 3½ and 6 minutes. The `Grammar verification` workflow runs the
recipe on every change to the grammar, `formal/`, or the recipe.

## What remains assumed

- **Lean.** The kernel checks the theorems. The `true` answers come from the
  compiled checker, so Lean's code generator is trusted to run the definitions
  it compiles. This is the same trust as `native_decide`.
- **The definitions are the intended ones.** `Mly.sourceGrammar` and
  `Lr1.canonical` define what the file means. Two development commands
  cross-check them against Menhir 20260209:
  - `expand`, against `menhir --only-preprocess-uu`: the same 481 productions.
  - `compare`, against `menhir --canonical --dump`: 4,328 states, with the
    same transitions and the same retained reductions.
- **The shipped parser runs its dump.** `GlrSound` is about the automaton in
  Menhir's `--dump` output. That Menhir's generated tables and GLR runtime
  accept exactly that automaton's trees is assumed.
- **Precedence in the GLR relation.** `rho` maps the GLR parser's trees into
  derivations of the source grammar. It does not show that they are trees of
  the precedence-filtered source relation. Both relations are proven
  unambiguous separately.

The lexer, the semantic actions, and the rest of the compiler lie outside both
theorems.
