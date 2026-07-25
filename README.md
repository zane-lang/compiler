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
./enter
```

The shell provides the project toolchain and adds `dev/bin` to `PATH`. Product
executable sources remain under `bin/`, while development-only command wrappers
live under `dev/bin/`.

## Building

```sh
./enter
dune build
```

## Usage

Common tools are available directly inside the development shell:

```sh
compiler
ambiguity profiles
ambiguity search
ambiguity search deep-function-body --timeout 1h --output deep-search.txt
ambiguity check UIDENT LIDENT LPAREN RPAREN LCURLY RCURLY EOF
ambiguity prove 3
syntax-experiment --max-tokens 12 --timeout 15 --max-witnesses 10
syntax-experiment --variant semicolon-separated --max-tokens 12 --timeout 15 --max-witnesses 10
grammar-stat
grammar-conflict
```

The `justfile` is reserved for parameterless project actions such as rebuilding,
watching, and running tool tests.
