# Zane compiler

This repository contains the Zane language compiler and CLI.

## Released toolchain

The **Release compiler** workflow publishes a Linux x86_64 toolchain archive
with `zanec`, its LLVM/shared-library dependencies, and Zig 0.16.0. It builds
Zane programs for Linux and Windows without installing OCaml, LLVM or a C
compiler. Windows-native and macOS-native compiler archives are not yet
provided; Windows program targets are tested on Windows in CI.

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
libraries and uses its bundled Zig to compile the C runtime and link programs.
The archive includes `toolchain.coda`, so the `zane` CLI recognizes it under
`~/.zane/toolchains/<version>/`. The CLI's automatic toolchain installation
command is not yet implemented. A different extraction directory also works
by setting `ZANE_COMPILER` to its `bin/zanec`.

```sh
zanec --target x86_64-linux-gnu --build hello --package path/to/hello
zanec --target x86_64-windows-gnu --build hello.exe --package path/to/hello
```

Set `ZANE_CC` to use another C compiler wrapper, or `ZIG` to use another Zig
executable. The compiler itself runs natively on Linux; Zig cross-compiles
the generated Zane program's runtime and links its target executable.

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
| `lib/` | One library per stage, `cst` → `sst` → `tst` → `cgt` → `optimize` → `codegen`, over `source`, `diagnostic` and `tree_graph`, and `driver`, which runs them in order |
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

CI holds every hand-written source file to 2,000 lines, and warns about one
past 1,500. `just check-file-sizes` runs the same check.

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
