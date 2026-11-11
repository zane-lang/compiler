# Zane compiler

This repository holds **`zanec`**, the compiler for the
[Zane](https://github.com/zane-lang/zane) programming language, and the C
runtime every Zane program links with.

**Want to write Zane programs?** You don't need this repository. Install the
[`zane`](https://github.com/zane-lang/zane) command, which downloads released
compilers and runs them for you. This README is for people who want to work on
the compiler itself, or call `zanec` directly.

## How the compiler works

`zanec` is written in OCaml and generates code through LLVM. A program passes
through six stages, each handing a tree to the next:

```text
source → CST → SST → TST → CGT → (optimized CGT) → binary
```

1. **parsing** reads source text into the concrete syntax tree (CST);
2. **desugaring** rewrites it to the simplified syntax tree (SST), which says
   each thing one way;
3. **semantics** resolves names and checks types, producing the typed tree (TST);
4. **lowering** turns it into the code-generation tree (CGT);
5. **optimization**, in optimized builds, evaluates at compile time what the
   program would compute the same way every run;
6. **codegen** emits LLVM IR and links the binary.

[`docs/design/stages.md`](docs/design/stages.md) explains each stage, and
[`docs/README.md`](docs/README.md) indexes every design document. The grammar is
proven unambiguous; [`docs/ambiguity/`](docs/ambiguity/README.md) says how.

The compiler follows the [language specification](https://github.com/zane-lang/spec).
Where it deliberately does something else, or decides what the spec leaves
open, [`docs/spec-divergences.md`](docs/spec-divergences.md) says so.

## Building it

Everything the build needs (OCaml, LLVM and clang, Zig, `just`, Python and the
rest) comes from one [pixi](https://pixi.sh) environment, on Linux x86-64,
macOS and Windows x86-64. With pixi installed:

```sh
git clone --recurse-submodules https://github.com/zane-lang/compiler
cd compiler
pixi run setup               # once: builds the OCaml packages, takes a while
pixi run just build
pixi run just test-compiler
```

`pixi shell` enters the environment so you can drop the `pixi run` prefix.
`just` with no arguments lists every recipe; `just test` runs every suite.
Windows also needs Visual Studio's C++ build tools. The full setup, what each
system runs, and the developer tools are in
[`docs/development.md`](docs/development.md).

## Using `zanec` directly

`zane` normally runs `zanec` for you. To call it yourself, name the program
and every package it imports with `--package`; `zanec` loads nothing else:

```sh
zanec --check --root --package app=path/to/project/bin/app --package core=path/to/core/lib/core
zanec --build hello --root --package hello=path/to/hello --package core=path/to/core/lib/core
zanec --target x86_64-windows-gnu --build hello.exe --root --package hello=path/to/hello --package core=path/to/core/lib/core
```

A released compiler is in `~/.zane/toolchains/<version>/bin/zanec`, where
`zane toolchain install` puts it. In a development checkout, `pixi shell`
provides a `zanec` that takes the same arguments
([`docs/development.md`](docs/development.md#developer-tools)).

`zanec` with no arguments prints its usage. Released compilers can build
for Linux, Windows and macOS from any of those systems. To install a release
archive by hand, and for how releases are published, see
[`docs/releasing.md`](docs/releasing.md).

## Where things are

| Path | What it holds |
|---|---|
| `bin/zanec/` | The compiler's entry point |
| `lib/` | One library per stage (`cst`, `sst`, `tst`, `cgt`, `optimize`, `codegen`), the `driver` that runs them, and their shared parts: `source`, `diagnostic`, `foreign` (C code in packages), `cache` |
| `runtime/` | The C runtime every program links with |
| `grammar/` | The grammar and lexer, from which the parser and editor grammars are generated ([`grammar/README.md`](grammar/README.md)) |
| `tests/` | The test suites, one directory each ([`tests/README.md`](tests/README.md)) |
| `docs/` | Design documents ([`docs/README.md`](docs/README.md)) |
| `editors/` | Generated Tree-sitter and Typst grammars; Neovim support is the [`zane-nvim`](https://github.com/zane-lang/zane-nvim) plugin |
| `formal/` | The Lean proof that the grammar is unambiguous |
| `tools/` | Developer tools: the ambiguity checker, grammar generator, `inspect`, nesting check |
| `dev/` | The pixi environment's commands and setup scripts |
| `vendor/coda` | The [Coda](https://github.com/zane-lang/coda) parser, as a Git submodule |

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) describes how code here is written and
what has to change with it: tests and design documents go in the same pull
request, and CI checks nesting depth and file size.

## License

The compiler is free software under the GNU General Public License, version
3. Its runtime library, which every program it builds contains, comes with
the Zane Compiler Runtime Library Exception: the runtime does not make those
programs GPL, so their authors choose their terms, within what the licenses
of the program's other code allow. [`LICENSE`](LICENSE) holds both, with the
exception's exact conditions.
