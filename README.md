# Zane compiler

This repository contains the Zane language compiler and CLI.

The concrete syntax and lexical rules live in [`grammar/`](grammar/README.md).
`python3 -m tools.grammar` generates the compiler's Menhir grammar and Sedlex
lexer, a Tree-sitter grammar for Neovim, and Sublime syntax highlighting for
Typst. See that guide for generation, installation and validation commands.

## Setup

To setup this project in a new environment or sandbox, install
[Devbox](https://www.jetify.com/devbox). Prefer a package manager, for example:

```sh
nix profile install nixpkgs#devbox
```

If you install from a release instead, download the archive and verify its
checksum before running anything from it, rather than piping the installer
straight into a shell:

```sh
version=0.17.2
base="https://releases.jetify.com/devbox/stable/$version"
archive="devbox_${version}_linux_amd64.tar.gz"
curl -fsSLO "$base/$archive"
curl -fsSLO "$base/checksums.txt"
checksum="$(grep -F -- "$archive" checksums.txt)" ||
  { echo "no checksum listed for $archive" >&2; exit 1; }
printf '%s\n' "$checksum" | sha256sum --check --status
tar -xzf "$archive" devbox
install -m 0755 devbox /usr/local/bin/devbox
```

Then enter the project development shell:

```sh
devbox shell
```

The shell provides the compiler toolchain and adds `dev/bin` to `PATH`.
For regeneration and `just test`, also install Node/npm and the pinned grammar
generator dependencies as described in [`grammar/README.md`](grammar/README.md).

## Where things are

| Path | What it holds |
|---|---|
| `bin/zanec/` | The compiler binary, `zanec` |
| `lib/` | One library per stage, `cst` → `sst` → `tst` → `cgt` → `codegen`, over `source`, `diagnostic` and `tree_graph`, and `driver`, which runs them in order |
| `runtime/` | The C runtime every program links with |
| `tests/` | One directory per thing tested: `parser`, `grammar`, `semantics`, `codegen`, `runtime`, `objects`, `unit`, `highlighting`, `ambiguity` |
| `tools/` | Developer tools: the ambiguity engine and its front end, and `inspect` |
| `dev/` | Commands for the development shell (`dev/bin/`), their shared scripts (`dev/lib/`), and the toolchain bootstrap CI and the shell run (`dev/setup/`) |
| `docs/` | Design and process documents; [`docs/README.md`](docs/README.md) is the index |

## Building and testing

```sh
dune build
just test
```

`just -l` lists the recipes: `test` runs the compiler, grammar and
ambiguity-tool and grammar-generator suites, each of which also has its own recipe.

## Usage

Common tools are available directly inside the development shell:

```sh
zanec path/to/source.zn      # print the CST for a file, `-` for standard input
zanec --tst --package DIR    # type-check a package and print its typed tree
zanec --check --kind application --package app=path/to/app/src   # what `zane check` runs
ambiguity profiles
ambiguity search
ambiguity search deep-function-body --timeout 1h --output deep-search.txt
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY RCURLY EOF
ambiguity prove-visible
grammar-stat
grammar-sentence
```

The `justfile` holds project actions: rebuilding, watching, the test suites,
promoting golden files, the machine-checked grammar proof
(`just verify-grammar`), and automaton explanations (`just explain`, which
takes arguments).
