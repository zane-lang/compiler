# Zane compiler

This repository contains the Zane language compiler and CLI.

## Setup

To setup this project in a new environment or sandbox, run:

```sh
curl -fsSL https://get.jetify.com/devbox | bash
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
ambiguities profiles
ambiguities search
ambiguities search deep-function-body --timeout 1h --output deep-search.txt
ambiguities check UIDENT LIDENT LPAREN RPAREN LCURLY RCURLY EOF
ambiguities prove 3
syntax-experiments --max-tokens 12 --timeout 15 --max-witnesses 10
syntax-experiments --variant semicolon-separated --max-tokens 12 --timeout 15 --max-witnesses 10
grammar-stats
grammar-conflicts
```

The `justfile` is reserved for parameterless project actions such as rebuilding,
watching, and running tool tests.
