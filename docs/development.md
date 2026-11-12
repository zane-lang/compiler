# Developing the compiler

The full setup for building and testing the compiler on Linux, macOS and
Windows. The README has the short version.

One [pixi](https://pixi.sh) environment, from `pixi.toml` and `pixi.lock`,
holds the whole toolchain on Linux (x86-64), macOS (Apple Silicon and Intel)
and Windows (x86-64): OCaml, opam, LLVM and clang 21, LLD, zig, `just`,
Python, Node and the rest. `pixi.lock` pins the environment's packages. The
OCaml libraries come from opam, which `pixi run setup` installs at the
versions `dev/setup/bootstrap-toolchain` pins, and opam resolves what those
depend on.

The compiler reads Coda files with Coda's own binding, which `vendor/coda`
holds as a Git submodule. Clone with `--recurse-submodules`, or fetch it in
an existing clone:

```sh
git submodule update --init
```

## Install pixi

On Linux and macOS, install pixi with its
[installer or a package manager](https://pixi.sh/latest/installation/), for
example `brew install pixi`, or download the release archive for your
platform from [pixi's releases](https://github.com/prefix-dev/pixi/releases)
and check it against the `.sha256` file beside it before unpacking it into a
directory on `PATH`.

On Windows, install it with `winget install prefix-dev.pixi`, or from the
same releases page.

## Windows: the C++ tools

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

## Provision the environment

```sh
pixi run setup
```

This installs the environment and then builds the project's opam switch (the
OCaml packages `dev/setup/bootstrap-toolchain` pins: dune, menhir, sedlex and
the rest) in `_opam/`. Run it once, and again when a pin or `pixi.lock`
changes. The first run builds several packages from source and takes a while.

## Build and test

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
`ZANE_CC` to `dev/bin/clang-lld`, which is clang with LLVM's `lld` as its
linker on Linux and plain clang on macOS. `zanec` asks it for the line its linker
would run, on macOS with `-fuse-ld=lld` so that the line is `lld`'s, and
links with the `lld` built into it. On Windows it sets `ZANE_CC` to
`dev/bin/zig-cc.cmd`, which links through `zig cc` for MinGW. `ZANE_CC` is
left alone if it is already set. Set `ZANE_VERBOSE` to have a build say why
it links through the C compiler instead.

## What each OS runs

`just test` passes on all three. CI runs `just test-compiler` natively on
each, Windows and macOS on `main`, in the merge queue and on manual runs but
not on a pull request, and the rest of `just test` on Linux, since what those suites check does not
depend on the host. CI also runs the test programs built on Linux for
Windows and macOS on those systems.
The highlighting consumers (`just test-highlighting`) and `just test-perf`
run on Linux only, as does `just test-windows`, which runs the Windows
programs under Wine. How the platforms differ, and what each is held to, is
in [`design/platforms.md`](design/platforms.md).

For grammar regeneration and the highlighting suite, install the pinned
generator dependencies with `pixi run .github/scripts/setup-grammar-dependencies`,
as [`grammar/README.md`](../grammar/README.md) describes.

## Developer tools

Common tools are available directly inside `pixi shell`, or through `pixi run`.
On Linux and macOS, `zanec` there builds the compiler if needed and runs it,
with paths taken relative to the directory you run it in. Name every package
a program imports with its own `--package`. On Windows the environment has no
`zanec` command; run `_build/default/bin/zanec/zanec.exe` instead:

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
