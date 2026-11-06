# Zane compiler

This repository contains the Zane language compiler and CLI.

## Released toolchain

The **Release compiler** workflow publishes a Linux x86_64 toolchain archive
with `zanec`, its LLVM/shared-library dependencies, and Zig (the version in the
archive's `share/zig.json`, pinned by `dev/toolchains/zig.json`). It builds Zane
programs for Linux, Windows and macOS without installing OCaml, LLVM or a C
compiler. Windows-native and macOS-native compiler archives are not yet
provided; Windows and macOS program targets are tested on Windows and macOS
in CI.

Download the `.tar.gz` and `SHA256SUMS` from a
[compiler release](https://github.com/zane-lang/compiler/releases), then verify
and extract the archive. For example, once `v0.1` has been published:

```sh
version=v0.1
archive="zane-compiler-$version-linux-x86_64.tar.gz"
base="https://github.com/zane-lang/compiler/releases/download/$version"
curl -fSLO "$base/$archive"
curl -fSLO "$base/SHA256SUMS"
sha256sum --check --strict SHA256SUMS
mkdir -p "$HOME/.zane/toolchains/$version"
tar -xzf "$archive" --strip-components=1 -C "$HOME/.zane/toolchains/$version"
export PATH="$HOME/.zane/toolchains/$version/bin:$PATH"
```

Keep the whole extracted directory together: `bin/zanec` loads its bundled
libraries, links with its bundled runtimes and link files, and uses its
bundled Zig for any other target.
The archive includes `toolchain.coda`, so the `zane` CLI recognizes it under
`~/.zane/toolchains/<version>/`, where `zane toolchain install` puts it. A
different extraction directory also works
by setting `ZANE_COMPILER` to its `bin/zanec`.

```sh
zanec --target x86_64-linux-gnu --build hello --package path/to/hello
zanec --target x86_64-windows-gnu --build hello.exe --package path/to/hello
```

The archive bundles the C runtime compiled by its Zig for x86-64 and AArch64
Linux, Windows and macOS, optimized and not, with the linker command and
files that link a program with it, so a build for one of those runs no C
compiler: `zanec` links it with the LLD built into it. Set `ZANE_CC` to use
another C compiler wrapper, or `ZIG` to use another Zig executable; either
way the bundled runtime is not used, and the runtime that compiler compiles
and the linker command it gives are cached under `~/.cache/zane` (or
`$XDG_CACHE_HOME/zane`); set `ZANE_CACHE_DIR` to keep them elsewhere. The
compiler itself runs natively on Linux; Zig cross-compiles the runtime for
any other target.

## Publishing a compiler release

After merging, choose **Actions → Release compiler → Run workflow**, select
the default branch, and enter a new `vMAJOR.MINOR` tag, such as `v0.1`.
`v0.0` already exists and will not be overwritten. The two-component tag
format matches the `zane` CLI's compiler-version resolver.

The workflow tests the compiler, packages it, checks the relocated archive
in a clean Ubuntu 22.04 container, and runs the Windows programs it produces
on a Windows runner. Only after those checks pass does it create a tag at
the tested commit and publish the archive and SHA-256 checksums. Build jobs
have read-only repository access; only the publication job can write.

If publication fails after tagging, use **Re-run failed jobs** on the same
run: its original commit and artifacts are retained, and a tag at that commit
is safe to reuse. If a draft release was already created, finish it manually
or delete the draft before retrying (keep the tag). Existing releases and
tags at another commit are always rejected.

The concrete syntax and lexical rules live in [`grammar/`](grammar/README.md).
`python3 -m tools.grammar` generates the compiler's Menhir grammar and Sedlex
lexer, a Tree-sitter grammar for Neovim, and Sublime syntax highlighting for
Typst. See that guide for generation, installation and validation commands.

## Setup

One [pixi](https://pixi.sh) environment, from `pixi.toml` and `pixi.lock`,
holds the whole toolchain on Linux (x86-64), macOS (Apple Silicon and Intel)
and Windows (x86-64): OCaml, opam, LLVM and clang 21, LLD, zig, `just`,
Python, Node and the rest. The lock file pins every package, so each machine
builds with the same versions.

The compiler reads Coda files with Coda's own binding, which `vendor/coda`
holds as a Git submodule. Clone with `--recurse-submodules`, or fetch it in
an existing clone:

```sh
git submodule update --init
```

### Install pixi

On Linux and macOS, install pixi with its
[installer or a package manager](https://pixi.sh/latest/installation/), for
example `brew install pixi`, or download the release archive for your
platform from [pixi's releases](https://github.com/prefix-dev/pixi/releases)
and check it against the `.sha256` file beside it before unpacking it into a
directory on `PATH`.

On Windows, install it with `winget install prefix-dev.pixi`, or from the
same releases page.

### Windows: the C++ tools

On Windows, OCaml is the MSVC build, and its C and linking steps use MSVC's
`cl` and `link`. Install [Visual Studio or the Build
Tools](https://visualstudio.microsoft.com/downloads/) with the **Desktop
development with C++** workload (the `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`
component). Activation (`dev/setup/activate.bat`) finds the newest
installation with `vswhere`, which the installer provides, and loads its
`vcvars64.bat`, so nothing more is configured by hand; in a developer
prompt, where `cl` is already on `PATH`, it leaves the prompt as it is.
Everything else comes from the pixi environment. `git` is needed to clone
the repository and its submodule.

### Provision the environment

```sh
pixi run setup
```

This installs the environment and then builds the project's opam switch (the
OCaml packages `dev/setup/bootstrap-toolchain` pins: dune, menhir, sedlex and
the rest) in `_opam/`. Run it once, and again when a pin or `pixi.lock`
changes. The first run builds several packages from source and takes a while.

### Build and test

Run a command in the environment with `pixi run`, or enter it once with
`pixi shell`:

```sh
pixi run just build
pixi run just test-compiler
```

```sh
pixi shell
just test-compiler
```

The environment adds `dev/bin` to `PATH`. On Linux and macOS it sets
`ZANE_CC` to `dev/bin/clang-lld`, whose linker is LLVM's `lld`, so `zanec`
links with the `lld` built into it. On Windows it sets `ZANE_CC` to
`dev/bin/zig-cc.cmd`, which links through `zig cc` for MinGW. `ZANE_CC` is
left alone if it is already set. Set `ZANE_VERBOSE` to have a build say why
it links through the C compiler instead.

### What each OS runs

`just test-compiler`, the compiler suite, passes on all three. The grammar,
ambiguity and highlighting suites (`just test-grammar`,
`just test-ambiguity-tools`, `just test-highlighting`) and `just test-perf`
run on Linux only, as does `just test-windows`, which runs the Windows
programs under Wine. How the platforms differ, and what each is held to, is
in [`docs/design/platforms.md`](docs/design/platforms.md).

For grammar regeneration and the highlighting suite, install the pinned
generator dependencies with `pixi run .github/scripts/setup-grammar-dependencies`,
as [`grammar/README.md`](grammar/README.md) describes.

## Where things are

| Path | What it holds |
|---|---|
| `bin/zanec/` | The compiler binary, `zanec` |
| `lib/` | One library per stage, `cst` → `sst` → `tst` → `cgt` → `optimize` → `codegen`, over `source`, `diagnostic` and `tree_graph`, and `driver`, which runs them in order; `foreign`, a package's C compiled by the clang linked into the compiler; `cache`, what builds keep between runs; `coda`, the binding `vendor/coda` builds |
| `runtime/` | The C runtime every program links with |
| `tests/` | One directory per thing tested: `parser`, `grammar`, `semantics`, `codegen`, `ffi`, `runtime`, `objects`, `unit`, `highlighting`, `ambiguity`, `nesting` |
| `vendor/` | Git submodules: `coda` |
| `tools/` | Developer tools: the ambiguity engine and its front end, `inspect`, and `nesting` |
| `dev/` | Commands for the pixi environment (`dev/bin/`), their shared scripts (`dev/lib/`), and the toolchain bootstrap and the pixi activation scripts (`dev/setup/`) |
| `docs/` | Design and process documents; [`docs/README.md`](docs/README.md) is the index |

## Building and testing

```sh
pixi run dune build
pixi run just test
```

`just` lists the recipes by group: `test` runs the compiler, grammar,
ambiguity-tool and grammar-generator suites, each of which also has its own
recipe. [`tests/README.md`](tests/README.md) says what each suite covers.

CI holds every hand-written source file to 2,000 lines, and warns about one
past 1,500. The warning is a prompt to split a file along a natural seam, not
a rule to meet: a file that holds one thing and has no such seam stays past
1,500 on purpose. `just check-file-sizes` runs the same check.

CI also fails any hand-written OCaml under `lib/`, `bin/` and `tools/` that
nests past five levels, and warns about any that reaches five, counted on the
parsed tree rather than on indentation. [`CONTRIBUTING.md`](CONTRIBUTING.md)
says what counts, why three is the aim, and how to flatten deep code.
`just check-nesting` runs the same check.

## Usage

Common tools are available directly inside `pixi shell`, or through `pixi run`:

```sh
zanec path/to/source.zn      # print the CST for a file, `-` for standard input
zanec --tst --package DIR    # type-check a package and print its typed tree
zanec --check --root --package app=path/to/project/bin/app   # what `zane check` runs for a program
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
