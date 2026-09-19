# Repository layout proposal

Status: **proposal**

This document proposes a more modular repository layout for the compiler as it
grows. The current repository is already well structured around compiler
stages; this proposal deliberately preserves that shape and targets the places
where responsibilities have started to accumulate inside single files or flat
directories.

Merging this document should not be read as approval for a single giant
rename/refactor. The migration section is intentionally incremental so that
each move can be reviewed independently and grammar/prover history stays easy
to follow.

## Goals

The layout should make it possible to answer these questions from a path alone:

- Is this production compiler code, a developer tool, a test, or documentation?
- Which compiler stage or developer subsystem owns it?
- Is this file an entry point, a model, an algorithm, or presentation/config?
- Where should a new file for the same responsibility go?

The repository should also avoid two opposite failure modes:

1. **flat-directory growth**, where unrelated tools and tests accumulate beside
   each other because there is nowhere more specific to put them; and
2. **micro-module fragmentation**, where tightly coupled recursive data or one
   coherent transformation is split only to reduce line counts.

The unit of modularity should be a responsibility, not an arbitrary file-size
limit.

## What is already good and should stay

The strongest part of the current layout is the stage-oriented compiler core:

- `bin/` contains product entry points.
- `lib/cst/` owns parsing and the concrete syntax tree.
- `lib/sst/` owns the simplified syntax tree and CST -> SST lowering.
- `lib/tree_graph/` and `lib/span_text/` are small focused support libraries.
- `dev/bin/` exposes development commands without mixing their shell wrappers
  with shipped binaries.
- `docs/stages.md` gives the architecture a clear stage model.

That is a good base. In particular, this proposal does **not** recommend a
generic `lib/common/`, `lib/utils/`, or `src/` bucket. Those would make the
tree less descriptive than it is today.

## Current pressure points

At the time this proposal was written, a few files/directories carry several
distinct responsibilities:

| Path | Approx. size | Why it is a pressure point |
| --- | ---: | --- |
| `tools/ambiguity_search.ml` | 4,816 lines | automaton loading, exact recognition, abstract proof, refinement, bounded search, progress, memory/config, and CLI wiring live in one executable module |
| `tools/test_prover.py` | 1,859 lines | fixtures, output parsers, helpers, and many independent prover test families share one file |
| `tools/syntax_experiment.py` | 1,386 lines | experiment model, source transforms, process execution, evaluation, reporting, and CLI are combined |
| `tools/ambiguity.py` | 813 lines | profile schema/loading, argument coercion, rendering, process execution, and CLI dispatch are combined |
| `lib/cst/parser.mly` | 1,813 lines | the grammar is cohesive, but roughly the first 535 lines are OCaml helper logic rather than grammar productions |
| `docs/ambiguity.md` | 1,177 lines | policy, proof obligations, tool manual, historical experiments, configuration, and soundness notes are all one document |
| `tools/` | flat | parser inspection, ambiguity research, syntax experiments, tests, and helper grammars all share one namespace |
| `test-parser/` + `test/` | two roots | parser inputs and their golden outputs are separated by naming rather than by a common test hierarchy |

Not every large file should be split. In particular, `lib/cst/nodes.ml`,
`lib/sst/nodes.ml`, and `lib/sst/lower.ml` are currently cohesive enough
that splitting them would mostly turn direct recursive structure into
cross-module plumbing.

## Proposed target layout

This is a target shape, not a requirement to create every directory at once.

```text
.
├── bin/
│   └── compiler/
│       ├── dune
│       └── main.ml
│
├── lib/
│   ├── cst/
│   │   ├── dune
│   │   ├── cst.ml
│   │   ├── nodes.ml
│   │   ├── span.ml
│   │   ├── lexer.ml
│   │   ├── parser.mly
│   │   ├── parser_nodes.ml
│   │   ├── parser_actions.ml
│   │   ├── statement_shape.ml
│   │   ├── statement_check.ml
│   │   └── to_tree_graph.ml
│   │
│   ├── sst/
│   │   ├── dune
│   │   ├── sst.ml
│   │   ├── nodes.ml
│   │   ├── lower.ml
│   │   └── to_tree_graph.ml
│   │
│   ├── span_text/
│   └── tree_graph/
│
├── tools/
│   ├── ambiguity/
│   │   ├── dune
│   │   ├── ambiguity_search.ml
│   │   ├── output.ml
│   │   ├── automaton.ml
│   │   ├── stack_pool.ml
│   │   ├── recognizer.ml
│   │   ├── abstraction.ml
│   │   ├── prover.ml
│   │   ├── search.ml
│   │   ├── config.ml
│   │   ├── cli.py
│   │   ├── profiles.py
│   │   ├── runner.py
│   │   ├── profiles.toml
│   │   ├── explain_automaton.py
│   │   ├── precision_sweep.py
│   │   └── grammars/
│   │
│   ├── parser/
│   │   ├── dune
│   │   ├── parser_accept.ml
│   │   ├── parser_shape.ml
│   │   ├── span_dump.ml
│   │   └── sst_dump.ml
│   │
│   └── syntax_experiment/
│       ├── cli.py
│       ├── model.py
│       ├── transforms.py
│       ├── runner.py
│       └── report.py
│
├── dev/
│   ├── bin/
│   └── lib/
│
├── test/
│   ├── parser/
│   │   ├── dune
│   │   ├── fixtures/
│   │   │   ├── main.zn
│   │   │   ├── utf8.zn
│   │   │   └── desugar.zn
│   │   ├── golden/
│   │   │   ├── main.cst.spans
│   │   │   ├── main.sst.spans
│   │   │   ├── desugar.cst.tree
│   │   │   └── ...
│   │   ├── syntax_test.py
│   │   └── ambiguity_test.py
│   │
│   ├── ambiguity/
│   │   ├── cli_test.py
│   │   ├── prover_test.py
│   │   └── precision_sweep_test.py
│   │
│   └── syntax_experiment/
│       └── experiment_test.py
│
├── docs/
│   ├── stages.md
│   ├── desugaring.md
│   ├── spec-divergences.md
│   ├── repository-layout.md
│   ├── ambiguity.md
│   └── ambiguity/
│       ├── policy.md
│       ├── proof-obligations.md
│       ├── tooling.md
│       ├── experiments.md
│       └── soundness.md
│
├── reports/
│   └── ambiguity/
│       ├── search/
│       └── prove/
│
├── ambiguity-searches.toml   # temporary compatibility path while migrating
├── devbox.json
├── dune-project
└── justfile
```

A few details in that tree are intentional:

- Compiler stages stay top-level under `lib/` instead of being hidden under a
  generic `compiler/` directory.
- Developer tooling is grouped by **subsystem**, not language. The OCaml engine,
  Python wrapper, helper scripts, and grammars for ambiguity work belong
  together even though they are implemented in different languages.
- Tests mirror the subsystem they test.
- The user-facing `ambiguity` command can stay in `dev/bin/`; only its
  implementation moves.
- `ambiguity-searches.toml` can stay at the repository root during migration
  so existing workflows keep working, then move once the wrapper can resolve a
  subsystem-local default without surprising users.

## 1. Split the ambiguity engine first

This is the highest-value change.

`tools/ambiguity_search.ml` already has natural internal boundaries. Its
top-level definitions show roughly these regions:

- output/progress helpers;
- grammar token parsing and Menhir automaton preparation;
- automaton parsing and terminal equivalence classes;
- concrete GLR stack storage and recognition;
- abstract stack representation and transition logic;
- survey/refinement/candidate analysis;
- proof-state exploration;
- bounded concrete witness search and parallelization;
- memory/progress persistence;
- environment/config/CLI wiring.

Those are real ownership boundaries, not cosmetic section headings.

A practical first split could be:

### `automaton.ml`

Own:

- `reduction`, `state`, and `automaton`;
- token declaration parsing;
- Menhir invocation/preparation;
- automaton dump parsing;
- minimum stack-height computation;
- terminal equivalence classes;
- production-name rendering.

This module answers: **what automaton are we proving/searching?**

### `stack_pool.ml`

Move the existing `Stack_pool` module out unchanged first.

This module answers: **how are exact GLR stacks represented and shared?**

### `recognizer.ml`

Own:

- concrete `frontier` and recognizer `engine`;
- reduction closure;
- shifts;
- acceptance counting;
- exact replay;
- concrete stack suffixes;
- possible-token computation;
- concrete lower bounds used by the search.

This module answers: **what does the grammar actually recognize?**

### `abstraction.ml`

Own:

- `precision`;
- abstract `stack`;
- stack residue/height constraints;
- abstract side moves;
- joint outcomes;
- chain/conflict diagnostics;
- abstraction-specific refinement requests.

This module answers: **how do concrete stacks project into the finite proof
state space?**

It is acceptable for this to remain around 1,000 lines initially. The purpose
of the first split is to separate concepts, not to force every file below an
arbitrary threshold.

### `prover.ml`

Own:

- survey/candidate/result types;
- `prove_state`;
- queueing/invalidation/reopening;
- refinement rounds and retirement;
- the top-level abstract proof algorithm and its verdict.

This module answers: **can the abstract state space rule out ambiguity?**

### `search.ml`

Own:

- concrete search outcome types;
- witness rendering/profile helpers;
- seen/frontier caches;
- unified bounded search;
- partitioning and parallel workers.

This module answers: **can we find a concrete ambiguous sentence within the
requested bound?**

### `output.ml`

Own the shared terminal/reporting primitives:

- flushed `printf`/`eprintf`;
- progress cadence;
- compact counts and elapsed clocks;
- search-progress rendering/persistence;
- memory-bar presentation.

This keeps presentation concerns out of both proof algorithms.

### `config.ml`

Own:

- environment parsing;
- memory-limit derivation;
- engine option definitions;
- validation of incompatible flags.

Then `ambiguity_search.ml` becomes a thin executable entry point that wires
the modules together and calls `main`.

### Why not split more immediately?

The proof subsystem is still evolving quickly. A first modular cut should make
ownership obvious without freezing every helper into a public interface.
Modules can be split again after their dependency directions settle.

The desired dependency direction is roughly:

```text
Config / Output
      ↓
   Automaton
      ↓
 Stack_pool
      ↓
 Recognizer
      ↓
 Abstraction
      ↓
    Prover

Automaton + Recognizer + Output
      ↓
    Search

Prover + Search + Config
      ↓
ambiguity_search.ml
```

Cycles between these modules should be treated as a sign that the boundary is
wrong or that a small shared type belongs lower in the graph.

## 2. Extract OCaml helper logic from `parser.mly`, but keep the grammar together

The parser file is large, but most of the grammar is one strongly connected
piece of syntax design. Splitting productions across many Menhir files would
make precedence and ambiguity work harder to review.

The clean split is the non-grammar prologue.

The first ~535 lines currently include several independent responsibilities:

### `parser_nodes.ml`

Move the small spanned-node constructors:

- `mk_name`;
- `expr`;
- `call_arg`;
- `constructor_args`;
- `verb_call`;
- `mould`;
- `type_expr`;
- `stat`;
- `decl`;
- operator/name/import constructors;
- and similar one-line builders.

The grammar then calls descriptive construction helpers without carrying their
record boilerplate.

### `parser_actions.ml`

Move parser semantic helpers that construct or rewrite larger nodes:

- `attach_abort_handle`;
- `constructor_expr`;
- `import_alias`.

These are semantic actions, but they do not need to live textually inside the
grammar.

### `statement_shape.ml`

Move shape/termination logic:

- `expr_ends_in_brace` and related recursive helpers;
- trailing-call detection;
- “continues past trailing” logic;
- statement constructor helpers such as `statement`, `expr_statement`,
  `braced_statement`, and `terminated_statement`.

This logic is substantial enough to deserve a name and tests of its own. It is
also distinct from `statement_check.ml`: the former decides statement shape
while the grammar is building nodes; the latter walks the completed CST and
reports statement defects.

The important result is that `parser.mly` becomes mostly:

1. tokens/precedence;
2. grammar productions;
3. short calls into named support modules.

That improves navigation without making the grammar itself geographically
fragmented.

## 3. Keep `nodes.ml` cohesive for now

`lib/cst/nodes.ml` and `lib/sst/nodes.ml` look large in the tree, but their
size is largely a consequence of mutually recursive syntax types.

Splitting them into `expr.ml`, `type.ml`, `decl.ml`, etc. would either:

- introduce recursive-module plumbing;
- duplicate forward declarations/interfaces; or
- force the data model into boundaries that the type graph does not actually
  have.

A single “schema” module is easy to search and accurately represents the fact
that expressions, calls, declarations, bodies, types, and patterns are one
recursive language tree.

Revisit this only if the type graph itself becomes separable.

## 4. Keep `lib/sst/lower.ml` as one transformation until a stronger boundary appears

`lower.ml` is about 700 lines, but almost all of it is one mutually recursive
CST -> SST tree walk. Its sectioning is already clear: types, expressions,
calls, matches, statements, lambdas, moulds, declarations.

Splitting by section today would trade a local `and` chain for cross-module
recursion and interfaces. That is not a navigation win.

A future split becomes worthwhile if lowering grows independent passes, for
example:

```text
sst/
  lower/
    surface.ml
    derived_operators.ml
    match_groups.ml
    statements.ml
```

but only once those are actual passes rather than functions in one recursive
walk.

## 5. Turn `tools/` into subsystem directories

Today `tools/` mixes:

- ambiguity engine code;
- the ambiguity wrapper;
- automaton tooling;
- precision sweeps;
- syntax experiments;
- parser inspection executables;
- helper grammars;
- and Python tests.

That makes the next file's location increasingly ambiguous.

### `tools/ambiguity/`

Move all ambiguity-specific implementation here:

- `ambiguity_search.ml` and its extracted modules;
- `ambiguity.py` as `cli.py` or a small package entry point;
- `precision_sweep.py`;
- `explain_automaton.py`;
- `grammars/`.

The current shell-facing command stays `dev/bin/ambiguity`, so users do not
care where its implementation lives.

The Python wrapper should itself be split by responsibility:

- `profiles.py`: `SearchProfile`, `Setting`, TOML loading, inheritance,
  coercion, validation, output-path expansion;
- `runner.py`: engine command construction, streaming, prelude/output handling;
- `cli.py`: argparse and dispatch only.

### `tools/parser/`

Group the small parser inspection/debug executables:

- `parser_accept.ml`;
- `parser_shape.ml`;
- `span_dump.ml`;
- `sst_dump.ml`.

They are not part of the compiler library and they are not ambiguity-engine
internals; “parser developer tools” is their shared responsibility.

### `tools/syntax_experiment/`

`syntax_experiment.py` has cleanly separable concerns:

- `model.py`: `Variant`, `Spelling`, `KnownCase`, result dataclasses;
- `transforms.py`: source-spelling transforms;
- `runner.py`: process lifetime, search command execution, timeout behavior;
- `report.py`: metrics, Pareto marking, Markdown rendering, report writing;
- `cli.py`: parser, config loading, validation, main.

This is a better split than one file per experiment variant: variants are data;
the responsibilities above are actual modules.

## 6. Give tests one root and mirror the implementation

`test-parser/` contains parser fixture source while `test/` contains golden
outputs and Dune rules. That relationship is not obvious until the build files
are read.

Prefer:

```text
test/parser/
  fixtures/
    main.zn
    utf8.zn
    desugar.zn
  golden/
    main.cst.spans
    main.sst.spans
    desugar.cst.tree
    desugar.sst.tree
    ...
  dune
```

The naming of goldens should say both the fixture and representation where
useful. For example, `main.cst.spans` is more self-describing than
`main.spans`.

Python tests should move out of `tools/` as well:

```text
test/ambiguity/
  cli_test.py
  prover_test.py
  precision_sweep_test.py

test/parser/
  syntax_test.py
  ambiguity_test.py

test/syntax_experiment/
  experiment_test.py
```

### Split `test_prover.py` by behavior

The current file already contains independent classes:

- soundness;
- precision;
- refinement;
- retirement;
- stack-height/residue behavior;
- candidate exact-parse behavior;
- forward traces;
- proof statuses/budgets;
- concrete search termination;
- surveys.

A good first split is not one file per test method. It is a few files aligned
with prover features:

```text
test/ambiguity/prover/
  fixtures.py
  harness.py
  soundness_test.py
  refinement_test.py
  diagnostics_test.py
  verdict_test.py
  survey_test.py
```

`fixtures.py` owns the tiny constructed grammars.
`harness.py` owns the executable runner and shared regex/output assertions.

This removes the largest source of duplication without scattering each feature
across dozens of files.

## 7. Split `docs/ambiguity.md` into a small index plus focused documents

The ambiguity document is valuable, but it currently serves several audiences
at once.

Keep `docs/ambiguity.md` as the stable entry point and make it a short index
and policy summary. Move detail to:

- `docs/ambiguity/policy.md`: smallest-grouping rule and the repository's
  ambiguity acceptance criteria;
- `docs/ambiguity/proof-obligations.md`: current conflict families and open
  obligations;
- `docs/ambiguity/tooling.md`: search/prove/survey/refine commands, watching
  runs, profiles, local machine configuration;
- `docs/ambiguity/experiments.md`: measured/rejected restructurings and
  sharpenings;
- `docs/ambiguity/soundness.md`: abstraction argument and proof-status
  semantics.

This preserves the historical/detail value while making “how do I run the
tool?” and “what is the policy?” quick to find.

`docs/desugaring.md` and `docs/spec-divergences.md` should remain single
documents for now; they already have one clear subject and good internal
sectioning.

## 8. Reports should say which subsystem generated them

Every current checked-in report is ambiguity-related. If reports remain
versioned, prefer:

```text
reports/
  ambiguity/
    search/
      general/
      deep-function-body/
    prove/
```

This keeps the top-level namespace open for future semantic/codegen benchmark
or analysis reports without making “reports” implicitly mean “ambiguity
reports”.

This move is low priority because it changes historical paths and provides less
day-to-day value than splitting code and tests.

## Naming rules

A few naming conventions would keep the modular layout from becoming noisy:

1. **Directories name subsystems/stages.**  
   Examples: `cst`, `sst`, `ambiguity`, `syntax_experiment`.

2. **Files name responsibilities.**  
   Examples: `automaton.ml`, `recognizer.ml`, `prover.ml`,
   `transforms.py`.

3. **Entry points stay thin.**  
   `main.ml`, `ambiguity_search.ml`, and `cli.py` should mostly parse/wire
   and call library code.

4. **Do not create “helpers”, “common”, or “utils” without a domain noun.**  
   `parser_nodes.ml` says why helpers belong together; `utils.ml` does not.

5. **Tests mirror production ownership.**  
   A prover test belongs under `test/ambiguity/`, not beside the prover
   implementation.

6. **Avoid one directory per source file.**  
   A directory should exist because several files share a subsystem boundary.

## Suggested migration order

The safest order is intentionally biased toward moves that expose clean APIs
without changing language behavior.

### Phase 1 — ambiguity engine modules

Split `tools/ambiguity_search.ml` in-place into modules under
`tools/ambiguity/`, with behavior and CLI output unchanged.

This has the highest payoff and gives the prover a structure capable of
growing without returning to a monolith.

### Phase 2 — parser support extraction

Move the Menhir prologue helpers into:

- `parser_nodes.ml`;
- `parser_actions.ml`;
- `statement_shape.ml`.

Keep grammar rules in one `parser.mly`.

### Phase 3 — test tree

Merge `test-parser/` into `test/parser/fixtures/`, move golden files beside
it, and move Python tests from `tools/` into mirrored test subdirectories.

Do this in one mechanical PR so fixture/golden renames do not linger half
migrated.

### Phase 4 — developer tool directories

Group parser tools, ambiguity tools, and syntax-experiment code into subsystem
directories. Update `dev/bin/`, `justfile`, and Dune paths without changing
the user-facing commands.

### Phase 5 — split Python tool internals

Refactor `ambiguity.py` and `syntax_experiment.py` into their packages after
the directory moves, so file movement and behavioral refactoring are not mixed
in the same diff.

### Phase 6 — documentation and report cleanup

Split `docs/ambiguity.md` while retaining the old path as an index, then
optionally nest historical reports.

## What should not be done as one PR

Avoid a single repository-wide refactor that simultaneously:

- moves the directories;
- splits the prover;
- splits parser helpers;
- renames tests;
- changes Dune libraries;
- changes wrapper paths;
- and updates documentation links.

That would be hard to review and would make `git blame`/history much less
useful in exactly the grammar and prover code where history is important.

Prefer small mechanical commits/PRs where a reviewer can answer one question:
“Did this responsibility move without changing behavior?”

## Short version

If only three changes are made, make them these:

1. **Split `tools/ambiguity_search.ml` into automaton / recognizer /
   abstraction / prover / search / config-output modules.**
2. **Extract the first ~535 lines of helper logic from `lib/cst/parser.mly`,
   but keep the grammar productions together.**
3. **Unify `test-parser/` and `test/` into a mirrored `test/` hierarchy,
   and move tool tests out of the production `tools/` namespace.**

Those three changes preserve the repository's existing strengths while making
the areas most likely to keep growing much easier to navigate.
