# Syntax experiments

`syntax_experiment.py` compares small, explicit changes to Zane's concrete
syntax. It generates a temporary Menhir grammar for every selected variant,
replays the known complete-ambiguity witnesses, runs the bounded ambiguity
search, and produces Markdown and JSON reports.

This is deliberately not a grammar-rewriting model. Every mutation is named,
reviewable, composable, and assigned an approximate edit cost.

## Quick start

```sh
syntax-experiment --list
syntax-experiment
syntax-experiment --variant semicolon-separated
```

Reports are written to:

```text
_build/syntax-experiment/report.md
_build/syntax-experiment/report.json
```

Generated grammars normally live only for the duration of a run. To inspect
them directly:

```sh
python3 tools/syntax_experiment.py --emit-only \
  --emit-dir _build/syntax-experiment/grammars
```

## Included ideas

The predefined candidates cover:

- semicolons required between adjacent statements;
- semicolons required after every statement;
- only statically named functions, methods, and constructors as call statements;
- significant newline separators;
- `[]`, `{}`, or `group()` expression grouping;
- removing general grouping;
- `[]`, `@()`, or `.()` for all calls;
- ordinary calls for names with `@()` or `[]` reserved for computed callees;
- abort handlers anchored to delimited boundaries (statement calls,
  declaration values, `return`/`resolve`/`abort` values, call arguments, and
  grouping) instead of every expression production;
- combinations of the most promising statement, grouping, call, and
  abort-handler changes.

The named-statement experiment still permits computed calls inside expressions.
It only prevents a computed call such as `(x)()` from independently reducing to
a statement. Named method calls remain valid statements even when their receiver
is computed.

The `semicolon-separated` experiment requires a semicolon only where another
statement follows and permits one trailing semicolon. The stricter
`semicolon-terminated` experiment requires a terminator after every declaration
and statement, including the final item in a block.

## Measurements

Known witnesses are **respelled in each variant's own syntax** before being
replayed: every transformation that changes surface spelling registers a
matching update in `SPELLINGS`, and each known case builds its intended
program from the resulting spelling profile. A rejection therefore means the
variant genuinely cannot parse the intended program — never that an old
spelling merely became illegal. A case a variant cannot express at all (for
example a computed-call statement under `named-statement-calls`) is labeled
"not expressible" and counted as rejected.

Alongside the ambiguity witnesses, the case set includes one plain
compatibility probe: an ordinary named call statement, `print("hello")`,
which every variant is expected to parse exactly once (spelled
`print["hello"]` under `bracket-calls`, and so on).

For each candidate, the report records:

- whether each known witness has zero, one, or two accepting derivations;
- complete ambiguity profiles found within the configured bounds;
- explored and unique frontiers;
- conflict seeds;
- search limits and elapsed time;
- up to five shortest concrete witnesses;
- an approximate syntax edit cost.

A candidate that rejects a known program is penalized separately from one that
still parses it ambiguously. A zero-witness result that stopped at a timeout or
frontier limit is marked uncertain rather than ambiguity-free.

The Pareto marker means that no other tested candidate was at least as good on
every measured axis. It is not an automatic language-design decision: readability,
orthogonality, and whether a changed spelling expresses Zane's intent still need
human judgment.

## Adding an experiment

1. Add a transformation function that uses `replace_once` or another checked
   structural edit. A changed grammar anchor must fail loudly rather than silently
   producing the baseline grammar.
2. Register it in `TRANSFORMS`, and register a matching spelling update in
   `SPELLINGS` (the identity update for transforms that do not change how the
   known witnesses are spelled). The two tables must cover the same names.
3. Add one or more `Variant` entries, including useful combinations and an edit
   cost.
4. Add focused assertions to `test_syntax_experiment.py`.
5. Run `just syntax-experiment-test`, then a short single-variant search before
   comparing the full matrix.

## Limitations

The ambiguity search is bounded because ambiguity of arbitrary context-free
grammars is undecidable. Results compare evidence found under equal bounds; they
do not prove global unambiguity.

These variants mutate the parser grammar only. A candidate that introduces a
token such as `NEWLINE` or `group` would also require a corresponding lexer
change before it could become real language syntax. Likewise, compatibility is
currently measured with token witnesses rather than a large source-to-AST corpus.
Adding an AST golden corpus is the natural next step once enough representative
Zane programs exist.
