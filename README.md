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
ambiguity-config
ambiguities 100 3600
ambiguity-prove 2 12 120
syntax-experiments
syntax-experiment semicolon-separated
grammar-stats
grammar-conflicts
```

`ambiguity-search` exposes the underlying OCaml tool directly for advanced
invocations. The `justfile` remains the source of the higher-level commands.
