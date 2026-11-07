# Compiler releases

How a compiler release is packaged, installed by hand, and published. Most
users install compilers with `zane toolchain install`
([`zane`](https://github.com/zane-lang/zane)); this page is for installing an
archive without it and for maintainers.

## What a release holds

The **Release compiler** workflow publishes toolchain archives for Linux
x86_64, macOS on both Apple Silicon and Intel, and Windows x86_64, each with
`zanec`, the libraries it loads, and Zig (the version in the archive's
`share/zig.json`, pinned by the platform's `dev/toolchains/zig-*.json`). Each
builds Zane programs for Linux, Windows and macOS without installing OCaml,
LLVM or a C compiler.

Download the `.tar.gz` and `SHA256SUMS` from a
[compiler release](https://github.com/zane-lang/compiler/releases), then verify
and extract the archive. For example, for `v0.28`:

```sh
version=v0.28
archive="zane-compiler-$version-linux-x86_64.tar.gz"
base="https://github.com/zane-lang/compiler/releases/download/$version"
curl -fSLO "$base/$archive"
curl -fSLO "$base/SHA256SUMS"
grep " $archive\$" SHA256SUMS | sha256sum --check --strict &&
  mkdir -p "$HOME/.zane/toolchains/$version" &&
  tar -xzf "$archive" --strip-components=1 -C "$HOME/.zane/toolchains/$version" &&
  export PATH="$HOME/.zane/toolchains/$version/bin:$PATH"
```

On Windows, take `zane-compiler-$version-windows-x86_64.tar.gz`, check it
against `SHA256SUMS` with `certutil -hashfile ARCHIVE SHA256` (or
`Get-FileHash`), and extract it with `tar -xzf`, which Windows carries; its
compiler is `bin\zanec.exe`.

Keep the whole extracted directory together: `bin/zanec` loads its bundled
libraries, links with its bundled runtimes and link files, and uses its
bundled Zig for any other target. It finds them itself, from the
`toolchain.coda` one directory above it.
The archive includes `toolchain.coda`, so the `zane` CLI recognizes it under
`~/.zane/toolchains/<version>/`, where `zane toolchain install` puts it. A
different extraction directory also works
by setting `ZANE_COMPILER` to its `bin/zanec`.

```sh
zanec --target x86_64-linux-gnu --build hello --root --package hello=path/to/hello --package core=path/to/core/lib/core
zanec --target x86_64-windows-gnu --build hello.exe --root --package hello=path/to/hello --package core=path/to/core/lib/core
```

Name every package the program imports with its own `--package`, as `core`
is here.

The archive bundles the C runtime compiled by its Zig for x86-64 and AArch64
Linux, Windows and macOS, optimized and not, with the linker command and
files that link a program with it, so a build for one of those runs no C
compiler: `zanec` links it with the LLD built into it. Set `ZANE_CC` to use
another C compiler wrapper, or `ZIG` to use another Zig executable; either
way the bundled runtime is not used, and the runtime that compiler compiles
and the linker command it gives are cached under `~/.cache/zane` (or
`$XDG_CACHE_HOME/zane`); set `ZANE_CACHE_DIR` to keep them elsewhere. Each
archive is built on the platform it is for, and the compiler runs natively
there; Zig cross-compiles the runtime for any other target.

## Publishing a compiler release

Choose **Actions → Release compiler → Run workflow**, select
the default branch, and enter a new `vMAJOR.MINOR` tag, such as `v0.1`.
`v0.0` already exists and will not be overwritten. The two-component tag
format matches the `zane` CLI's compiler-version resolver.

The workflow tests the compiler and, on each platform, builds, packages and
checks it by the same steps: the archive is extracted, moved to a path with
spaces, and builds and runs a program plain, optimized and tiered, outside
the build environment (on Linux in a clean Ubuntu 22.04 container). Only
after every platform's checks pass does it create a tag at the tested commit
and publish the archives and SHA-256 checksums. Build jobs
have read-only repository access; only the publication job can write.

If publication fails after tagging, use **Re-run failed jobs** on the same
run: its original commit and artifacts are retained, and a tag at that commit
is safe to reuse. If a draft release was already created, finish it manually
or delete the draft before retrying (keep the tag). Existing releases and
tags at another commit are always rejected.
