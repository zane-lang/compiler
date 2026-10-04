# One grammar directory for the compiler and editors

Edit this directory, then run `python3 -m tools.grammar` from the repository
root. Menhir **20260209** must be on `PATH` (the existing Devbox shell provides
it). The generator itself uses only Python's standard library.

| Source | Owns |
|---|---|
| `syntax.mly` | Productions, precedence, OCaml actions and the start symbol |
| `lexicon.json` | Tokens, portable lexical expressions, trivia, payload conversion, token node names and highlighting roles |
| `tree-sitter.json` | GLR conflict sets, public nodes and contextual highlight queries |

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
| `editors/tree-sitter-zane/queries/highlights.scm` | Neovim and Tree-sitter highlighting |
| `editors/tree-sitter-zane/tree-sitter.json`, `package.json` | Tree-sitter build metadata and pinned CLI |
| `editors/typst/Zane.sublime-syntax` | Typst `raw(syntaxes: ...)` |
| `editors/neovim/zane.lua` | Neovim filetype detection and highlighting activation |

```sh
python3 -m tools.grammar
python3 -m tools.grammar --check
# Equivalent development recipes:
just generate-grammar
just check-grammar-generation
```

Generated text is committed. Dune and the proof tools keep their existing paths;
`just rebuild` and CI fail if outputs have drifted. `--check` writes nothing.
`--source DIR`, `--output-root DIR` and `--menhir PATH` support isolated trials.
The generator computes every output before overwriting any existing file.

### Lexical expressions

Expressions are JSON strings for literals, or objects with one operator:
`ref`, `seq`, `choice`, `star`, `plus`, `optional`, `range`, `not`, `unicode`,
or `any`. They compile to Sedlex expressions and regexes. `unicode` supports
`alphabetic`, `lowercase` and `uppercase`; `range` takes two characters and
`not` takes a nonempty list of excluded characters. For example:

```json
{"seq": [{"ref": "digits"}, ".", {"ref": "digits"}]}
```

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

The standard CI build checks generated-file drift and runs generator unit tests.
For actual backend and consumer tests, install their tools and run:

```sh
python3 -m venv .highlighting-venv
. .highlighting-venv/bin/activate
python3 -m pip install -r tests/highlighting/requirements.txt
export PATH="$PWD/editors/tree-sitter-zane/node_modules/.bin:$PATH"
just test-highlighting
```

The backend suite builds the C parser, parses every accepted example from the
existing compiler syntax suite, checks the larger parser fixtures, loads
highlight queries, checks reserved words and incomplete edits, and reruns the
compiler's acceptance/rejection suite through a parser-only driver. The
Neovim and Typst tests run if their executables are present. To reproduce the
full consumer check, install both; inspect the test output for skips.

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

The 20 declared Tree-sitter conflicts retain alternative parses rather than
forcing a choice with added precedence. Source precedence is translated per
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

Grammar edits can produce new Tree-sitter conflicts. Run `npm run generate`,
review its conflict report and update the overlay using expanded Menhir rule
names, then regenerate and rerun the backend suite. Keep source grammar edits
subject to the existing `just verify-grammar` policy. The compiler's formal
proof does not cover the generated Tree-sitter parser.
