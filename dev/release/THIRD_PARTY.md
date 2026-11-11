# Bundled components

The compiler is GPL-3.0-only, and its runtime library, which the programs it
builds contain, is GPL-3.0-only with the Zane Compiler Runtime Library
Exception, so those programs can be distributed under any terms; `LICENSE`
contains both. Its source is
the commit in `toolchain.coda`, available from
https://github.com/zane-lang/compiler. The included `pixi.lock`, which pins
its conda-forge toolchain, and the OCaml bootstrap pins describe how it was
built. The LLVM,
OCaml and Coda license notices, LGPL-2.1, and the GCC runtime exception are
included here.

The archive also includes:

- LLVM 21, with its linker LLD and clang's C front end built into the
  compiler, and clang's builtin headers embedded in it (Apache-2.0 with LLVM
  exceptions): https://github.com/llvm/llvm-project/tree/llvmorg-21.1.8
- LLVM's OCaml bindings (Apache-2.0 with LLVM exceptions), built into the
  compiler from the copy of LLVM 21.1.8's `llvm/bindings/ocaml` at
  `vendor/llvm-ocaml`
- Coda's parser and OCaml binding (MIT), built into the compiler from the
  submodule at `vendor/coda`: https://github.com/zane-lang/coda
- OCaml's native runtime (LGPL-2.1 with the OCaml linking exception):
  https://github.com/ocaml/ocaml
- The shared libraries the compiler loads that its system does not bring:
  on Linux the ELF loader and libraries in `lib/`, on macOS the dylibs in
  `lib/`, and on Windows the DLLs beside `bin/zanec.exe`. On Linux and
  Windows the accompanying `runtime-libraries.txt` identifies the files they
  were taken from, and the conda-forge packages that hold them are pinned by
  the included `pixi.lock`: https://conda-forge.org
  These include glibc (LGPL-2.1-or-later), GCC runtime libraries (GPL-3.0 with
  the GCC runtime library exception), and LLVM's library dependencies; on
  Windows, the Microsoft Visual C++ runtime, under its redistribution terms.
- Zig (the version and source recorded in the included `zig.json`) and its C toolchain libraries,
  with the start-up files, C library stubs and compiler runtimes it builds
  from them for each bundled target, which `share/runtime/link/files/`
  holds. Zig's `LICENSE` and the licenses in its `lib/` directory are
  retained with the distribution:
  https://ziglang.org/download/

The bundled libraries can be replaced where they are; on Linux the wrapper in
`bin/zanec` runs the compiler with the loader and libraries in `lib/`.
`ZANE_CC` selects a replacement C compiler wrapper, and `ZIG` selects a
replacement Zig executable.
