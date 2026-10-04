# One grammar directory for the compiler and editors

Edit this directory, then run `python3 -m tools.grammar` from the repository
root. Menhir **20260209** must be on `PATH` (the existing Devbox shell provides
it). Regeneration also uses Python **3.11+**, the pinned **coda-format 2.2.2**
parser, Node/npm and **Tree-sitter CLI 0.25.10**:

```sh
python3 -m venv .grammar-venv
.grammar-venv/bin/python -m pip install -r tools/grammar/requirements.txt
npm ci --prefix editors/tree-sitter-zane
export GRAMMAR_PYTHON="$PWD/.grammar-venv/bin/python"
just generate-grammar
```

The CLI is taken from the local npm installation, or from `PATH` when that is
absent. `--tree-sitter PATH` (or `TREE_SITTER`) selects it explicitly. The generator checks its version
because conflict discovery consumes that CLI's structured diagnostic schema.

| Source | Owns |
|---|---|
| `syntax.mly` | Productions, precedence, OCaml actions and the start symbol |
| `lexicon.coda` | Tokens, portable lexical expressions, trivia, payload conversion, token node names and highlighting roles |
| `tree-sitter.coda` | Public nodes and contextual highlight queries |

[Coda](https://github.com/zane-lang/coda) supports comments and flat tables.
Literal tokens use a table; lexical expressions and payload tokens use nested
blocks. Coda leaves are strings: the loader explicitly interprets only version
numbers, highlighting priorities, `eof` and `any`. A spelling such as `true`,
or a range endpoint such as `0`, remains a string. The dependency is pinned to
the published 2.2.2 release; no custom Coda parser is included.

The productions retain Menhir notation rather than introducing a second grammar
DSL. Token declarations are inserted at `(* @generated-tokens *)`; do not put
`%token` declarations in the template. Productions use symbolic token names,
so a literal spelling is defined only in the lexicon. Compiler actions still call the existing
OCaml modules in `lib/cst/`. No compiler production or action was changed in the
initial migration: Menhir's action-erased expanded output is byte-for-byte
identical to the previous grammar.

## Outputs and regeneration

| Generated output | Consumer |
|---|---|
| `lib/cst/parser.mly` | Menhir / Dune and the existing ambiguity/proof tools |
| `lib/cst/lexer.ml` | Sedlex / Dune |
| `editors/tree-sitter-zane/grammar.js` | Tree-sitter CLI |
| `editors/tree-sitter-zane/conflicts.json` | Generated discovery report with rule groups, example prefixes and lookahead tokens |
| `editors/tree-sitter-zane/queries/highlights.scm` | Neovim and Tree-sitter highlighting |
| `editors/tree-sitter-zane/tree-sitter.json`, `package.json` | Tree-sitter build metadata and pinned CLI |
| `editors/typst/Zane.sublime-syntax` | Typst `raw(syntaxes: ...)` |
| `editors/neovim/zane.lua` | Neovim filetype detection and highlighting activation |

```sh
.grammar-venv/bin/python -m tools.grammar
.grammar-venv/bin/python -m tools.grammar --check
# Equivalent development recipes:
just generate-grammar
just check-grammar-generation
```

Generated text is committed. Dune and the proof tools keep their existing paths;
`just rebuild` and CI fail if outputs have drifted. `--check` does not modify
generated outputs; parser generation runs in disposable temporary directories.
`--source DIR`, `--output-root DIR`, `--menhir PATH` and `--tree-sitter PATH`
support isolated trials.
The generator computes every output before overwriting any existing file.

### Lexical expressions

Expressions are Coda blocks containing one operator:
`literal`, `ref`, `seq`, `choice`, `star`, `plus`, `optional`, `range`, `not`,
`unicode`, or `any`. They compile to Sedlex expressions and regexes. `unicode` supports
`alphabetic`, `lowercase` and `uppercase`; `range` takes two characters and
`not` takes a nonempty list of excluded characters. For example:

```coda
decimal_lit {
  seq [
    {
      ref int_lit
    }
    {
      literal .
    }
    {
      ref digits
    }
  ]
}
```

`seq` and `choice` are arrays of expression blocks, including a `literal`
block for literal children. This avoids Coda's ambiguity between scalar lists
and table headers. `pattern_tokens` is an array of blocks; `literal_tokens`
is a table with `name`, `literal`, `capture` and `scope` columns. `eof_token`
is a single block. Pattern tokens are ordered first, followed by literal rows
and EOF; the compiler emitter explicitly puts literal matches before patterns.

The initial lexicon preserves Unicode names, a privacy underscore only at the
start, apostrophes between integer digit groups, decimals with digits on both
sides of the dot, strings with a backslash escaping any character, and the
apostrophe-prefixed loose operators. Unicode tables are supplied by each
backend; their version can differ.

Each token has exactly one of `literal`, `pattern`, or
`eof`. Pattern tokens carry a string payload and a named Tree-sitter leaf.
They also carry an example alias; literal aliases are derived from the spelling.
The string token's `value: "unquote"` strips its delimiters for the compiler.
`capture` names a Tree-sitter capture; `scope` names a Sublime scope.
`highlight_priority` controls overlapping Sublime rules: decimals precede
integers. Compiler and Tree-sitter lexers select longest matches themselves.

## Typst

Copy `editors/typst/Zane.sublime-syntax` beside your Typst document, then use:

````typst
#set raw(syntaxes: "Zane.sublime-syntax")

```zane
type Result = struct { value Int; }
```
````

Both `zane` and `zn` tags are recognized. This highlights the rendered document.
It does not configure the Typst web editor or your text editor.

## Neovim

Use Neovim **0.11 or newer**, Node/npm, and a C compiler. Generate the grammar
text first, then build with the pinned Tree-sitter CLI **0.25.10**:

```sh
npm ci --prefix editors/tree-sitter-zane
npm run generate --prefix editors/tree-sitter-zane
npm run build --prefix editors/tree-sitter-zane
```

The default parser ABI is **15**. Both identifier casing classes exclude the
keyword spellings from the shared lexicon; the generator emits regexes without
lookahead using a finite prefix trie. This preserves the compiler's keyword
priority even in positions where Tree-sitter expects an identifier.

For a simple local Linux installation:

```sh
mkdir -p ~/.config/nvim/parser ~/.config/nvim/queries/zane ~/.config/nvim/plugin
cp editors/tree-sitter-zane/zane.so ~/.config/nvim/parser/zane.so
cp editors/tree-sitter-zane/queries/highlights.scm ~/.config/nvim/queries/zane/
cp editors/neovim/zane.lua ~/.config/nvim/plugin/zane.lua
```

The generated Lua registers `.zn` and `.zane` files and starts the highlighter.
No LSP or `nvim-treesitter` registration is needed. Use `:Inspect` and
`:InspectTree` to inspect captures and tree structure. Other platforms can use
the parser artifact appropriate to their platform on Neovim's runtime path.

## Validation

Every CI build checks generated-file drift. When a change touches the grammar,
the generator, the editor files or the compiler parser, CI also installs Neovim
and Typst and runs the backend and consumer tests. To run them locally:

```sh
python3 -m venv .highlighting-venv
.highlighting-venv/bin/python -m pip install -r tests/highlighting/requirements.txt
npm ci --prefix editors/tree-sitter-zane
export GRAMMAR_PYTHON="$PWD/.highlighting-venv/bin/python"
just test-highlighting
```

The recipe uses the npm-installed Tree-sitter CLI.

The backend suite builds the C parser, parses every accepted example from the
existing compiler syntax suite, checks the larger parser fixtures, loads
highlight queries, checks reserved words and incomplete edits, and reruns the
compiler's acceptance/rejection suite through a parser-only driver. The
Neovim and Typst tests run if their executables are present. To reproduce the
full consumer check, install both and set `ZANE_REQUIRE_HIGHLIGHTING_TOOLS=1`,
as CI does, so that a missing tool fails the run instead of skipping its tests.

The initial implementation was tested with Menhir 20260209, Sedlex 3.7,
Tree-sitter CLI 0.25.10 / Python binding 0.25.2, Neovim 0.12.5 and Typst 0.15.1.
The existing grammar regressions and span goldens also passed. With Lean 4.34.1,
the existing checker verified source-grammar unambiguity and GLR unambiguity
and correspondence for the regenerated compiler grammar.

## Scope and limitations

This is a Zane-specific generator, not a general converter for every Menhir
extension. It uses `--only-preprocess-uu` to expand parameterized and `%inline`
rules and erase OCaml actions. The reader supports the resulting production
format and standard-library `@name` attributes; unsupported syntax fails with
an error. Nullable helpers become optional references to their nonempty rules,
since Tree-sitter forbids empty non-start rules.

Tree-sitter conflicts are discovered on every regeneration, including `--check`.
The generator starts with no declarations, runs `tree-sitter generate --json`,
adds only the diagnostic's `AddConflict` rule group, and repeats until generation
succeeds. It currently discovers 20 groups. No generated report or previously
declared conflict is used as input. It stops on other errors, duplicate groups,
or more than 128 groups, and computes all outputs before replacing any file.
The committed report makes changes reviewable without requiring manual upkeep.

This uses the conflicts of the translated grammar directly. Menhir's conflicts
would need a mapping across the nullable-rule rewrite and different automata;
they are not needed for this discovery method. The default policy retains
competing parses rather than inventing extra precedence. New groups are
automatically accepted, so review report diffs and run the backend suite;
discovery does not establish correctness or acceptable runtime performance.
Source precedence is translated per
production. Menhir `%nonassoc` becomes Tree-sitter `prec`, which does not by
itself implement rejection on equal precedence. This translation is tested
against Zane's examples; it is not a proven language-equivalence transformation.

Tree-sitter provides an editor tree and error recovery. It does not execute
OCaml actions or `Statement_check`, so it accepts some constructs the compiler
rejects, including certain trailing-block continuations, mismatched import
alias casing, and statement terminators after braces. Compiler checks remain
authoritative. The editor tree also differs from the compiler's constructed
CST: public nodes are selected in the overlay, and expanded helper nodes are
hidden. Highlighting includes lexical roles plus a few contextual function and
member captures; it does not perform name resolution.

Grammar edits can produce new Tree-sitter conflicts. Regenerate, review the
generated conflict report, and rerun the backend suite. Keep source grammar edits
subject to the existing `just verify-grammar` policy. The compiler's formal
proof does not cover the generated Tree-sitter parser.
