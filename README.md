# Zane compiler

This repository contains the Zane language compiler and CLI.

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

The shell provides the project toolchain and adds `dev/bin` to `PATH`.

## Where things are

| Path | What it holds |
|---|---|
| `bin/zanec/` | The compiler binary, `zanec` |
| `lib/` | One library per stage, `cst` → `sst` → `tst` → `cgt` → `codegen`, over `source`, `diagnostic` and `tree_graph` |
| `runtime/` | The C runtime every program links with |
| `tests/` | One directory per thing tested: `parser`, `grammar`, `semantics`, `codegen`, `runtime`, `ambiguity` |
| `tools/` | Developer tools: the ambiguity engine and its front end, and `inspect` |
| `dev/` | Commands for the development shell (`dev/bin/`) and their shared scripts |
| `docs/` | Design and process documents; [`docs/README.md`](docs/README.md) is the index |

## Building and testing

```sh
dune build
just test
```

`just -l` lists the recipes: `test` runs the compiler, grammar and
ambiguity-tool suites, each of which also has its own recipe.

## Usage

Common tools are available directly inside the development shell:

```sh
zanec path/to/source.zn      # print the CST for a file, `-` for standard input
zanec --tst --package DIR    # type-check a package and print its typed tree
ambiguity profiles
ambiguity search
ambiguity search deep-function-body --timeout 1h --output deep-search.txt
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY RCURLY EOF
ambiguity prove 3
grammar-stat
grammar-sentence
```

The `justfile` holds project actions: rebuilding, watching, the test suites,
promoting golden files, and the grammar sweeps and explanations, which take
arguments.
